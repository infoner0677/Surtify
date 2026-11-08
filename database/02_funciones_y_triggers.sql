-- =============================================================================
-- SURTIFY · 02_funciones_y_triggers.sql
-- Lógica de negocio dentro del motor (igual filosofía del informe ACA):
--   * Helpers de identidad (schema "app", no expuesto por la API de Supabase)
--   * Triggers de inventario y caja (portados desde MySQL, con correcciones)
--   * Funciones RPC que el frontend invoca: abrir caja, vender, gastos, cerrar
-- Correcciones respecto al script MySQL original:
--   1. Se eliminó el trigger duplicado de facturas (generaba 2 movimientos por venta).
--   2. Stock insuficiente => la venta completa se revierte (antes quedaba negativo).
--   3. El saldo esperado del cajón solo suma/resta EFECTIVO (Nequi/tarjeta no
--      entran al cajón físico, pero sí al libro de movimientos).
-- =============================================================================

create schema if not exists app;

-- ---------- Helpers de identidad ----------
create or replace function app.mi_empleado() returns integer
language sql stable security definer set search_path = public as $$
  select id_empleado from empleados where auth_user_id = auth.uid() and activo limit 1
$$;

create or replace function app.mi_sucursal() returns integer
language sql stable security definer set search_path = public as $$
  select id_sucursal from empleados where auth_user_id = auth.uid() and activo limit 1
$$;

create or replace function app.mi_comercio() returns integer
language sql stable security definer set search_path = public as $$
  select s.id_comercio from empleados e join sucursales s using (id_sucursal)
  where e.auth_user_id = auth.uid() and e.activo limit 1
$$;

create or replace function app.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select r.es_administrador from empleados e join roles r on r.id_role = e.id_role
                   where e.auth_user_id = auth.uid() and e.activo limit 1), false)
$$;

-- ¿Puede el usuario actual ver datos de esta sucursal? Admin: todas las de su comercio. Cajero: solo la suya.
create or replace function app.puede_ver_sucursal(p_id_sucursal integer) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from sucursales s
                 where s.id_sucursal = p_id_sucursal
                   and s.id_comercio = app.mi_comercio()
                   and (app.es_admin() or s.id_sucursal = app.mi_sucursal()))
$$;

-- Al confirmarse un usuario en Supabase Auth, se enlaza con el empleado de igual email.
create or replace function app.vincular_empleado_auth() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null and new.email_confirmed_at is not null then
    update empleados set auth_user_id = new.id
     where lower(email) = lower(new.email) and auth_user_id is null;
  end if;
  return new;
end $$;

drop trigger if exists tr_vincular_empleado on auth.users;
create trigger tr_vincular_empleado
  after insert or update of email_confirmed_at on auth.users
  for each row execute function app.vincular_empleado_auth();

-- ---------- TRIGGER 1: descontar stock al vender ----------
create or replace function fn_actualizar_stock_venta() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sucursal integer;
begin
  select id_sucursal into v_sucursal from pedidos where id_pedido = new.id_pedido;
  update inventarios_sucursal set stock = stock - new.cantidad
   where id_sucursal = v_sucursal and id_producto = new.id_producto and stock >= new.cantidad;
  if not found then
    raise exception 'Stock insuficiente (o producto sin inventario en la sucursal). Producto id %', new.id_producto
      using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger tr_actualizar_stock_venta after insert on detalles_pedido
  for each row execute function fn_actualizar_stock_venta();

-- ---------- TRIGGER 2: reingresar stock por devolución ----------
create or replace function fn_reversar_stock_devolucion() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sucursal integer;
begin
  select p.id_sucursal into v_sucursal
    from notas_credito nc join facturas f on f.id_factura = nc.id_factura
    join pedidos p on p.id_pedido = f.id_pedido
   where nc.id_nota_credito = new.id_nota_credito;
  update inventarios_sucursal set stock = stock + new.cantidad_devuelta
   where id_sucursal = v_sucursal and id_producto = new.id_producto;
  return new;
end $$;
create trigger tr_reversar_stock_devolucion after insert on detalles_nota_credito
  for each row execute function fn_reversar_stock_devolucion();

-- ---------- TRIGGER 3: ingreso a caja al emitir factura (reemplaza los 2 triggers duplicados) ----------
create or replace function fn_registrar_movimiento_factura() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_emp integer; v_ses integer;
begin
  select id_empleado into v_emp from pedidos where id_pedido = new.id_pedido;
  select id_sesion into v_ses from sesiones_caja
   where id_empleado = v_emp and estado_caja = 'Abierta' order by fecha_apertura desc limit 1;
  if v_ses is not null then
    insert into movimientos_caja (id_sesion, tipo_movimiento, metodo_pago, monto_recibido, monto_cambio, monto_neto, id_factura)
    values (v_ses, 'Ingreso', new.metodo_pago, coalesce(new.monto_recibido, new.total_facturado),
            coalesce(new.monto_cambio, 0), new.total_facturado, new.id_factura);
    if new.metodo_pago = 'Efectivo' then
      update sesiones_caja
         set monto_cierre_esperado = coalesce(monto_cierre_esperado, monto_apertura) + new.total_facturado
       where id_sesion = v_ses;
    end if;
  end if;
  return new;
end $$;
create trigger tr_registrar_movimiento_factura after insert on facturas
  for each row execute function fn_registrar_movimiento_factura();

-- ---------- TRIGGER 4: egreso de caja por nota crédito ----------
create or replace function fn_registrar_egreso_nota_credito() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_emp integer; v_ses integer; v_metodo varchar;
begin
  select p.id_empleado, f.metodo_pago into v_emp, v_metodo
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
create trigger tr_registrar_egreso_nota_credito after insert on notas_credito
  for each row execute function fn_registrar_egreso_nota_credito();

-- ---------- TRIGGER 5: gasto de caja resta del efectivo esperado ----------
create or replace function fn_actualizar_esperado_por_gasto() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update sesiones_caja
     set monto_cierre_esperado = coalesce(monto_cierre_esperado, monto_apertura) - new.monto_gasto
   where id_sesion = new.id_sesion;
  return new;
end $$;
create trigger tr_actualizar_esperado_por_gasto after insert on gastos_caja
  for each row execute function fn_actualizar_esperado_por_gasto();

-- ---------- TRIGGER 6: facturas inmutables (lo prometido en el diccionario de datos) ----------
create or replace function fn_facturas_inmutables() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Una factura no puede eliminarse: emita una nota crédito' using errcode = 'P0001';
  end if;
  if tg_table_name = 'facturas' then
    if (new.id_pedido, new.numero_factura, new.subtotal, new.impuestos, new.total_facturado, new.metodo_pago)
       is distinct from (old.id_pedido, old.numero_factura, old.subtotal, old.impuestos, old.total_facturado, old.metodo_pago) then
      raise exception 'Una factura emitida es inmutable (solo puede cambiar estado_dian)' using errcode = 'P0001';
    end if;
  else
    raise exception 'El detalle de una factura emitida es inmutable' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger tr_facturas_inmutables before update or delete on facturas
  for each row execute function fn_facturas_inmutables();
create trigger tr_detalles_factura_inmutables before update or delete on detalles_factura
  for each row execute function fn_facturas_inmutables();

-- =============================================================================
-- FUNCIONES RPC (las que invoca el frontend con supabase.rpc)
-- Todas son SECURITY DEFINER: validan la identidad con auth.uid() y calculan
-- precios, totales e IVA en el servidor (el cliente nunca los dicta).
-- =============================================================================

-- Resumen de una sesión de caja (uso interno; no se expone directamente)
create or replace function app.resumen_sesion(p_id integer) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id_sesion', s.id_sesion,
    'estado', s.estado_caja,
    'fecha_apertura', s.fecha_apertura,
    'fecha_cierre', s.fecha_cierre,
    'monto_apertura', s.monto_apertura,
    'monto_cierre_esperado', coalesce(s.monto_cierre_esperado, s.monto_apertura),
    'monto_cierre_real', s.monto_cierre_real,
    'diferencia', case when s.monto_cierre_real is null then null
                       else s.monto_cierre_real - coalesce(s.monto_cierre_esperado, s.monto_apertura) end,
    'num_ventas', (select count(*) from movimientos_caja m where m.id_sesion = s.id_sesion and m.tipo_movimiento = 'Ingreso'),
    'total_ventas', coalesce((select sum(monto_neto) from movimientos_caja m where m.id_sesion = s.id_sesion and m.tipo_movimiento = 'Ingreso'), 0),
    'ventas_por_metodo', coalesce((select jsonb_object_agg(metodo_pago, t) from
        (select metodo_pago, sum(monto_neto) t from movimientos_caja m
          where m.id_sesion = s.id_sesion and m.tipo_movimiento = 'Ingreso' group by metodo_pago) x), '{}'::jsonb),
    'total_gastos', coalesce((select sum(monto_gasto) from gastos_caja g where g.id_sesion = s.id_sesion), 0),
    'total_devoluciones', coalesce((select sum(monto_neto) from movimientos_caja m where m.id_sesion = s.id_sesion and m.tipo_movimiento = 'Egreso'), 0)
  ) from sesiones_caja s where s.id_sesion = p_id
$$;

-- Perfil del usuario autenticado (el frontend decide modo "Rosa" o "Carlos" con esto)
create or replace function public.perfil_actual() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id_empleado', e.id_empleado, 'nombre', e.nombre, 'email', e.email,
    'id_sucursal', e.id_sucursal, 'nombre_sucursal', s.nombre_sucursal,
    'id_comercio', s.id_comercio, 'nombre_comercial', c.nombre_comercial,
    'rol', r.nombre_rol, 'es_administrador', coalesce(r.es_administrador, false))
  from empleados e
  join sucursales s on s.id_sucursal = e.id_sucursal
  join comercios c on c.id_comercio = s.id_comercio
  left join roles r on r.id_role = e.id_role
  where e.auth_user_id = auth.uid() and e.activo
$$;

create or replace function public.resumen_caja() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ses integer;
begin
  select id_sesion into v_ses from sesiones_caja
   where id_empleado = app.mi_empleado() and estado_caja = 'Abierta' limit 1;
  if v_ses is null then return null; end if;
  return app.resumen_sesion(v_ses);
end $$;

create or replace function public.abrir_caja(p_monto_apertura numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_emp integer := app.mi_empleado(); v_suc integer := app.mi_sucursal(); v_id integer;
begin
  if v_emp is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  if p_monto_apertura is null or p_monto_apertura < 0 then raise exception 'La base de caja no puede ser negativa'; end if;
  if exists (select 1 from sesiones_caja where id_empleado = v_emp and estado_caja = 'Abierta') then
    raise exception 'Ya tienes una caja abierta';
  end if;
  insert into sesiones_caja (id_sucursal, id_empleado, monto_apertura, monto_cierre_esperado, estado_caja)
  values (v_suc, v_emp, p_monto_apertura, p_monto_apertura, 'Abierta') returning id_sesion into v_id;
  return app.resumen_sesion(v_id);
end $$;

-- p_items: [{"id_producto": 1, "cantidad": 2}, ...]   ·  Los precios salen SIEMPRE de la base de datos.
create or replace function public.registrar_venta(
  p_items jsonb, p_metodo_pago text, p_monto_recibido numeric default null,
  p_id_cliente integer default null, p_canal text default 'POS') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_emp integer := app.mi_empleado(); v_suc integer := app.mi_sucursal(); v_com integer := app.mi_comercio();
  v_ses integer; v_lineas jsonb; l jsonb;
  v_total numeric(12,2) := 0; v_sub numeric(12,2) := 0; v_imp numeric(12,2) := 0;
  v_tl numeric(12,2); v_base numeric(12,2);
  v_recibido numeric(12,2); v_cambio numeric(12,2) := 0;
  v_pedido integer; v_factura integer; v_pref text; v_cons integer; v_num text; v_fecha timestamptz;
begin
  if v_emp is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  select id_sesion into v_ses from sesiones_caja
   where id_empleado = v_emp and estado_caja = 'Abierta' order by fecha_apertura desc limit 1;
  if v_ses is null then raise exception 'Debes abrir la caja antes de vender'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El carrito está vacío';
  end if;
  if p_metodo_pago not in ('Efectivo','Nequi','Daviplata','Bre-B','Tarjeta') then
    raise exception 'Método de pago no válido: %', p_metodo_pago;
  end if;
  if p_id_cliente is not null and not exists (select 1 from clientes where id_cliente = p_id_cliente and id_comercio = v_com) then
    raise exception 'Cliente no válido';
  end if;

  -- Normaliza el carrito (agrupa productos repetidos) y trae precio/IVA reales del catálogo
  select jsonb_agg(jsonb_build_object('id_producto', i.id_producto, 'cantidad', i.cant, 'nombre', p.nombre,
                                      'precio', p.precio_venta, 'iva', p.iva_porcentaje))
    into v_lineas
    from (select (x->>'id_producto')::integer as id_producto, sum((x->>'cantidad')::integer) as cant
            from jsonb_array_elements(p_items) x group by 1) i
    left join productos p on p.id_producto = i.id_producto and p.id_comercio = v_com and p.activo;

  for l in select * from jsonb_array_elements(v_lineas) loop
    if l->>'nombre' is null then raise exception 'El producto % no existe o no pertenece a tu comercio', l->>'id_producto'; end if;
    if (l->>'cantidad')::integer <= 0 then raise exception 'Cantidad no válida para el producto %', l->>'nombre'; end if;
    v_total := v_total + (l->>'cantidad')::integer * (l->>'precio')::numeric;
  end loop;

  if p_metodo_pago = 'Efectivo' then
    v_recibido := coalesce(p_monto_recibido, v_total);
    if v_recibido < v_total then raise exception 'El efectivo recibido ($%) es menor al total ($%)', v_recibido, v_total; end if;
    v_cambio := v_recibido - v_total;
  else
    v_recibido := v_total;
  end if;

  insert into pedidos (id_sucursal, id_cliente, id_empleado, total, estado, canal_venta)
  values (v_suc, p_id_cliente, v_emp, v_total, 'Completado', p_canal) returning id_pedido into v_pedido;

  -- El trigger tr_actualizar_stock_venta descuenta inventario (y aborta todo si no alcanza)
  for l in select * from jsonb_array_elements(v_lineas) loop
    insert into detalles_pedido (id_pedido, id_producto, cantidad, precio_unitario)
    values (v_pedido, (l->>'id_producto')::integer, (l->>'cantidad')::integer, (l->>'precio')::numeric);
    v_tl   := (l->>'cantidad')::integer * (l->>'precio')::numeric;
    v_base := round(v_tl / (1 + (l->>'iva')::numeric / 100), 2);   -- precios con IVA incluido
    v_sub  := v_sub + v_base;
    v_imp  := v_imp + (v_tl - v_base);
  end loop;

  update comercios set consecutivo_factura = consecutivo_factura + 1 where id_comercio = v_com
    returning prefijo_factura, consecutivo_factura into v_pref, v_cons;
  v_num := v_pref || '-' || lpad(v_cons::text, 4, '0');

  -- El trigger tr_registrar_movimiento_factura registra el ingreso y el efectivo esperado
  insert into facturas (id_pedido, numero_factura, subtotal, impuestos, total_facturado, metodo_pago, monto_recibido, monto_cambio)
  values (v_pedido, v_num, v_sub, v_imp, v_total, p_metodo_pago, v_recibido, v_cambio)
  returning id_factura, fecha_emision into v_factura, v_fecha;

  for l in select * from jsonb_array_elements(v_lineas) loop
    insert into detalles_factura (id_factura, id_producto, nombre_producto_historico, cantidad, precio_unitario, iva_aplicado, total_linea)
    values (v_factura, (l->>'id_producto')::integer, l->>'nombre', (l->>'cantidad')::integer,
            (l->>'precio')::numeric, (l->>'iva')::numeric, (l->>'cantidad')::integer * (l->>'precio')::numeric);
  end loop;

  return jsonb_build_object('id_pedido', v_pedido, 'id_factura', v_factura, 'numero_factura', v_num,
    'fecha_emision', v_fecha, 'subtotal', v_sub, 'impuestos', v_imp, 'total', v_total,
    'metodo_pago', p_metodo_pago, 'monto_recibido', v_recibido, 'cambio', v_cambio, 'lineas', v_lineas);
end $$;

create or replace function public.registrar_gasto(p_monto numeric, p_concepto text, p_descripcion text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ses integer;
begin
  if app.mi_empleado() is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'El monto del gasto debe ser mayor a cero'; end if;
  if p_concepto is null or btrim(p_concepto) = '' then raise exception 'El concepto es obligatorio'; end if;
  select id_sesion into v_ses from sesiones_caja where id_empleado = app.mi_empleado() and estado_caja = 'Abierta' limit 1;
  if v_ses is null then raise exception 'Debes abrir la caja antes de registrar gastos'; end if;
  insert into gastos_caja (id_sesion, monto_gasto, concepto, descripcion) values (v_ses, p_monto, btrim(p_concepto), p_descripcion);
  return app.resumen_sesion(v_ses);
end $$;

create or replace function public.cerrar_caja(p_monto_real numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ses integer;
begin
  if app.mi_empleado() is null then raise exception 'Tu usuario no está vinculado a un empleado activo' using errcode = '42501'; end if;
  if p_monto_real is null or p_monto_real < 0 then raise exception 'El efectivo contado no puede ser negativo'; end if;
  select id_sesion into v_ses from sesiones_caja where id_empleado = app.mi_empleado() and estado_caja = 'Abierta' limit 1;
  if v_ses is null then raise exception 'No tienes una caja abierta'; end if;
  update sesiones_caja set monto_cierre_real = p_monto_real, fecha_cierre = now(), estado_caja = 'Cerrada' where id_sesion = v_ses;
  return app.resumen_sesion(v_ses);
end $$;

-- =============================================================================
-- VISTAS (security_invoker: respetan las políticas RLS de quien consulta)
-- =============================================================================
create or replace view v_productos_pos with (security_invoker = true) as
select p.id_producto, p.nombre, p.precio_venta, p.iva_porcentaje, p.codigo_barras,
       c.nombre as categoria, coalesce(i.stock, 0) as stock, i.stock_minimo
  from productos p
  left join categorias c on c.id_categoria = p.id_categoria
  left join inventarios_sucursal i on i.id_producto = p.id_producto and i.id_sucursal = app.mi_sucursal()
 where p.activo;

create or replace view v_reporte_critico_inventario with (security_invoker = true) as
select com.nombre_comercial as comercio, suc.nombre_sucursal as sucursal, cat.nombre as categoria,
       prod.nombre as producto, prod.codigo_barras, inv.stock, inv.stock_minimo,
       case when inv.stock <= inv.stock_minimo then 'ALERTA: RECOMPRA URGENTE' else 'Estado Saludable' end as estado_alerta
  from inventarios_sucursal inv
  join sucursales suc on suc.id_sucursal = inv.id_sucursal
  join comercios com on com.id_comercio = suc.id_comercio
  join productos prod on prod.id_producto = inv.id_producto
  left join categorias cat on cat.id_categoria = prod.id_categoria;
