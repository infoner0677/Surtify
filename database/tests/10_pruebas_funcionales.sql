-- Pruebas funcionales de la migración (PostgreSQL local + shim). Cada bloque imprime "OK Txx".
-- Ejecutar sobre una base recién migrada (01..04) con 00_shim_supabase_local.sql aplicado.
create schema if not exists test;
grant usage on schema test to anon, authenticated;

create or replace function test.uid_of(p_email text) returns uuid language sql as
  $$ select id from auth.users where email = p_email $$;
create or replace function test.expect_error(p_sql text, p_pattern text) returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then return; end if;
    raise exception 'FALLO: error inesperado [%] (se esperaba [%])', sqlerrm, p_pattern;
  end;
  raise exception 'FALLO: debía fallar con [%]: %', p_pattern, p_sql;
end $$;
grant execute on function test.expect_error(text, text) to anon, authenticated;

-- ---------- Preparación: usuarios Auth (se enlazan solos por email) + un segundo comercio ----------
insert into auth.users (email, email_confirmed_at) values
  ('carlos.mendoza@eltriunfo.com', now()), ('diana.gomez@eltriunfo.com', now());
do $$
declare v_com int; v_suc int; v_rol int; v_cat int; v_prod int;
begin
  insert into comercios (nombre_comercial, nit_rut, prefijo_factura) values ('Tienda Rival', '800000001-1', 'RIV') returning id_comercio into v_com;
  insert into sucursales (id_comercio, nombre_sucursal, direccion) values (v_com, 'Sede Rival', 'Cra 1 # 1-1') returning id_sucursal into v_suc;
  insert into roles (id_comercio, nombre_rol, es_administrador) values (v_com, 'Dueño', true) returning id_role into v_rol;
  insert into empleados (id_sucursal, id_role, nombre, salario, email) values (v_suc, v_rol, 'Rival Dueño', 1000000, 'rival@rival.com');
  insert into categorias (id_comercio, nombre) values (v_com, 'General') returning id_categoria into v_cat;
  insert into productos (id_comercio, id_categoria, nombre, precio_venta, codigo_barras) values (v_com, v_cat, 'Producto Rival', 1000, '999') returning id_producto into v_prod;
  insert into inventarios_sucursal (id_sucursal, id_producto, stock) values (v_suc, v_prod, 10);
end $$;
insert into auth.users (email, email_confirmed_at) values ('rival@rival.com', now());

do $$ begin
  assert (select count(*) from empleados where auth_user_id is not null) = 3, 'Los 3 empleados debían enlazarse con Auth';
  raise notice 'OK T01 trigger de vinculación Auth <-> empleados';
end $$;

-- ---------- Seguridad básica ----------
do $$ begin
  perform set_config('role', 'anon', true);
  perform test.expect_error('select * from productos', 'permission denied');
  perform test.expect_error('select public.abrir_caja(1000)', 'permission denied');
  assert (select count(*) from sistema_acerca_de) = 8, 'anon debe leer la ficha acerca_de';
  raise notice 'OK T02 anon: sin acceso a datos ni funciones; solo ficha del sistema';
end $$;

-- ---------- Flujo de caja de Diana (cajera) ----------
do $$ begin
  perform set_config('request.jwt.claim.sub', test.uid_of('diana.gomez@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  assert (public.perfil_actual()->>'rol') = 'Cajero / Operador' and (public.perfil_actual()->>'es_administrador')::boolean = false, 'perfil cajero';
  perform test.expect_error($q$select public.registrar_venta('[{"id_producto":1,"cantidad":1}]', 'Efectivo')$q$, 'abrir la caja');
  perform public.abrir_caja(50000);
  perform test.expect_error('select public.abrir_caja(1000)', 'Ya tienes una caja abierta');
  raise notice 'OK T03/T04/T05 perfil cajero, no vende sin caja, no abre dos cajas';
end $$;

do $$
declare r jsonb; v_jamon int; v_queso int;
begin
  select id_producto into v_jamon from productos where codigo_barras = '7701234560010';
  select id_producto into v_queso from productos where codigo_barras = '7709876540032';
  perform set_config('request.jwt.claim.sub', test.uid_of('diana.gomez@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  -- Venta idéntica a la del informe: 3 jamones + 1 queso = $73.500 pagados con $100.000
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', v_jamon, 'cantidad', 3),
                                                jsonb_build_object('id_producto', v_queso, 'cantidad', 1)), 'Efectivo', 100000);
  assert (r->>'total')::numeric = 73500 and (r->>'cambio')::numeric = 26500, 'total/cambio';
  assert (r->>'subtotal')::numeric = 61764.71 and (r->>'impuestos')::numeric = 11735.29, 'IVA igual al del informe';
  assert r->>'numero_factura' = 'SETR-0001', 'consecutivo';
  assert (select stock from inventarios_sucursal where id_producto = v_jamon) = 117, 'stock jamón 120-3';
  assert (select stock from inventarios_sucursal where id_producto = v_queso) = 79,  'stock queso 80-1';
  assert (select count(*) from movimientos_caja where id_factura = (r->>'id_factura')::int) = 1, 'UN solo movimiento por factura (bug de triggers duplicados corregido)';
  assert (public.resumen_caja()->>'monto_cierre_esperado')::numeric = 123500, 'esperado 50.000 + 73.500';
  raise notice 'OK T06 venta del informe: total, cambio, IVA, stock, 1 movimiento, efectivo esperado';
end $$;

do $$
declare r jsonb; v_huevos int; res jsonb;
begin
  select id_producto into v_huevos from productos where codigo_barras = '7703333000015';
  perform set_config('request.jwt.claim.sub', test.uid_of('diana.gomez@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', v_huevos, 'cantidad', 2)), 'Nequi');
  assert (r->>'total')::numeric = 42000 and (r->>'impuestos')::numeric = 0 and r->>'numero_factura' = 'SETR-0002', 'venta Nequi sin IVA';
  res := public.resumen_caja();
  assert (res->>'monto_cierre_esperado')::numeric = 123500, 'Nequi NO entra al cajón físico';
  assert (res->'ventas_por_metodo'->>'Nequi')::numeric = 42000 and (res->>'num_ventas')::int = 2, 'libro por método';
  res := public.registrar_gasto(12000, 'Papelería y Empaques', 'Bolsas');
  assert (res->>'monto_cierre_esperado')::numeric = 111500, 'gasto resta del efectivo';
  raise notice 'OK T07/T08 pago digital fuera del cajón, gasto resta efectivo';
end $$;

-- ---------- Integridad y validaciones ----------
do $$
declare v_jamon int; v_peds int; v_stock int;
begin
  select id_producto into v_jamon from productos where codigo_barras = '7701234560010';
  select count(*) into v_peds from pedidos; select stock into v_stock from inventarios_sucursal where id_producto = v_jamon;
  perform set_config('request.jwt.claim.sub', test.uid_of('diana.gomez@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  perform test.expect_error(format($q$select public.registrar_venta('[{"id_producto":%s,"cantidad":500}]', 'Efectivo')$q$, v_jamon), 'Stock insuficiente');
  perform set_config('role', 'postgres', true);
  assert (select count(*) from pedidos) = v_peds, 'venta fallida no deja pedido huérfano (atomicidad)';
  assert (select stock from inventarios_sucursal where id_producto = v_jamon) = v_stock, 'stock intacto tras venta fallida';
  perform set_config('role', 'authenticated', true);
  perform test.expect_error(format($q$select public.registrar_venta('[{"id_producto":%s,"cantidad":1}]', 'Efectivo', 100)$q$, v_jamon), 'menor al total');
  perform test.expect_error($q$select public.registrar_venta('[]', 'Efectivo')$q$, 'carrito está vacío');
  perform test.expect_error(format($q$select public.registrar_venta('[{"id_producto":%s,"cantidad":-2}]', 'Efectivo')$q$, v_jamon), 'Cantidad no válida');
  perform test.expect_error(format($q$select public.registrar_venta('[{"id_producto":%s,"cantidad":1}]', 'Bitcoin')$q$, v_jamon), 'Método de pago');
  raise notice 'OK T09/T10/T11 sobreventa bloqueada con rollback total; efectivo insuficiente, carrito vacío, cantidad negativa, método inválido';
end $$;

-- ---------- Aislamiento multi-inquilino y menor privilegio ----------
do $$
declare v_rival_prod int; v_rival_cli int;
begin
  select id_producto into v_rival_prod from productos where nombre = 'Producto Rival';
  perform set_config('request.jwt.claim.sub', test.uid_of('diana.gomez@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  assert (select count(*) from productos) = 9, 'Diana solo ve los 9 productos de su comercio';
  assert (select count(*) from comercios) = 1 and (select count(*) from empleados) = 1, 'cajero ve solo su registro de empleado';
  perform test.expect_error(format($q$select public.registrar_venta('[{"id_producto":%s,"cantidad":1}]', 'Efectivo')$q$, v_rival_prod), 'no pertenece a tu comercio');
  -- Escrituras directas prohibidas
  perform test.expect_error($q$insert into facturas (numero_factura, subtotal, total_facturado, metodo_pago) values ('X', 1, 1, 'Efectivo')$q$, 'permission denied');
  perform test.expect_error($q$update sesiones_caja set monto_cierre_esperado = 999999999$q$, 'permission denied');
  perform test.expect_error($q$delete from movimientos_caja$q$, 'permission denied');
  perform test.expect_error($q$update comercios set consecutivo_factura = 0$q$, 'permission denied');
  -- Políticas: UPDATE permitido por GRANT pero filtrado por RLS => 0 filas
  update productos set precio_venta = 1; assert not found, 'cajero NO puede cambiar precios';
  update inventarios_sucursal set stock = 9999; assert not found, 'cajero NO puede inflar stock a mano';
  update empleados set salario = 99999999; assert not found, 'cajero NO puede cambiarse el salario';
  raise notice 'OK T12/T13/T14 aislamiento entre comercios y cajero sin escritura directa a finanzas/precios/stock';
end $$;

do $$
declare v_rival_prod int;
begin
  perform set_config('request.jwt.claim.sub', test.uid_of('rival@rival.com')::text, true);
  perform set_config('role', 'authenticated', true);
  assert (select count(*) from productos) = 1 and (select count(*) from facturas) = 0 and (select count(*) from sesiones_caja) = 0, 'Rival no ve nada de El Triunfo';
  assert (select count(*) from v_reporte_critico_inventario) = 1, 'la vista respeta RLS (security_invoker)';
  raise notice 'OK T14b el otro comercio no ve datos ajenos (tablas ni vistas)';
end $$;

-- ---------- Admin ----------
do $$
declare v_jamon int;
begin
  select id_producto into v_jamon from productos where codigo_barras = '7701234560010';
  perform set_config('request.jwt.claim.sub', test.uid_of('carlos.mendoza@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  assert (public.perfil_actual()->>'es_administrador')::boolean, 'Carlos es admin';
  assert (select count(*) from sesiones_caja) = 1 and (select count(*) from empleados) = 2, 'admin ve sesiones y empleados de su comercio';
  assert (select count(*) from facturas) = 2, 'admin ve las facturas';
  update productos set precio_venta = 17000 where id_producto = v_jamon; assert found, 'admin sí cambia precios';
  update productos set precio_venta = 16500 where id_producto = v_jamon;
  perform test.expect_error($q$update comercios set consecutivo_factura = 0$q$, 'permission denied');
  raise notice 'OK T15 admin: ve todo su comercio, gestiona catálogo, no toca el consecutivo';
end $$;

-- ---------- Triggers de devolución e inmutabilidad (como postgres) ----------
do $$
declare v_fac int; v_nc int; v_jamon int; v_stock int; v_esp numeric;
begin
  select id_producto into v_jamon from productos where codigo_barras = '7701234560010';
  select id_factura into v_fac from facturas where numero_factura = 'SETR-0001';
  select stock into v_stock from inventarios_sucursal where id_producto = v_jamon;
  insert into notas_credito (id_factura, numero_nota, motivo_dian, total_reversado) values (v_fac, 'NC-0001', 'Devolución parcial', 16500) returning id_nota_credito into v_nc;
  insert into detalles_nota_credito (id_nota_credito, id_producto, cantidad_devuelta, precio_unitario_reversado, total_linea_reversado) values (v_nc, v_jamon, 1, 16500, 16500);
  assert (select stock from inventarios_sucursal where id_producto = v_jamon) = v_stock + 1, 'devolución reingresa stock';
  assert (select count(*) from movimientos_caja where id_nota_credito = v_nc and tipo_movimiento = 'Egreso') = 1, 'egreso por nota crédito';
  select monto_cierre_esperado into v_esp from sesiones_caja where estado_caja = 'Abierta';
  assert v_esp = 95000, 'esperado: 111.500 - 16.500 = 95.000';
  perform test.expect_error('update facturas set total_facturado = 1', 'inmutable');
  perform test.expect_error('delete from facturas', 'no puede eliminarse');
  perform test.expect_error('update detalles_factura set cantidad = 99', 'inmutable');
  update facturas set estado_dian = 'Enviado' where id_factura = v_fac;   -- esto sí está permitido
  raise notice 'OK T16/T19 nota crédito: stock y caja; facturas inmutables (salvo estado_dian)';
end $$;

-- ---------- Cierre de caja ----------
do $$
declare res jsonb;
begin
  perform set_config('request.jwt.claim.sub', test.uid_of('diana.gomez@eltriunfo.com')::text, true);
  perform set_config('role', 'authenticated', true);
  res := public.cerrar_caja(94500);
  assert res->>'estado' = 'Cerrada' and (res->>'diferencia')::numeric = -500 and (res->>'monto_cierre_esperado')::numeric = 95000, 'arqueo: faltante de $500';
  assert (res->>'total_gastos')::numeric = 12000 and (res->>'total_devoluciones')::numeric = 16500 and (res->>'total_ventas')::numeric = 115500, 'totales del arqueo';
  perform test.expect_error($q$select public.registrar_venta('[{"id_producto":1,"cantidad":1}]', 'Efectivo')$q$, 'abrir la caja');
  perform test.expect_error('select public.cerrar_caja(1)', 'No tienes una caja abierta');
  raise notice 'OK T17 cierre de caja con arqueo y bloqueo de ventas posteriores';
end $$;
