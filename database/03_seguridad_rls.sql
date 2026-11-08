-- =============================================================================
-- SURTIFY · 03_seguridad_rls.sql
-- Control de acceso (el equivalente en Supabase del DCL GRANT/REVOKE del informe).
--
-- Modelo:
--   * anon (sin sesión): no ve nada, salvo la ficha "acerca de" del sistema.
--   * authenticated: ve SOLO los datos de su propio comercio (RLS por id_comercio).
--       - Administrador (Carlos): todas las sucursales de su comercio.
--       - Cajero (Rosa/Diana): solo su sucursal y sus propias sesiones de caja.
--   * Las tablas financieras (pedidos, facturas, caja, movimientos, gastos, notas)
--     NO tienen permisos de escritura desde el cliente: solo se modifican mediante
--     las funciones RPC de 02_funciones_y_triggers.sql (principio de menor privilegio).
-- =============================================================================

-- ---------- 1. Cerrar todo y abrir solo lo necesario ----------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema app    from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from public, anon, authenticated;

grant usage on schema app to authenticated;
grant execute on function app.mi_empleado(), app.mi_sucursal(), app.mi_comercio(),
                          app.es_admin(), app.puede_ver_sucursal(integer) to authenticated;

grant execute on function public.perfil_actual(), public.resumen_caja(), public.abrir_caja(numeric),
  public.registrar_venta(jsonb, text, numeric, integer, text),
  public.registrar_gasto(numeric, text, text), public.cerrar_caja(numeric) to authenticated;

-- ---------- 2. Activar RLS en TODAS las tablas ----------
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ---------- 3. Permisos de tabla (las políticas filtran las filas) ----------
grant select on all tables in schema public to authenticated;
grant select on sistema_acerca_de to anon;

grant update (nombre_comercial, razon_social, nit_rut) on comercios to authenticated;
grant insert, update on sucursales to authenticated;
grant insert, update, delete on roles, categorias, proveedores, clientes, inventarios_sucursal to authenticated;
grant insert, update on productos to authenticated;
grant update (id_sucursal, id_role, numero_identificacion, tipo_documento, nombre, salario, activo) on empleados to authenticated;

-- ---------- 4. Políticas ----------
-- Catálogos globales
create policy "acerca_de_lectura" on sistema_acerca_de for select to anon, authenticated using (true);
create policy "modulos_lectura"   on modulos_suscripcion for select to authenticated using (true);

-- Comercio / suscripciones / sucursales
create policy "comercio_select" on comercios for select to authenticated using (id_comercio = (select app.mi_comercio()));
create policy "comercio_update" on comercios for update to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()))
  with check (id_comercio = (select app.mi_comercio()));
create policy "suscripciones_select" on suscripciones_comercio for select to authenticated
  using (id_comercio = (select app.mi_comercio()));
create policy "sucursales_select" on sucursales for select to authenticated using (id_comercio = (select app.mi_comercio()));
create policy "sucursales_insert" on sucursales for insert to authenticated
  with check (id_comercio = (select app.mi_comercio()) and (select app.es_admin()));
create policy "sucursales_update" on sucursales for update to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()))
  with check (id_comercio = (select app.mi_comercio()));

-- Roles y permisos
create policy "roles_select" on roles for select to authenticated using (id_comercio = (select app.mi_comercio()));
create policy "roles_admin_write" on roles for all to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()))
  with check (id_comercio = (select app.mi_comercio()) and (select app.es_admin()));
create policy "permisos_select" on permisos_rol_modulo for select to authenticated
  using (exists (select 1 from roles r where r.id_role = permisos_rol_modulo.id_role));

-- Empleados: el admin ve a todos los de su comercio; el cajero solo su propio registro
create policy "empleados_select" on empleados for select to authenticated
  using (exists (select 1 from sucursales s where s.id_sucursal = empleados.id_sucursal and s.id_comercio = (select app.mi_comercio()))
         and ((select app.es_admin()) or id_empleado = (select app.mi_empleado())));
create policy "empleados_update" on empleados for update to authenticated
  using ((select app.es_admin())
         and exists (select 1 from sucursales s where s.id_sucursal = empleados.id_sucursal and s.id_comercio = (select app.mi_comercio())))
  with check (exists (select 1 from sucursales s where s.id_sucursal = empleados.id_sucursal and s.id_comercio = (select app.mi_comercio()))
              and (id_role is null or exists (select 1 from roles r where r.id_role = empleados.id_role)));

-- Catálogo
create policy "categorias_select" on categorias for select to authenticated using (id_comercio = (select app.mi_comercio()));
create policy "categorias_admin_write" on categorias for all to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()))
  with check (id_comercio = (select app.mi_comercio()) and (select app.es_admin()));
create policy "proveedores_admin" on proveedores for all to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()))
  with check (id_comercio = (select app.mi_comercio()) and (select app.es_admin()));
create policy "productos_select" on productos for select to authenticated using (id_comercio = (select app.mi_comercio()));
create policy "productos_insert" on productos for insert to authenticated
  with check (id_comercio = (select app.mi_comercio()) and (select app.es_admin())
              and (id_categoria is null or exists (select 1 from categorias c where c.id_categoria = productos.id_categoria)));
create policy "productos_update" on productos for update to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()))
  with check (id_comercio = (select app.mi_comercio())
              and (id_categoria is null or exists (select 1 from categorias c where c.id_categoria = productos.id_categoria)));

-- Inventario: lectura por sucursal visible; escritura manual solo admin
create policy "inventario_select" on inventarios_sucursal for select to authenticated
  using (app.puede_ver_sucursal(id_sucursal));
create policy "inventario_admin_write" on inventarios_sucursal for all to authenticated
  using ((select app.es_admin()) and app.puede_ver_sucursal(id_sucursal))
  with check ((select app.es_admin()) and app.puede_ver_sucursal(id_sucursal)
              and exists (select 1 from productos p where p.id_producto = inventarios_sucursal.id_producto));

-- Clientes: cualquier empleado puede registrarlos; borrar solo admin
create policy "clientes_select" on clientes for select to authenticated using (id_comercio = (select app.mi_comercio()));
create policy "clientes_insert" on clientes for insert to authenticated with check (id_comercio = (select app.mi_comercio()));
create policy "clientes_update" on clientes for update to authenticated
  using (id_comercio = (select app.mi_comercio())) with check (id_comercio = (select app.mi_comercio()));
create policy "clientes_delete" on clientes for delete to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.es_admin()));

-- Ventas y documentos: SOLO LECTURA desde el cliente (heredan visibilidad del padre)
create policy "pedidos_select" on pedidos for select to authenticated using (app.puede_ver_sucursal(id_sucursal));
create policy "detalles_pedido_select" on detalles_pedido for select to authenticated
  using (exists (select 1 from pedidos p where p.id_pedido = detalles_pedido.id_pedido));
create policy "facturas_select" on facturas for select to authenticated
  using (exists (select 1 from pedidos p where p.id_pedido = facturas.id_pedido));
create policy "detalles_factura_select" on detalles_factura for select to authenticated
  using (exists (select 1 from facturas f where f.id_factura = detalles_factura.id_factura));
create policy "notas_credito_select" on notas_credito for select to authenticated
  using (exists (select 1 from facturas f where f.id_factura = notas_credito.id_factura));
create policy "detalles_nota_select" on detalles_nota_credito for select to authenticated
  using (exists (select 1 from notas_credito n where n.id_nota_credito = detalles_nota_credito.id_nota_credito));

-- Caja: el cajero ve solo sus sesiones; el admin las de su comercio
create policy "sesiones_select" on sesiones_caja for select to authenticated
  using (app.puede_ver_sucursal(id_sucursal) and ((select app.es_admin()) or id_empleado = (select app.mi_empleado())));
create policy "movimientos_select" on movimientos_caja for select to authenticated
  using (exists (select 1 from sesiones_caja s where s.id_sesion = movimientos_caja.id_sesion));
create policy "gastos_select" on gastos_caja for select to authenticated
  using (exists (select 1 from sesiones_caja s where s.id_sesion = gastos_caja.id_sesion));
