-- =============================================================================
-- SURTIFY · 14_autoservicio_comprobante_y_fiado.sql
--   A) Pago por comprobante Bre-B (sin comisión de pasarela): el cliente paga a la llave de la tienda,
--      sube la captura y escribe la referencia; la venta queda "Por verificar" y el dueño la concilia.
--   B) Fiado en autoservicio: el cliente entra con Google, deja celular y acepta el tratamiento de datos;
--      el dueño lo aprueba y le fija un cupo. Sin aprobación no hay fiado.
--   C) Endurecimiento: el cupo de fiado ya no se puede editar con UPDATE directo (solo por funciones).
-- =============================================================================

-- C) Ningún cajero puede subir el cupo de un cliente editando la tabla
revoke update on clientes from authenticated;
grant update (nombre, telefono, numero_identificacion, tipo_documento, email, tipo_persona, regimen_tributario) on clientes to authenticated;

-- ---------- Configuración de pago por sede ----------
alter table sucursales add column if not exists modo_pago_auto text not null default 'pasarela'
  check (modo_pago_auto in ('pasarela','comprobante'));
alter table sucursales add column if not exists llave_breb text;
alter table sucursales add column if not exists titular_breb text;
alter table sucursales add column if not exists tope_sin_verificar numeric(12,2) not null default 100000 check (tope_sin_verificar > 0);
update sucursales set modo_pago_auto = 'comprobante', llave_breb = coalesce(llave_breb, '@surtify-demo'),
       titular_breb = coalesce(titular_breb, 'Carnes y Salsas El Triunfo (DEMO)')
 where autoservicio;

-- ---------- Datos del pago ----------
alter table pagos_autoservicio add column if not exists modo text not null default 'pasarela' check (modo in ('pasarela','comprobante','fiado'));
alter table pagos_autoservicio add column if not exists id_cliente integer references clientes(id_cliente);
alter table pagos_autoservicio add column if not exists verificacion text not null default 'No aplica'
  check (verificacion in ('No aplica','Por verificar','Verificado','Dudoso'));
alter table pagos_autoservicio add column if not exists ref_cliente text;
alter table pagos_autoservicio add column if not exists ruta_captura text;
alter table pagos_autoservicio add column if not exists verificado_por integer references empleados(id_empleado) on delete set null;
alter table pagos_autoservicio add column if not exists verificado_en timestamptz;
alter table pagos_autoservicio add column if not exists nota_verificacion text;
create unique index if not exists uq_pagosauto_refcliente on pagos_autoservicio(id_comercio, ref_cliente) where ref_cliente is not null;
create index if not exists idx_pagosauto_cliente on pagos_autoservicio(id_cliente);
create index if not exists idx_pagosauto_verif on pagos_autoservicio(id_comercio, verificacion);

-- ---------- Almacenamiento de las capturas (privado; el cliente anónimo solo puede SUBIR a la carpeta de su pago) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('capturas-autoservicio', 'capturas-autoservicio', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

grant usage on schema app to anon;
create or replace function app.puede_subir_captura(p_carpeta text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_carpeta ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and exists (select 1 from pagos_autoservicio p where p.id_pago::text = p_carpeta and p.modo = 'comprobante'
                  and p.estado in ('Pendiente','Vencido') and p.ruta_captura is null and p.expira > now() - interval '30 minutes')
     and (select count(*) from storage.objects o where o.bucket_id = 'capturas-autoservicio' and o.name like p_carpeta || '/%') < 3
$$;
revoke all on function app.puede_subir_captura(text) from public;
grant execute on function app.puede_subir_captura(text) to anon, authenticated;

drop policy if exists "captura_subir" on storage.objects;
create policy "captura_subir" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'capturas-autoservicio' and app.puede_subir_captura((storage.foldername(name))[1]));
drop policy if exists "captura_leer" on storage.objects;
create policy "captura_leer" on storage.objects for select to authenticated
  using (bucket_id = 'capturas-autoservicio'
         and exists (select 1 from public.pagos_autoservicio p where p.ruta_captura = storage.objects.name));

-- ---------- Clientes que se registran solos (Google) ----------
create table if not exists clientes_autoservicio (
  id_cliente     integer primary key references clientes(id_cliente) on delete cascade,
  id_comercio    integer not null references comercios(id_comercio) on delete cascade,
  auth_user_id   uuid not null,
  email          text,
  estado         text not null default 'Pendiente' check (estado in ('Pendiente','Aprobado','Rechazado')),
  acepta_datos_en timestamptz not null,
  creado         timestamptz not null default now(),
  resuelto       timestamptz,
  resuelto_por   integer references empleados(id_empleado) on delete set null,
  unique (auth_user_id, id_comercio)
);
create index if not exists idx_cliauto_comercio on clientes_autoservicio(id_comercio, estado);
create index if not exists idx_cliauto_resuelto_por on clientes_autoservicio(resuelto_por);
alter table clientes_autoservicio enable row level security;
revoke all on clientes_autoservicio from anon, authenticated;
grant select on clientes_autoservicio to authenticated;
drop policy if exists "cliauto_select" on clientes_autoservicio;
create policy "cliauto_select" on clientes_autoservicio for select to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()));

-- ---------- Venta interna de autoservicio (la usan la pasarela, el comprobante y el fiado) ----------
create or replace function app.autoservicio_vender(p_id_pago uuid, p_metodo text, p_proveedor text, p_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p record; l jsonb; v_sub numeric(12,2) := 0; v_imp numeric(12,2) := 0; v_tl numeric(12,2); v_base numeric(12,2);
  v_pedido integer; v_factura integer; v_pref text; v_cons integer; v_num text;
  v_est text; v_cupo numeric(12,2); v_saldo numeric(12,2) := 0;
begin
  select * into p from pagos_autoservicio where id_pago = p_id_pago for update;
  if not found then raise exception 'Pago no encontrado'; end if;
  if p.estado not in ('Pendiente','Vencido') then   -- ya resuelto (aviso repetido): no se vuelve a vender
    return jsonb_build_object('estado', p.estado, 'id_factura', p.id_factura, 'repetido', true);
  end if;

  if p_metodo = 'Fiado' then   -- reglas del fiado: cuenta aprobada y cupo (se bloquea al cliente para que dos compras no lo superen)
    select ca.estado, c.cupo_fiado into v_est, v_cupo from clientes_autoservicio ca join clientes c on c.id_cliente = ca.id_cliente
     where ca.id_cliente = p.id_cliente for update of c;
    if p.id_cliente is null or v_est is distinct from 'Aprobado' or coalesce(v_cupo, 0) <= 0 then
      raise exception 'Tu cuenta de fiado aún no está aprobada'; end if;
    select coalesce(sum(case when tipo = 'Cargo' then monto else -monto end), 0) into v_saldo from cartera_movimientos where id_cliente = p.id_cliente;
    if v_saldo + p.total > v_cupo then
      raise exception 'Esta compra supera tu cupo de fiado (cupo $%, debes $%)', v_cupo, v_saldo; end if;
  end if;

  begin   -- si algo falla (p. ej. se agotó el producto mientras pagaba) se deshace todo
    insert into pedidos (id_sucursal, id_cliente, id_empleado, total, estado, canal_venta)
    values (p.id_sucursal, p.id_cliente, null, p.total, 'Completado', 'Autoservicio') returning id_pedido into v_pedido;
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
    if p_metodo = 'Fiado' then
      insert into cartera_movimientos (id_comercio, id_cliente, id_sucursal, id_empleado, id_sesion, tipo, monto, metodo_pago, id_factura, nota)
      values (p.id_comercio, p.id_cliente, p.id_sucursal, null, null, 'Cargo', p.total, 'Fiado', v_factura, 'Autoservicio ' || v_num);
    end if;
    update pagos_autoservicio set estado = 'Aprobado', metodo_pago = p_metodo, proveedor = p_proveedor,
           ref_externa = p_ref, id_factura = v_factura, resuelto = now() where id_pago = p_id_pago;
  exception when others then
    if p_metodo = 'Fiado' then   -- no hubo dinero de por medio: simplemente no se vendió
      update pagos_autoservicio set estado = 'Rechazado', metodo_pago = p_metodo, nota = left(sqlerrm, 250), resuelto = now() where id_pago = p_id_pago;
      return jsonb_build_object('estado', 'Rechazado', 'motivo', sqlerrm);
    end if;
    update pagos_autoservicio set estado = 'Pago sin venta', metodo_pago = p_metodo, proveedor = p_proveedor,
           ref_externa = p_ref, nota = left(sqlerrm, 250), resuelto = now() where id_pago = p_id_pago;
    return jsonb_build_object('estado', 'Pago sin venta', 'motivo', sqlerrm);
  end;
  return jsonb_build_object('estado', 'Aprobado', 'id_factura', v_factura, 'numero_factura', v_num);
end $$;
revoke all on function app.autoservicio_vender(uuid, text, text, text) from public, anon, authenticated;

-- ---------- Confirmación de la pasarela (solo clave de servicio; solo para pagos en modo pasarela) ----------
create or replace function public.autoservicio_confirmar_pago(p_id_pago uuid, p_aprobado boolean, p_metodo text,
                                                              p_proveedor text, p_ref_externa text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from pagos_autoservicio where id_pago = p_id_pago for update;
  if not found then raise exception 'Pago no encontrado'; end if;
  if p.estado not in ('Pendiente','Vencido') then
    return jsonb_build_object('estado', p.estado, 'id_factura', p.id_factura, 'repetido', true); end if;
  if p.modo <> 'pasarela' then raise exception 'Este pago no es de pasarela'; end if;
  if not p_aprobado then
    update pagos_autoservicio set estado = 'Rechazado', metodo_pago = p_metodo, proveedor = p_proveedor,
           ref_externa = p_ref_externa, resuelto = now() where id_pago = p_id_pago;
    return jsonb_build_object('estado', 'Rechazado');
  end if;
  if p_metodo is null or p_metodo not in ('Nequi','Daviplata','Bre-B','Tarjeta','PSE') then
    raise exception 'Método de pago no válido: %', p_metodo; end if;
  return app.autoservicio_vender(p_id_pago, p_metodo, p_proveedor, p_ref_externa);
end $$;
revoke all on function public.autoservicio_confirmar_pago(uuid, boolean, text, text, text) from public, anon, authenticated;
grant execute on function public.autoservicio_confirmar_pago(uuid, boolean, text, text, text) to service_role;

-- ---------- Catálogo público (ahora indica cómo se paga en esa tienda) ----------
create or replace function public.autoservicio_catalogo(p_sucursal integer)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  select jsonb_build_object('comercio', c.nombre_comercial, 'sucursal', s.nombre_sucursal,
    'modo_pago', s.modo_pago_auto, 'llave_breb', case when s.modo_pago_auto = 'comprobante' then s.llave_breb end,
    'titular_breb', case when s.modo_pago_auto = 'comprobante' then s.titular_breb end, 'tope', s.tope_sin_verificar,
    'productos', coalesce((select jsonb_agg(jsonb_build_object('id_producto', p.id_producto, 'nombre', p.nombre,
         'precio', p.precio_venta, 'codigo_barras', p.codigo_barras, 'stock', i.stock) order by p.nombre)
       from inventarios_sucursal i join productos p on p.id_producto = i.id_producto and p.activo
      where i.id_sucursal = s.id_sucursal and i.stock > 0), '[]'::jsonb))
    into v from sucursales s join comercios c on c.id_comercio = s.id_comercio
   where s.id_sucursal = p_sucursal and s.autoservicio;
  if v is null then raise exception 'Esta tienda no tiene autoservicio'; end if;
  return v;
end $$;

-- ---------- Crear el cobro (precios del servidor; con p_fiado=true vende de inmediato a la cuenta aprobada del cliente) ----------
drop function if exists public.autoservicio_crear_pago(integer, jsonb);
create or replace function public.autoservicio_crear_pago(p_sucursal integer, p_items jsonb, p_fiado boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record; v_lineas jsonb; l jsonb; v_total numeric(12,2) := 0; v_id uuid; v_ref text; v_stock integer;
  v_modo text; v_uid uuid := auth.uid(); v_cli integer; v_res jsonb;
begin
  select id_comercio, modo_pago_auto, llave_breb, titular_breb, tope_sin_verificar into s from sucursales where id_sucursal = p_sucursal and autoservicio;
  if not found then raise exception 'Esta tienda no tiene autoservicio'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El carrito está vacío'; end if;
  if jsonb_array_length(p_items) > 60 then raise exception 'El carrito tiene demasiados productos'; end if;
  if (select count(*) from pagos_autoservicio where id_sucursal = p_sucursal and estado = 'Pendiente' and expira > now()) >= 300 then
    raise exception 'La tienda está recibiendo demasiados pedidos. Intenta en unos minutos'; end if;

  select jsonb_agg(jsonb_build_object('id_producto', i.id_producto, 'cantidad', i.cant, 'nombre', p.nombre,
                                      'precio', p.precio_venta, 'iva', p.iva_porcentaje) order by p.nombre)
    into v_lineas
    from (select (x->>'id_producto')::integer as id_producto, sum((x->>'cantidad')::integer) as cant
            from jsonb_array_elements(p_items) x group by 1) i
    left join productos p on p.id_producto = i.id_producto and p.id_comercio = s.id_comercio and p.activo;
  for l in select * from jsonb_array_elements(v_lineas) loop
    if l->>'nombre' is null then raise exception 'Un producto del carrito no existe'; end if;
    if (l->>'cantidad')::integer < 1 or (l->>'cantidad')::integer > 99 then raise exception 'Cantidad no válida para %', l->>'nombre'; end if;
    select stock into v_stock from inventarios_sucursal where id_sucursal = p_sucursal and id_producto = (l->>'id_producto')::integer;
    if coalesce(v_stock, 0) < (l->>'cantidad')::integer then
      raise exception 'No hay suficiente stock de % (quedan %)', l->>'nombre', coalesce(v_stock, 0); end if;
    v_total := v_total + (l->>'cantidad')::integer * (l->>'precio')::numeric;
  end loop;

  v_modo := case when coalesce(p_fiado, false) then 'fiado' else s.modo_pago_auto end;
  if v_modo = 'fiado' then
    if v_uid is null then raise exception 'Inicia sesión para comprar a fiado'; end if;
    select ca.id_cliente into v_cli from clientes_autoservicio ca where ca.auth_user_id = v_uid and ca.id_comercio = s.id_comercio and ca.estado = 'Aprobado';
    if v_cli is null then raise exception 'Tu cuenta de fiado aún no está aprobada'; end if;
  elsif v_modo = 'comprobante' then
    if s.llave_breb is null then raise exception 'La tienda aún no configuró su llave Bre-B'; end if;
    if v_total > s.tope_sin_verificar then
      raise exception 'Esta compra pasa de $% (máximo para pagar con comprobante). Divide la compra o pide ayuda al personal', s.tope_sin_verificar::bigint; end if;
  end if;

  v_ref := 'AS-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
  insert into pagos_autoservicio (id_comercio, id_sucursal, referencia, lineas, total, modo, id_cliente)
  values (s.id_comercio, p_sucursal, v_ref, v_lineas, v_total, v_modo, v_cli) returning id_pago into v_id;

  if v_modo = 'fiado' then
    v_res := app.autoservicio_vender(v_id, 'Fiado', 'Fiado autoservicio', 'FIADO-' || v_ref);
    return jsonb_build_object('id_pago', v_id, 'referencia', v_ref, 'total', v_total, 'modo', 'fiado',
                              'estado', v_res->>'estado', 'motivo', v_res->>'motivo');
  end if;
  return jsonb_build_object('id_pago', v_id, 'referencia', v_ref, 'total', v_total, 'lineas', v_lineas, 'modo', v_modo, 'estado', 'Pendiente',
    'llave_breb', case when v_modo = 'comprobante' then s.llave_breb end, 'titular_breb', case when v_modo = 'comprobante' then s.titular_breb end);
end $$;

-- ---------- El cliente envía su comprobante Bre-B: la venta se registra "Por verificar" ----------
create or replace function public.autoservicio_enviar_comprobante(p_id_pago uuid, p_referencia text, p_ruta text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p record; v_ref text; v_res jsonb;
begin
  select * into p from pagos_autoservicio where id_pago = p_id_pago for update;
  if not found then raise exception 'Pago no encontrado'; end if;
  if p.modo <> 'comprobante' then raise exception 'Este pago no se hace con comprobante'; end if;
  if p.estado not in ('Pendiente','Vencido') or p.ruta_captura is not null then raise exception 'Este pago ya fue enviado'; end if;
  if p.expira < now() - interval '30 minutes' then raise exception 'El tiempo de este pago terminó. Habla con el personal de la tienda'; end if;
  v_ref := upper(regexp_replace(coalesce(p_referencia, ''), '\s', '', 'g'));
  if v_ref !~ '^[A-Z0-9-]{6,40}$' then
    raise exception 'Escribe el número de referencia tal como aparece en tu comprobante (solo letras y números)'; end if;
  if p_ruta is null or p_ruta !~ ('^' || p_id_pago::text || '/[A-Za-z0-9._-]+$') then raise exception 'Imagen no válida'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'capturas-autoservicio' and o.name = p_ruta) then
    raise exception 'La captura no se subió. Inténtalo de nuevo'; end if;
  if exists (select 1 from pagos_autoservicio x where x.id_comercio = p.id_comercio and x.ref_cliente = v_ref) then
    raise exception 'Ese número de referencia ya se usó en otra compra'; end if;

  update pagos_autoservicio set ref_cliente = v_ref, ruta_captura = p_ruta, verificacion = 'Por verificar' where id_pago = p_id_pago;
  v_res := app.autoservicio_vender(p_id_pago, 'Bre-B', 'Comprobante Bre-B', v_ref);
  return v_res;
end $$;

-- ---------- Estado del pago / comprobante para el cliente ----------
create or replace function public.autoservicio_estado(p_id_pago uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p record; f record; c record; v_saldo numeric(12,2); v_cupo numeric(12,2);
begin
  update pagos_autoservicio set estado = 'Vencido', resuelto = now() where id_pago = p_id_pago and estado = 'Pendiente' and expira <= now();
  select * into p from pagos_autoservicio where id_pago = p_id_pago;
  if not found then raise exception 'Pago no encontrado'; end if;
  select s.nombre_sucursal, co.nombre_comercial, s.llave_breb, s.titular_breb into c from sucursales s join comercios co on co.id_comercio = s.id_comercio where s.id_sucursal = p.id_sucursal;
  select numero_factura, fecha_emision, subtotal, impuestos into f from facturas where id_factura = p.id_factura;
  if p.metodo_pago = 'Fiado' and p.id_cliente is not null and p.estado = 'Aprobado' then
    select coalesce(sum(case when tipo = 'Cargo' then monto else -monto end), 0) into v_saldo from cartera_movimientos where id_cliente = p.id_cliente;
    select cupo_fiado into v_cupo from clientes where id_cliente = p.id_cliente;
  end if;
  return jsonb_build_object('estado', p.estado, 'referencia', p.referencia, 'total', p.total, 'lineas', p.lineas, 'modo', p.modo,
    'metodo_pago', p.metodo_pago, 'ref_externa', p.ref_externa, 'verificacion', p.verificacion,
    'nota', case when p.estado = 'Pago sin venta' then 'Tu pago fue recibido pero no pudimos completar la compra. Habla con el personal de la tienda.'
                 when p.estado = 'Rechazado' and p.modo = 'fiado' then p.nota end,
    'llave_breb', case when p.modo = 'comprobante' then c.llave_breb end, 'titular_breb', case when p.modo = 'comprobante' then c.titular_breb end,
    'saldo_fiado', v_saldo, 'cupo_fiado', v_cupo,
    'comercio', c.nombre_comercial, 'sucursal', c.nombre_sucursal,
    'numero_factura', f.numero_factura, 'fecha_emision', f.fecha_emision, 'subtotal', f.subtotal, 'impuestos', f.impuestos);
end $$;

-- ---------- Cuenta del cliente que entra con Google ----------
create or replace function public.autoservicio_mi_cuenta(p_sucursal integer)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_com integer; ca record; c record; v_saldo numeric(12,2); u record;
begin
  if v_uid is null then raise exception 'Inicia sesión'; end if;
  select id_comercio into v_com from sucursales where id_sucursal = p_sucursal and autoservicio;
  if v_com is null then raise exception 'Esta tienda no tiene autoservicio'; end if;
  select email, coalesce(raw_user_meta_data->>'full_name', raw_user_meta_data->>'name') as nombre into u from auth.users where id = v_uid;
  select * into ca from clientes_autoservicio where auth_user_id = v_uid and id_comercio = v_com;
  if not found then return jsonb_build_object('registrado', false, 'email', u.email, 'nombre', u.nombre); end if;
  select nombre, telefono, cupo_fiado into c from clientes where id_cliente = ca.id_cliente;
  select coalesce(sum(case when tipo = 'Cargo' then monto else -monto end), 0) into v_saldo from cartera_movimientos where id_cliente = ca.id_cliente;
  return jsonb_build_object('registrado', true, 'estado', ca.estado, 'nombre', c.nombre, 'telefono', c.telefono, 'email', ca.email,
    'cupo', c.cupo_fiado, 'saldo', v_saldo, 'disponible', case when ca.estado = 'Aprobado' then greatest(coalesce(c.cupo_fiado, 0) - v_saldo, 0) end);
end $$;

create or replace function public.autoservicio_registrar_cliente(p_sucursal integer, p_nombre text, p_telefono text, p_acepta boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_com integer; u record; v_tel text; v_nom text := btrim(coalesce(p_nombre, '')); v_id integer;
begin
  if v_uid is null then raise exception 'Inicia sesión'; end if;
  select id_comercio into v_com from sucursales where id_sucursal = p_sucursal and autoservicio;
  if v_com is null then raise exception 'Esta tienda no tiene autoservicio'; end if;
  if not coalesce(p_acepta, false) then raise exception 'Debes autorizar el tratamiento de tus datos para registrarte'; end if;
  if length(v_nom) < 3 or length(v_nom) > 100 then raise exception 'Escribe tu nombre completo'; end if;
  v_tel := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
  if length(v_tel) = 12 and left(v_tel, 2) = '57' then v_tel := substr(v_tel, 3); end if;
  if v_tel !~ '^3[0-9]{9}$' then raise exception 'Escribe un celular colombiano de 10 dígitos (empieza por 3)'; end if;
  select email, email_confirmed_at into u from auth.users where id = v_uid;
  if u.email is null or u.email_confirmed_at is null then raise exception 'Tu correo no está verificado'; end if;
  if exists (select 1 from clientes_autoservicio where auth_user_id = v_uid and id_comercio = v_com) then
    raise exception 'Ya enviaste tu solicitud. El dueño de la tienda la revisará'; end if;
  -- cupo 0: mientras no esté aprobado no puede fiar ni siquiera en el mostrador
  insert into clientes (id_comercio, nombre, telefono, email, cupo_fiado) values (v_com, v_nom, v_tel, u.email, 0) returning id_cliente into v_id;
  insert into clientes_autoservicio (id_cliente, id_comercio, auth_user_id, email, acepta_datos_en) values (v_id, v_com, v_uid, u.email, now());
  return jsonb_build_object('registrado', true, 'estado', 'Pendiente');
end $$;

-- ---------- Dueño: aprobar clientes y conciliar comprobantes ----------
create or replace function public.autoservicio_clientes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not app.es_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id_cliente', ca.id_cliente, 'nombre', c.nombre, 'telefono', c.telefono, 'email', ca.email,
      'estado', ca.estado, 'cupo', c.cupo_fiado, 'creado', ca.creado,
      'saldo', (select coalesce(sum(case when m.tipo = 'Cargo' then m.monto else -m.monto end), 0) from cartera_movimientos m where m.id_cliente = ca.id_cliente))
      order by (ca.estado = 'Pendiente') desc, ca.creado desc)
    from clientes_autoservicio ca join clientes c on c.id_cliente = ca.id_cliente where ca.id_comercio = app.mi_comercio()), '[]'::jsonb);
end $$;

create or replace function public.autoservicio_decidir_cliente(p_id_cliente integer, p_aprobar boolean, p_cupo numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_com integer := app.mi_comercio();
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede aprobar clientes' using errcode = '42501'; end if;
  if not exists (select 1 from clientes_autoservicio where id_cliente = p_id_cliente and id_comercio = v_com) then raise exception 'Cliente no encontrado'; end if;
  if p_aprobar then
    if p_cupo is null or p_cupo <= 0 or p_cupo > 5000000 then raise exception 'Indica un cupo entre $1 y $5.000.000'; end if;
    update clientes set cupo_fiado = p_cupo where id_cliente = p_id_cliente;
    update clientes_autoservicio set estado = 'Aprobado', resuelto = now(), resuelto_por = app.mi_empleado() where id_cliente = p_id_cliente;
  else
    update clientes set cupo_fiado = 0 where id_cliente = p_id_cliente;
    update clientes_autoservicio set estado = 'Rechazado', resuelto = now(), resuelto_por = app.mi_empleado() where id_cliente = p_id_cliente;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.autoservicio_verificar(p_id_pago uuid, p_resultado text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_com integer := app.mi_comercio();
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede conciliar' using errcode = '42501'; end if;
  if p_resultado not in ('Verificado','Dudoso') then raise exception 'Resultado no válido'; end if;
  update pagos_autoservicio set verificacion = p_resultado, verificado_por = app.mi_empleado(), verificado_en = now(),
         nota_verificacion = nullif(btrim(coalesce(p_nota, '')), '')
   where id_pago = p_id_pago and id_comercio = v_com and verificacion in ('Por verificar','Dudoso');
  if not found then raise exception 'Pago no encontrado o ya conciliado'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.autoservicio_configurar(p_sucursal integer, p_modo text, p_llave text, p_titular text, p_tope numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not app.es_admin() then raise exception 'Solo el administrador' using errcode = '42501'; end if;
  if p_modo not in ('pasarela','comprobante') then raise exception 'Modo de pago no válido'; end if;
  if p_modo = 'comprobante' and (btrim(coalesce(p_llave, '')) = '' or btrim(coalesce(p_titular, '')) = '') then
    raise exception 'Indica la llave Bre-B y el nombre del titular'; end if;
  if p_tope is null or p_tope <= 0 or p_tope > 1000000 then raise exception 'El tope debe estar entre $1 y $1.000.000'; end if;
  update sucursales set modo_pago_auto = p_modo, llave_breb = nullif(btrim(coalesce(p_llave, '')), ''),
         titular_breb = nullif(btrim(coalesce(p_titular, '')), ''), tope_sin_verificar = p_tope
   where id_sucursal = p_sucursal and autoservicio and id_comercio = app.mi_comercio();
  if not found then raise exception 'Sede de autoservicio no encontrada'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Permisos ----------
revoke all on function public.autoservicio_catalogo(integer) from public, anon, authenticated;
revoke all on function public.autoservicio_crear_pago(integer, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.autoservicio_enviar_comprobante(uuid, text, text) from public, anon, authenticated;
revoke all on function public.autoservicio_estado(uuid) from public, anon, authenticated;
revoke all on function public.autoservicio_mi_cuenta(integer) from public, anon, authenticated;
revoke all on function public.autoservicio_registrar_cliente(integer, text, text, boolean) from public, anon, authenticated;
revoke all on function public.autoservicio_clientes() from public, anon, authenticated;
revoke all on function public.autoservicio_decidir_cliente(integer, boolean, numeric) from public, anon, authenticated;
revoke all on function public.autoservicio_verificar(uuid, text, text) from public, anon, authenticated;
revoke all on function public.autoservicio_configurar(integer, text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.autoservicio_catalogo(integer) to anon, authenticated;
grant execute on function public.autoservicio_crear_pago(integer, jsonb, boolean) to anon, authenticated;
grant execute on function public.autoservicio_enviar_comprobante(uuid, text, text) to anon, authenticated;
grant execute on function public.autoservicio_estado(uuid) to anon, authenticated;
grant execute on function public.autoservicio_mi_cuenta(integer) to authenticated;
grant execute on function public.autoservicio_registrar_cliente(integer, text, text, boolean) to authenticated;
grant execute on function public.autoservicio_clientes() to authenticated;
grant execute on function public.autoservicio_decidir_cliente(integer, boolean, numeric) to authenticated;
grant execute on function public.autoservicio_verificar(uuid, text, text) to authenticated;
grant execute on function public.autoservicio_configurar(integer, text, text, text, numeric) to authenticated;

-- Listado de facturas: añade el estado de verificación (al final)
create or replace view v_facturas_recientes with (security_invoker = true) as
select f.id_factura, f.numero_factura, f.fecha_emision, f.total_facturado, f.metodo_pago,
       s.nombre_sucursal as sucursal, coalesce(e.nombre, 'Autoservicio')::varchar(100) as cajero,
       coalesce((select sum(nc.total_reversado) from notas_credito nc where nc.id_factura = f.id_factura), 0) as devuelto,
       p.id_sucursal, p.id_empleado, c.nombre as cliente,
       coalesce((select sum(df.cantidad) from detalles_factura df where df.id_factura = f.id_factura), 0)::int as unidades,
       (select count(*) from comprobantes_pago cp where cp.id_factura = f.id_factura)::int as n_comprobantes,
       (select pa.ref_externa from pagos_autoservicio pa where pa.id_factura = f.id_factura limit 1) as ref_pasarela,
       (select pa.verificacion from pagos_autoservicio pa where pa.id_factura = f.id_factura limit 1) as verificacion
  from facturas f
  join pedidos p on p.id_pedido = f.id_pedido
  join sucursales s on s.id_sucursal = p.id_sucursal
  left join empleados e on e.id_empleado = p.id_empleado
  left join clientes c on c.id_cliente = p.id_cliente;
grant select on v_facturas_recientes to authenticated;
