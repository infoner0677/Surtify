-- =============================================================================
-- SURTIFY · 06_inventario_y_panel.sql
-- Módulos 2 y 3 del plan: Inventario con alertas de stock mínimo y Panel multisede (Carlos).
--   * v_inventario_admin ........ inventario por sucursal con bandera de alerta
--   * ajustar_stock() ........... entradas / correcciones de stock y stock mínimo (solo admin)
--   * crear_producto() .......... producto nuevo + inventario en todas las sucursales (solo admin)
--   * panel_multisede(dias) ..... KPIs, ventas por sucursal/día/método, top productos, alertas, turnos
--   * Sede Norte (demo) ......... segunda sucursal para poder ver el panel multisede en acción
-- Todas las funciones validan la identidad con auth.uid(); "hoy" se calcula en hora de Bogotá.
-- =============================================================================

-- ---------- Segunda sucursal de demostración ----------
do $$
declare v_com int; v_suc int; v_rol_cajero int;
begin
  select id_comercio into v_com from comercios where nit_rut = '901234567-8';
  if v_com is null then return; end if;
  if exists (select 1 from sucursales where id_comercio = v_com and nombre_sucursal = 'Sede Norte - Chapinero') then return; end if;

  insert into sucursales (id_comercio, nombre_sucursal, direccion, telefono)
  values (v_com, 'Sede Norte - Chapinero', 'Carrera 13 # 60-20', '6015550101') returning id_sucursal into v_suc;

  select id_role into v_rol_cajero from roles where id_comercio = v_com and not es_administrador order by id_role limit 1;
  insert into empleados (id_sucursal, id_role, numero_identificacion, tipo_documento, nombre, salario, email)
  values (v_suc, v_rol_cajero, '1000000003', 'CC', 'Laura Ruiz', 1400000, 'laura.ruiz@eltriunfo.com');

  -- Salchicha Ranchera arranca por debajo del mínimo para que se vea una alerta real.
  insert into inventarios_sucursal (id_sucursal, id_producto, stock, stock_minimo)
  select v_suc, id_producto, case when codigo_barras = '7701111000011' then 6 else 30 end, 10
    from productos where id_comercio = v_com;
end $$;

-- ---------- Vista de inventario (respeta RLS: el admin ve todas las sedes, el cajero la suya) ----------
create or replace view v_inventario_admin with (security_invoker = true) as
select i.id_inventario, i.id_sucursal, s.nombre_sucursal as sucursal,
       p.id_producto, p.nombre as producto, c.nombre as categoria, p.codigo_barras,
       p.precio_venta, i.stock, coalesce(i.stock_minimo, 0) as stock_minimo,
       (i.stock <= coalesce(i.stock_minimo, 0)) as en_alerta
  from inventarios_sucursal i
  join sucursales s on s.id_sucursal = i.id_sucursal
  join productos p on p.id_producto = i.id_producto
  left join categorias c on c.id_categoria = p.id_categoria
 where p.activo;
grant select on v_inventario_admin to authenticated;

-- ---------- Entrada / ajuste de stock ----------
create or replace function public.ajustar_stock(
  p_id_sucursal integer, p_id_producto integer, p_delta integer, p_stock_minimo integer default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_com integer := app.mi_comercio(); v_actual integer; v_nuevo integer; v_min integer;
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede modificar el inventario' using errcode = '42501'; end if;
  if p_delta is null then raise exception 'Indica la cantidad a sumar o restar'; end if;
  if p_stock_minimo is not null and p_stock_minimo < 0 then raise exception 'El stock mínimo no puede ser negativo'; end if;
  if not exists (select 1 from sucursales where id_sucursal = p_id_sucursal and id_comercio = v_com) then
    raise exception 'Sucursal no válida'; end if;
  if not exists (select 1 from productos where id_producto = p_id_producto and id_comercio = v_com) then
    raise exception 'Producto no válido'; end if;

  select stock into v_actual from inventarios_sucursal
   where id_sucursal = p_id_sucursal and id_producto = p_id_producto for update;
  if not found then
    if p_delta < 0 then raise exception 'No hay inventario para descontar'; end if;
    insert into inventarios_sucursal (id_sucursal, id_producto, stock, stock_minimo)
    values (p_id_sucursal, p_id_producto, p_delta, coalesce(p_stock_minimo, 5))
    returning stock, stock_minimo into v_nuevo, v_min;
  else
    if v_actual + p_delta < 0 then raise exception 'El stock no puede quedar negativo (actual: %)', v_actual; end if;
    update inventarios_sucursal
       set stock = stock + p_delta, stock_minimo = coalesce(p_stock_minimo, stock_minimo)
     where id_sucursal = p_id_sucursal and id_producto = p_id_producto
    returning stock, stock_minimo into v_nuevo, v_min;
  end if;
  return jsonb_build_object('stock', v_nuevo, 'stock_minimo', v_min, 'en_alerta', v_nuevo <= coalesce(v_min, 0));
end $$;

-- ---------- Producto nuevo ----------
create or replace function public.crear_producto(
  p_nombre text, p_precio numeric, p_iva numeric, p_codigo_barras text, p_id_categoria integer,
  p_id_sucursal integer, p_stock integer, p_stock_minimo integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_com integer := app.mi_comercio(); v_id integer; v_codigo text := nullif(btrim(coalesce(p_codigo_barras, '')), '');
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede crear productos' using errcode = '42501'; end if;
  if p_nombre is null or btrim(p_nombre) = '' then raise exception 'El nombre es obligatorio'; end if;
  if p_precio is null or p_precio < 0 then raise exception 'El precio no es válido'; end if;
  if p_iva is null or p_iva < 0 or p_iva > 100 then raise exception 'El IVA debe estar entre 0 y 100'; end if;
  if coalesce(p_stock, 0) < 0 or coalesce(p_stock_minimo, 0) < 0 then raise exception 'El stock no puede ser negativo'; end if;
  if not exists (select 1 from sucursales where id_sucursal = p_id_sucursal and id_comercio = v_com) then
    raise exception 'Sucursal no válida'; end if;
  if p_id_categoria is not null and not exists (select 1 from categorias where id_categoria = p_id_categoria and id_comercio = v_com) then
    raise exception 'Categoría no válida'; end if;
  if v_codigo is not null and exists (select 1 from productos where id_comercio = v_com and codigo_barras = v_codigo) then
    raise exception 'Ya existe un producto con ese código de barras'; end if;

  insert into productos (id_comercio, id_categoria, nombre, precio_venta, iva_porcentaje, codigo_barras)
  values (v_com, p_id_categoria, btrim(p_nombre), p_precio, p_iva, v_codigo) returning id_producto into v_id;

  -- El producto queda disponible en todas las sedes: con stock inicial en la elegida y 0 en las demás.
  insert into inventarios_sucursal (id_sucursal, id_producto, stock, stock_minimo)
  select s.id_sucursal, v_id, case when s.id_sucursal = p_id_sucursal then coalesce(p_stock, 0) else 0 end, coalesce(p_stock_minimo, 5)
    from sucursales s where s.id_comercio = v_com;
  return jsonb_build_object('id_producto', v_id);
end $$;

-- ---------- Panel multisede ----------
create or replace function public.panel_multisede(p_dias integer default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_com integer := app.mi_comercio();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_dias integer := least(greatest(coalesce(p_dias, 7), 1), 90);
  v_desde date;
  res jsonb;
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede ver el panel multisede' using errcode = '42501'; end if;
  v_desde := v_hoy - (v_dias - 1);

  with v as (
    select f.id_factura, f.total_facturado, f.metodo_pago, p.id_sucursal,
           (f.fecha_emision at time zone 'America/Bogota')::date as dia
      from facturas f
      join pedidos p on p.id_pedido = f.id_pedido
      join sucursales s on s.id_sucursal = p.id_sucursal
     where s.id_comercio = v_com
  )
  select jsonb_build_object(
    'dias', v_dias,
    'hoy', v_hoy,
    'totales', (select jsonb_build_object(
        'ventas', coalesce(sum(total_facturado), 0),
        'num_ventas', count(*),
        'ticket_promedio', coalesce(round(avg(total_facturado)), 0),
        'ventas_hoy', coalesce(sum(total_facturado) filter (where dia = v_hoy), 0),
        'num_ventas_hoy', count(*) filter (where dia = v_hoy))
      from v where dia >= v_desde),
    'gastos', coalesce((select sum(g.monto_gasto) from gastos_caja g
        join sesiones_caja sc on sc.id_sesion = g.id_sesion
        join sucursales s on s.id_sucursal = sc.id_sucursal
       where s.id_comercio = v_com and (g.fecha_gasto at time zone 'America/Bogota')::date >= v_desde), 0),
    'devoluciones', coalesce((select sum(nc.total_reversado) from notas_credito nc
        join facturas f on f.id_factura = nc.id_factura
        join pedidos p on p.id_pedido = f.id_pedido
        join sucursales s on s.id_sucursal = p.id_sucursal
       where s.id_comercio = v_com and (nc.fecha_emision at time zone 'America/Bogota')::date >= v_desde), 0),
    'sucursales', coalesce((select jsonb_agg(jsonb_build_object(
        'id_sucursal', s.id_sucursal,
        'nombre', s.nombre_sucursal,
        'ventas_hoy', coalesce((select sum(total_facturado) from v where v.id_sucursal = s.id_sucursal and v.dia = v_hoy), 0),
        'num_ventas_hoy', (select count(*) from v where v.id_sucursal = s.id_sucursal and v.dia = v_hoy),
        'ventas_periodo', coalesce((select sum(total_facturado) from v where v.id_sucursal = s.id_sucursal and v.dia >= v_desde), 0),
        'num_ventas_periodo', (select count(*) from v where v.id_sucursal = s.id_sucursal and v.dia >= v_desde),
        'cajas_abiertas', coalesce((select jsonb_agg(jsonb_build_object(
              'empleado', e.nombre, 'desde', sc.fecha_apertura,
              'efectivo_esperado', coalesce(sc.monto_cierre_esperado, sc.monto_apertura)))
            from sesiones_caja sc join empleados e on e.id_empleado = sc.id_empleado
           where sc.id_sucursal = s.id_sucursal and sc.estado_caja = 'Abierta'), '[]'::jsonb),
        'productos_en_alerta', (select count(*) from inventarios_sucursal i join productos pr on pr.id_producto = i.id_producto
           where i.id_sucursal = s.id_sucursal and pr.activo and i.stock <= coalesce(i.stock_minimo, 0))
      ) order by s.nombre_sucursal) from sucursales s where s.id_comercio = v_com), '[]'::jsonb),
    'ventas_por_dia', (select jsonb_agg(jsonb_build_object('fecha', d.dia, 'total', coalesce(t.total, 0), 'num', coalesce(t.n, 0)) order by d.dia)
        from (select v_desde + g as dia from generate_series(0, v_dias - 1) g) d
        left join (select dia, sum(total_facturado) as total, count(*) as n from v where dia >= v_desde group by dia) t on t.dia = d.dia),
    'ventas_por_metodo', coalesce((select jsonb_object_agg(metodo_pago, t) from
        (select metodo_pago, sum(total_facturado) as t from v where dia >= v_desde group by metodo_pago) x), '{}'::jsonb),
    'top_productos', coalesce((select jsonb_agg(jsonb_build_object('producto', q.producto, 'unidades', q.unidades, 'total', q.total) order by q.total desc)
        from (select df.nombre_producto_historico as producto, sum(df.cantidad) as unidades, sum(df.total_linea) as total
                from detalles_factura df join v on v.id_factura = df.id_factura
               where v.dia >= v_desde group by df.nombre_producto_historico
               order by sum(df.total_linea) desc limit 5) q), '[]'::jsonb),
    'alertas_stock', coalesce((select jsonb_agg(jsonb_build_object('sucursal', a.sucursal, 'producto', a.producto, 'stock', a.stock, 'stock_minimo', a.stock_minimo)
          order by a.stock - a.stock_minimo, a.producto)
        from (select s.nombre_sucursal as sucursal, pr.nombre as producto, i.stock, coalesce(i.stock_minimo, 0) as stock_minimo
                from inventarios_sucursal i
                join sucursales s on s.id_sucursal = i.id_sucursal
                join productos pr on pr.id_producto = i.id_producto
               where s.id_comercio = v_com and pr.activo and i.stock <= coalesce(i.stock_minimo, 0)
               order by i.stock - coalesce(i.stock_minimo, 0), pr.nombre limit 15) a), '[]'::jsonb),
    'turnos_recientes', coalesce((select jsonb_agg(jsonb_build_object(
          'sucursal', t.sucursal, 'empleado', t.empleado, 'apertura', t.fecha_apertura, 'cierre', t.fecha_cierre, 'estado', t.estado_caja,
          'esperado', t.esperado, 'contado', t.monto_cierre_real, 'diferencia', t.diferencia) order by t.fecha_apertura desc)
        from (select s.nombre_sucursal as sucursal, e.nombre as empleado, sc.fecha_apertura, sc.fecha_cierre, sc.estado_caja,
                     coalesce(sc.monto_cierre_esperado, sc.monto_apertura) as esperado, sc.monto_cierre_real,
                     case when sc.monto_cierre_real is null then null
                          else sc.monto_cierre_real - coalesce(sc.monto_cierre_esperado, sc.monto_apertura) end as diferencia
                from sesiones_caja sc
                join sucursales s on s.id_sucursal = sc.id_sucursal
                join empleados e on e.id_empleado = sc.id_empleado
               where s.id_comercio = v_com
               order by sc.fecha_apertura desc limit 8) t), '[]'::jsonb)
  ) into res from (select 1) one;
  return res;
end $$;

-- ---------- Permisos: solo usuarios autenticados pueden invocarlas ----------
revoke all on function public.ajustar_stock(integer, integer, integer, integer) from public, anon;
revoke all on function public.crear_producto(text, numeric, numeric, text, integer, integer, integer, integer) from public, anon;
revoke all on function public.panel_multisede(integer) from public, anon;
grant execute on function public.ajustar_stock(integer, integer, integer, integer) to authenticated;
grant execute on function public.crear_producto(text, numeric, numeric, text, integer, integer, integer, integer) to authenticated;
grant execute on function public.panel_multisede(integer) to authenticated;

update sistema_acerca_de set valor = '2.1.0 (PostgreSQL / Supabase: RLS, triggers, RPC, inventario y panel multisede)'
 where parametro = 'Versión Base de Datos';
