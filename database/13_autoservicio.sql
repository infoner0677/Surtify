-- =============================================================================
-- SURTIFY · 13_autoservicio.sql  —  Sucursal de autoservicio con pago por pasarela
--   * El cliente NO tiene cuenta: usa la web pública (autoservicio.html) con la clave anon.
--   * Solo 3 funciones son públicas (catálogo, crear pago, consultar estado). Todo lo demás es privado.
--   * La venta/factura se crea ÚNICAMENTE cuando la pasarela confirma el pago, y esa confirmación
--     solo la puede ejecutar la clave de servicio (Edge Function / webhook), nunca el navegador.
--   * Confirmación idempotente (los webhooks se repiten) y a prueba de pagos sin stock.
-- =============================================================================

alter table sucursales add column if not exists autoservicio boolean not null default false;

alter table pedidos drop constraint if exists pedidos_canal_venta_check;
alter table pedidos add constraint pedidos_canal_venta_check
  check (canal_venta::text in ('Mostrador','POS','E-commerce','Autoservicio'));

-- Sede demo de autoservicio (con inventario inicial) en el comercio de la demo
insert into sucursales (id_comercio, nombre_sucursal, direccion, autoservicio)
select c.id_comercio, 'Autoservicio Centro', 'Carrera 7 # 45-10, Bogotá', true
  from comercios c
 where c.prefijo_factura = 'SETR'
   and not exists (select 1 from sucursales s where s.id_comercio = c.id_comercio and s.autoservicio);

insert into inventarios_sucursal (id_sucursal, id_producto, stock, stock_minimo)
select s.id_sucursal, p.id_producto, 20, 5
  from sucursales s join productos p on p.id_comercio = s.id_comercio and p.activo
 where s.autoservicio
   and not exists (select 1 from inventarios_sucursal i where i.id_sucursal = s.id_sucursal and i.id_producto = p.id_producto);

-- Pagos del autoservicio: un cobro por carrito, con foto fija de precios y IVA
create table if not exists pagos_autoservicio (
  id_pago      uuid primary key default gen_random_uuid(),   -- no adivinable: quien lo conoce es quien pagó
  id_comercio  integer not null references comercios(id_comercio) on delete cascade,
  id_sucursal  integer not null references sucursales(id_sucursal),
  referencia   text not null unique,
  lineas       jsonb not null,
  total        numeric(12,2) not null check (total > 0),
  estado       text not null default 'Pendiente'
               check (estado in ('Pendiente','Aprobado','Rechazado','Vencido','Pago sin venta')),
  metodo_pago  text,
  proveedor    text,
  ref_externa  text,            -- identificador de la transacción en la pasarela (sirve de comprobante)
  nota         text,
  id_factura   integer references facturas(id_factura) on delete restrict,
  creado       timestamptz not null default now(),
  expira       timestamptz not null default now() + interval '15 minutes',
  resuelto     timestamptz
);
create index if not exists idx_pagosauto_sucursal on pagos_autoservicio(id_sucursal, creado desc);
create index if not exists idx_pagosauto_comercio on pagos_autoservicio(id_comercio);
create index if not exists idx_pagosauto_factura  on pagos_autoservicio(id_factura);
alter table pagos_autoservicio enable row level security;
revoke all on pagos_autoservicio from anon, authenticated;
grant select on pagos_autoservicio to authenticated;
drop policy if exists "pagosauto_select" on pagos_autoservicio;
create policy "pagosauto_select" on pagos_autoservicio for select to authenticated
  using (id_comercio = (select app.mi_comercio()) and app.puede_ver_sucursal(id_sucursal));

-- 1) Catálogo público de la tienda (solo sedes marcadas como autoservicio, solo lo que hay en stock)
create or replace function public.autoservicio_catalogo(p_sucursal integer)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  select jsonb_build_object('comercio', c.nombre_comercial, 'sucursal', s.nombre_sucursal,
    'productos', coalesce((select jsonb_agg(jsonb_build_object('id_producto', p.id_producto, 'nombre', p.nombre,
         'precio', p.precio_venta, 'codigo_barras', p.codigo_barras, 'stock', i.stock) order by p.nombre)
       from inventarios_sucursal i join productos p on p.id_producto = i.id_producto and p.activo
      where i.id_sucursal = s.id_sucursal and i.stock > 0), '[]'::jsonb))
    into v from sucursales s join comercios c on c.id_comercio = s.id_comercio
   where s.id_sucursal = p_sucursal and s.autoservicio;
  if v is null then raise exception 'Esta tienda no tiene autoservicio'; end if;
  return v;
end $$;

-- 2) Crear el cobro: precios e IVA salen SIEMPRE de la base de datos, nunca del navegador
create or replace function public.autoservicio_crear_pago(p_sucursal integer, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_com integer; v_lineas jsonb; l jsonb; v_total numeric(12,2) := 0; v_id uuid; v_ref text; v_stock integer;
begin
  select id_comercio into v_com from sucursales where id_sucursal = p_sucursal and autoservicio;
  if v_com is null then raise exception 'Esta tienda no tiene autoservicio'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El carrito está vacío'; end if;
  if jsonb_array_length(p_items) > 60 then raise exception 'El carrito tiene demasiados productos'; end if;
  if (select count(*) from pagos_autoservicio where id_sucursal = p_sucursal and estado = 'Pendiente' and expira > now()) >= 300 then
    raise exception 'La tienda está recibiendo demasiados pedidos. Intenta en unos minutos'; end if;

  select jsonb_agg(jsonb_build_object('id_producto', i.id_producto, 'cantidad', i.cant, 'nombre', p.nombre,
                                      'precio', p.precio_venta, 'iva', p.iva_porcentaje) order by p.nombre)
    into v_lineas
    from (select (x->>'id_producto')::integer as id_producto, sum((x->>'cantidad')::integer) as cant
            from jsonb_array_elements(p_items) x group by 1) i
    left join productos p on p.id_producto = i.id_producto and p.id_comercio = v_com and p.activo;

  for l in select * from jsonb_array_elements(v_lineas) loop
    if l->>'nombre' is null then raise exception 'Un producto del carrito no existe'; end if;
    if (l->>'cantidad')::integer < 1 or (l->>'cantidad')::integer > 99 then
      raise exception 'Cantidad no válida para %', l->>'nombre'; end if;
    select stock into v_stock from inventarios_sucursal where id_sucursal = p_sucursal and id_producto = (l->>'id_producto')::integer;
    if coalesce(v_stock, 0) < (l->>'cantidad')::integer then
      raise exception 'No hay suficiente stock de % (quedan %)', l->>'nombre', coalesce(v_stock, 0); end if;
    v_total := v_total + (l->>'cantidad')::integer * (l->>'precio')::numeric;
  end loop;

  v_ref := 'AS-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
  insert into pagos_autoservicio (id_comercio, id_sucursal, referencia, lineas, total)
  values (v_com, p_sucursal, v_ref, v_lineas, v_total) returning id_pago into v_id;
  return jsonb_build_object('id_pago', v_id, 'referencia', v_ref, 'total', v_total, 'lineas', v_lineas);
end $$;

-- 3) Estado del pago (el cliente lo consulta con su id; sirve también para mostrar el comprobante)
create or replace function public.autoservicio_estado(p_id_pago uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p record; f record; c record;
begin
  update pagos_autoservicio set estado = 'Vencido', resuelto = now()
   where id_pago = p_id_pago and estado = 'Pendiente' and expira <= now();
  select * into p from pagos_autoservicio where id_pago = p_id_pago;
  if not found then raise exception 'Pago no encontrado'; end if;
  select s.nombre_sucursal, co.nombre_comercial into c from sucursales s join comercios co on co.id_comercio = s.id_comercio where s.id_sucursal = p.id_sucursal;
  select numero_factura, fecha_emision, subtotal, impuestos into f from facturas where id_factura = p.id_factura;
  return jsonb_build_object('estado', p.estado, 'referencia', p.referencia, 'total', p.total, 'lineas', p.lineas,
    'metodo_pago', p.metodo_pago, 'ref_externa', p.ref_externa, 'nota', case when p.estado = 'Pago sin venta' then 'Tu pago fue recibido pero no pudimos completar la compra. Habla con el personal de la tienda.' end,
    'comercio', c.nombre_comercial, 'sucursal', c.nombre_sucursal,
    'numero_factura', f.numero_factura, 'fecha_emision', f.fecha_emision, 'subtotal', f.subtotal, 'impuestos', f.impuestos);
end $$;

-- 4) Confirmación de la pasarela: SOLO clave de servicio. Idempotente.
create or replace function public.autoservicio_confirmar_pago(p_id_pago uuid, p_aprobado boolean, p_metodo text,
                                                              p_proveedor text, p_ref_externa text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p record; l jsonb; v_sub numeric(12,2) := 0; v_imp numeric(12,2) := 0; v_tl numeric(12,2); v_base numeric(12,2);
  v_pedido integer; v_factura integer; v_pref text; v_cons integer; v_num text;
begin
  select * into p from pagos_autoservicio where id_pago = p_id_pago for update;
  if not found then raise exception 'Pago no encontrado'; end if;
  if p.estado not in ('Pendiente','Vencido') then   -- ya resuelto (webhook repetido): no se vuelve a vender. Un pago aprobado se acepta aunque haya vencido: el dinero ya salió
    return jsonb_build_object('estado', p.estado, 'id_factura', p.id_factura, 'repetido', true);
  end if;
  if not p_aprobado then
    update pagos_autoservicio set estado = 'Rechazado', metodo_pago = p_metodo, proveedor = p_proveedor,
           ref_externa = p_ref_externa, resuelto = now() where id_pago = p_id_pago;
    return jsonb_build_object('estado', 'Rechazado');
  end if;
  if p_metodo is null or p_metodo not in ('Nequi','Daviplata','Bre-B','Tarjeta','PSE') then
    raise exception 'Método de pago no válido: %', p_metodo; end if;

  begin   -- si algo falla (p. ej. se agotó el producto mientras pagaba) se deshace todo y queda marcado para reembolso
    insert into pedidos (id_sucursal, id_cliente, id_empleado, total, estado, canal_venta)
    values (p.id_sucursal, null, null, p.total, 'Completado', 'Autoservicio') returning id_pedido into v_pedido;
    for l in select * from jsonb_array_elements(p.lineas) loop
      insert into detalles_pedido (id_pedido, id_producto, cantidad, precio_unitario)
      values (v_pedido, (l->>'id_producto')::integer, (l->>'cantidad')::integer, (l->>'precio')::numeric);
      v_tl := (l->>'cantidad')::integer * (l->>'precio')::numeric;
      v_base := round(v_tl / (1 + (l->>'iva')::numeric / 100), 2);
      v_sub := v_sub + v_base; v_imp := v_imp + (v_tl - v_base);
    end loop;
    update comercios set consecutivo_factura = consecutivo_factura + 1 where id_comercio = p.id_comercio
      returning prefijo_factura, consecutivo_factura into v_pref, v_cons;
    v_num := v_pref || '-' || lpad(v_cons::text, 4, '0');
    insert into facturas (id_pedido, numero_factura, subtotal, impuestos, total_facturado, metodo_pago, monto_recibido, monto_cambio)
    values (v_pedido, v_num, v_sub, v_imp, p.total, p_metodo, p.total, 0) returning id_factura into v_factura;
    for l in select * from jsonb_array_elements(p.lineas) loop
      insert into detalles_factura (id_factura, id_producto, nombre_producto_historico, cantidad, precio_unitario, iva_aplicado, total_linea)
      values (v_factura, (l->>'id_producto')::integer, l->>'nombre', (l->>'cantidad')::integer,
              (l->>'precio')::numeric, (l->>'iva')::numeric, (l->>'cantidad')::integer * (l->>'precio')::numeric);
    end loop;
    update pagos_autoservicio set estado = 'Aprobado', metodo_pago = p_metodo, proveedor = p_proveedor,
           ref_externa = p_ref_externa, id_factura = v_factura, resuelto = now() where id_pago = p_id_pago;
  exception when others then
    update pagos_autoservicio set estado = 'Pago sin venta', metodo_pago = p_metodo, proveedor = p_proveedor,
           ref_externa = p_ref_externa, nota = left(sqlerrm, 250), resuelto = now() where id_pago = p_id_pago;
    return jsonb_build_object('estado', 'Pago sin venta', 'motivo', sqlerrm);
  end;
  return jsonb_build_object('estado', 'Aprobado', 'id_factura', v_factura, 'numero_factura', v_num);
end $$;

-- Permisos: 3 funciones públicas; la confirmación solo con clave de servicio
revoke all on function public.autoservicio_catalogo(integer) from public, anon, authenticated;
revoke all on function public.autoservicio_crear_pago(integer, jsonb) from public, anon, authenticated;
revoke all on function public.autoservicio_estado(uuid) from public, anon, authenticated;
revoke all on function public.autoservicio_confirmar_pago(uuid, boolean, text, text, text) from public, anon, authenticated;
grant execute on function public.autoservicio_catalogo(integer) to anon, authenticated;
grant execute on function public.autoservicio_crear_pago(integer, jsonb) to anon, authenticated;
grant execute on function public.autoservicio_estado(uuid) to anon, authenticated;
grant execute on function public.autoservicio_confirmar_pago(uuid, boolean, text, text, text) to service_role;

-- Listado de facturas: las ventas de autoservicio no tienen cajero y su comprobante es la referencia de la pasarela
create or replace view v_facturas_recientes with (security_invoker = true) as
select f.id_factura, f.numero_factura, f.fecha_emision, f.total_facturado, f.metodo_pago,
       s.nombre_sucursal as sucursal, coalesce(e.nombre, 'Autoservicio')::varchar(100) as cajero,
       coalesce((select sum(nc.total_reversado) from notas_credito nc where nc.id_factura = f.id_factura), 0) as devuelto,
       p.id_sucursal, p.id_empleado, c.nombre as cliente,
       coalesce((select sum(df.cantidad) from detalles_factura df where df.id_factura = f.id_factura), 0)::int as unidades,
       (select count(*) from comprobantes_pago cp where cp.id_factura = f.id_factura)::int as n_comprobantes,
       (select pa.ref_externa from pagos_autoservicio pa where pa.id_factura = f.id_factura limit 1) as ref_pasarela
  from facturas f
  join pedidos p on p.id_pedido = f.id_pedido
  join sucursales s on s.id_sucursal = p.id_sucursal
  left join empleados e on e.id_empleado = p.id_empleado
  left join clientes c on c.id_cliente = p.id_cliente;
grant select on v_facturas_recientes to authenticated;
