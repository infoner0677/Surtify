-- =============================================================================
-- SURTIFY · 07_devoluciones_y_reporte.sql
--   * Devoluciones con nota crédito: devolucion_disponible(), registrar_devolucion(), v_facturas_recientes
--   * Reporte para el contador: reporte_contador(desde, hasta, sucursal)
--   * Corrección: el egreso de caja por devolución sale de la caja de QUIEN devuelve el dinero
--     (antes salía de la caja del cajero que hizo la venta original, que podía estar cerrada).
-- =============================================================================

alter table notas_credito add column if not exists id_empleado integer references empleados(id_empleado) on delete set null;
alter table comercios     add column if not exists consecutivo_nota integer not null default 0 check (consecutivo_nota >= 0);
create index if not exists idx_notas_credito_empleado on notas_credito(id_empleado);

-- El egreso usa la sesión de caja del empleado que registra la nota (si no consta, la del vendedor original).
create or replace function fn_registrar_egreso_nota_credito() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_emp integer; v_ses integer; v_metodo varchar;
begin
  select coalesce(new.id_empleado, p.id_empleado), f.metodo_pago into v_emp, v_metodo
    from facturas f join pedidos p on p.id_pedido = f.id_pedido where f.id_factura = new.id_factura;
  select id_sesion into v_ses from sesiones_caja
   where id_empleado = v_emp and estado_caja = 'Abierta' order by fecha_apertura desc limit 1;
  if v_ses is not null then
    insert into movimientos_caja (id_sesion, tipo_movimiento, metodo_pago, monto_recibido, monto_cambio, monto_neto, id_nota_credito)
    values (v_ses, 'Egreso', v_metodo, 0, 0, new.total_reversado, new.id_nota_credito);
    if v_metodo = 'Efectivo' then
      update sesiones_caja
         set monto_cierre_esperado = coalesce(monto_cierre_esperado, monto_apertura) - new.total_reversado
       where id_sesion = v_ses;
    end if;
  end if;
  return new;
end $$;

-- ---------- Facturas recientes (respeta RLS: el admin ve todas las sedes, el cajero la suya) ----------
create or replace view v_facturas_recientes with (security_invoker = true) as
select f.id_factura, f.numero_factura, f.fecha_emision, f.total_facturado, f.metodo_pago,
       s.nombre_sucursal as sucursal, e.nombre as cajero,
       coalesce((select sum(nc.total_reversado) from notas_credito nc where nc.id_factura = f.id_factura), 0) as devuelto
  from facturas f
  join pedidos p on p.id_pedido = f.id_pedido
  join sucursales s on s.id_sucursal = p.id_sucursal
  left join empleados e on e.id_empleado = p.id_empleado;
grant select on v_facturas_recientes to authenticated;

-- ---------- Qué se puede devolver de una factura ----------
create or replace function public.devolucion_disponible(p_id_factura integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_f record;
begin
  if app.mi_empleado() is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  select f.id_factura, f.numero_factura, f.fecha_emision, f.total_facturado, f.metodo_pago, p.id_sucursal into v_f
    from facturas f join pedidos p on p.id_pedido = f.id_pedido where f.id_factura = p_id_factura;
  if not found or not app.puede_ver_sucursal(v_f.id_sucursal) then raise exception 'Factura no encontrada'; end if;
  return jsonb_build_object(
    'id_factura', v_f.id_factura, 'numero_factura', v_f.numero_factura, 'fecha_emision', v_f.fecha_emision,
    'total', v_f.total_facturado, 'metodo_pago', v_f.metodo_pago,
    'lineas', coalesce((select jsonb_agg(jsonb_build_object('id_producto', x.id_producto, 'nombre', x.nombre, 'precio', x.precio,
                          'vendida', x.vendida, 'devuelta', x.devuelta, 'disponible', x.vendida - x.devuelta) order by x.nombre)
      from (select df.id_producto, max(df.nombre_producto_historico) as nombre, max(df.precio_unitario) as precio,
                   sum(df.cantidad)::int as vendida,
                   coalesce((select sum(dn.cantidad_devuelta) from detalles_nota_credito dn
                              join notas_credito nc on nc.id_nota_credito = dn.id_nota_credito
                             where nc.id_factura = p_id_factura and dn.id_producto = df.id_producto), 0)::int as devuelta
              from detalles_factura df
             where df.id_factura = p_id_factura and df.id_producto is not null
             group by df.id_producto) x), '[]'::jsonb));
end $$;

-- ---------- Registrar devolución (nota crédito + reingreso de stock + egreso de caja) ----------
-- p_items: [{"id_producto": 1, "cantidad": 1}, ...]
create or replace function public.registrar_devolucion(p_id_factura integer, p_items jsonb, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_emp integer := app.mi_empleado(); v_com integer := app.mi_comercio(); v_ses integer;
  v_f record; v_d jsonb; l jsonb; v_line jsonb; v_lineas jsonb := '[]'::jsonb; v_total numeric(12,2) := 0;
  v_pid integer; v_cant integer; v_precio numeric(12,2); v_nc integer; v_pref text; v_cons integer; v_num text;
  v_motivo text := btrim(coalesce(p_motivo, ''));
begin
  if v_emp is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  if v_motivo = '' then raise exception 'Indica el motivo de la devolución'; end if;
  if length(v_motivo) > 255 then raise exception 'El motivo es demasiado largo'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Selecciona al menos un producto a devolver'; end if;

  select id_sesion into v_ses from sesiones_caja where id_empleado = v_emp and estado_caja = 'Abierta' limit 1;
  if v_ses is null then raise exception 'Abre tu caja antes de registrar una devolución'; end if;

  select f.id_factura, f.metodo_pago, p.id_sucursal into v_f
    from facturas f join pedidos p on p.id_pedido = f.id_pedido where f.id_factura = p_id_factura for update of f;
  if not found or not app.puede_ver_sucursal(v_f.id_sucursal) then raise exception 'Factura no encontrada'; end if;

  v_d := public.devolucion_disponible(p_id_factura);   -- se calcula tras bloquear la factura

  for l in select jsonb_build_object('id_producto', (x->>'id_producto')::integer, 'cantidad', sum((x->>'cantidad')::integer))
             from jsonb_array_elements(p_items) x group by (x->>'id_producto')::integer loop
    v_pid := (l->>'id_producto')::integer; v_cant := (l->>'cantidad')::integer;
    if v_cant is null or v_cant <= 0 then raise exception 'Cantidad no válida'; end if;
    select e into v_line from jsonb_array_elements(v_d->'lineas') e where (e->>'id_producto')::integer = v_pid;
    if v_line is null then raise exception 'El producto % no pertenece a esa factura', v_pid; end if;
    if v_cant > (v_line->>'disponible')::integer then
      raise exception 'No puedes devolver % unidades de %: solo quedan % por devolver', v_cant, v_line->>'nombre', v_line->>'disponible';
    end if;
    v_precio := (v_line->>'precio')::numeric;
    v_total := v_total + v_cant * v_precio;
    v_lineas := v_lineas || jsonb_build_object('id_producto', v_pid, 'nombre', v_line->>'nombre', 'cantidad', v_cant,
                                               'precio', v_precio, 'total', v_cant * v_precio);
  end loop;

  update comercios set consecutivo_nota = consecutivo_nota + 1 where id_comercio = v_com
    returning prefijo_factura, consecutivo_nota into v_pref, v_cons;
  v_num := 'NC-' || v_pref || '-' || lpad(v_cons::text, 4, '0');

  -- El trigger tr_registrar_egreso_nota_credito saca el dinero de MI caja abierta
  insert into notas_credito (id_factura, numero_nota, motivo_dian, total_reversado, id_empleado)
  values (p_id_factura, v_num, v_motivo, v_total, v_emp) returning id_nota_credito into v_nc;

  -- El trigger tr_reversar_stock_devolucion reingresa el stock a la sede de la venta original
  for l in select * from jsonb_array_elements(v_lineas) loop
    insert into detalles_nota_credito (id_nota_credito, id_producto, cantidad_devuelta, precio_unitario_reversado, total_linea_reversado)
    values (v_nc, (l->>'id_producto')::integer, (l->>'cantidad')::integer, (l->>'precio')::numeric, (l->>'total')::numeric);
  end loop;

  return jsonb_build_object('id_nota_credito', v_nc, 'numero_nota', v_num, 'total', v_total, 'metodo_pago', v_f.metodo_pago,
    'efectivo_a_entregar', case when v_f.metodo_pago = 'Efectivo' then v_total else 0 end,
    'lineas', v_lineas, 'caja', app.resumen_sesion(v_ses));
end $$;

-- ---------- Reporte para el contador ----------
create or replace function public.reporte_contador(p_desde date, p_hasta date, p_id_sucursal integer default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_emp integer := app.mi_empleado(); v_com integer := app.mi_comercio(); v_adm boolean := app.es_admin(); v_suc integer := app.mi_sucursal();
  v_sucs integer[]; v_nombre_suc text; res jsonb;
begin
  if v_emp is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  if p_desde is null or p_hasta is null or p_desde > p_hasta then raise exception 'El rango de fechas no es válido'; end if;
  if p_hasta - p_desde > 366 then raise exception 'El rango máximo es de un año'; end if;

  -- Administrador: todas las sedes (o la elegida). Cajero: solo la suya.
  select array_agg(s.id_sucursal) into v_sucs from sucursales s
   where s.id_comercio = v_com
     and ((v_adm and (p_id_sucursal is null or s.id_sucursal = p_id_sucursal)) or (not v_adm and s.id_sucursal = v_suc));
  if v_sucs is null then raise exception 'Sucursal no válida'; end if;
  if array_length(v_sucs, 1) = 1 then select nombre_sucursal into v_nombre_suc from sucursales where id_sucursal = v_sucs[1]; end if;

  with f as (
    select fa.id_factura, fa.numero_factura, fa.fecha_emision, fa.subtotal, fa.impuestos, fa.total_facturado,
           fa.metodo_pago, fa.estado_dian, s.nombre_sucursal as sucursal
      from facturas fa
      join pedidos p on p.id_pedido = fa.id_pedido
      join sucursales s on s.id_sucursal = p.id_sucursal
     where p.id_sucursal = any(v_sucs)
       and (fa.fecha_emision at time zone 'America/Bogota')::date between p_desde and p_hasta
  ), n as (
    select nc.id_nota_credito, nc.numero_nota, nc.fecha_emision, nc.total_reversado, nc.motivo_dian,
           fa.numero_factura, s.nombre_sucursal as sucursal
      from notas_credito nc
      join facturas fa on fa.id_factura = nc.id_factura
      join pedidos p on p.id_pedido = fa.id_pedido
      join sucursales s on s.id_sucursal = p.id_sucursal
     where p.id_sucursal = any(v_sucs)
       and (nc.fecha_emision at time zone 'America/Bogota')::date between p_desde and p_hasta
  ), l as (
    select df.iva_aplicado, df.total_linea, round(df.total_linea / (1 + df.iva_aplicado / 100), 2) as base
      from detalles_factura df join f on f.id_factura = df.id_factura
  )
  select jsonb_build_object(
    'comercio', (select jsonb_build_object('nombre', c.nombre_comercial, 'razon_social', c.razon_social, 'nit', c.nit_rut)
                   from comercios c where c.id_comercio = v_com),
    'desde', p_desde, 'hasta', p_hasta, 'sucursal', v_nombre_suc,
    'facturas', (select jsonb_build_object('num', count(*), 'total', coalesce(sum(total_facturado), 0),
                   'subtotal', coalesce(sum(subtotal), 0), 'iva', coalesce(sum(impuestos), 0),
                   'primera', (select numero_factura from f order by id_factura limit 1),
                   'ultima',  (select numero_factura from f order by id_factura desc limit 1)) from f),
    'iva_por_tarifa', coalesce((select jsonb_agg(jsonb_build_object('tarifa', iva_aplicado, 'base', b, 'iva', i, 'total', t) order by iva_aplicado)
                         from (select iva_aplicado, sum(base) as b, sum(total_linea - base) as i, sum(total_linea) as t from l group by iva_aplicado) x), '[]'::jsonb),
    'devoluciones', (select jsonb_build_object('num', count(*), 'total', coalesce(sum(total_reversado), 0)) from n),
    'ventas_netas', (select coalesce(sum(total_facturado), 0) from f) - (select coalesce(sum(total_reversado), 0) from n),
    'por_metodo', coalesce((select jsonb_object_agg(metodo_pago, t) from (select metodo_pago, sum(total_facturado) as t from f group by metodo_pago) x), '{}'::jsonb),
    'gastos', coalesce((select sum(g.monto_gasto) from gastos_caja g
                   join sesiones_caja sc on sc.id_sesion = g.id_sesion
                  where sc.id_sucursal = any(v_sucs) and (v_adm or sc.id_empleado = v_emp)
                    and (g.fecha_gasto at time zone 'America/Bogota')::date between p_desde and p_hasta), 0),
    'por_sucursal', coalesce((select jsonb_agg(jsonb_build_object('nombre', sucursal, 'num', num, 'total', total) order by sucursal)
                       from (select sucursal, count(*) as num, sum(total_facturado) as total from f group by sucursal) x), '[]'::jsonb),
    'detalle_facturas', coalesce((select jsonb_agg(jsonb_build_object('numero', numero_factura, 'fecha', fecha_emision, 'sucursal', sucursal,
                          'metodo', metodo_pago, 'subtotal', subtotal, 'iva', impuestos, 'total', total_facturado, 'estado_dian', estado_dian) order by id_factura)
                       from (select * from f order by id_factura limit 2000) z), '[]'::jsonb),
    'detalle_notas', coalesce((select jsonb_agg(jsonb_build_object('numero', numero_nota, 'fecha', fecha_emision, 'factura', numero_factura,
                          'sucursal', sucursal, 'motivo', motivo_dian, 'total', total_reversado) order by id_nota_credito)
                       from (select * from n order by id_nota_credito limit 2000) z), '[]'::jsonb)
  ) into res;
  return res;
end $$;

revoke all on function public.devolucion_disponible(integer) from public, anon;
revoke all on function public.registrar_devolucion(integer, jsonb, text) from public, anon;
revoke all on function public.reporte_contador(date, date, integer) from public, anon;
grant execute on function public.devolucion_disponible(integer) to authenticated;
grant execute on function public.registrar_devolucion(integer, jsonb, text) to authenticated;
grant execute on function public.reporte_contador(date, date, integer) to authenticated;

update sistema_acerca_de set valor = '2.2.0 (PostgreSQL / Supabase: RLS, triggers, RPC, inventario, panel multisede, devoluciones y reporte contable)'
 where parametro = 'Versión Base de Datos';
