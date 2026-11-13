-- =============================================================================
-- SURTIFY · 17_roles_permisos.sql
--   Roles reales con permisos que el dueño activa con casillas (Bodega, Contabilidad, los que invente).
--   * permisos_catalogo: lista cerrada de permisos (lo que se puede marcar).
--   * roles_permisos: qué permisos tiene cada rol. El rol con es_administrador lo puede todo.
--   * app.tiene_permiso(clave): la usan las funciones y políticas (se aplica en la base, no solo en la pantalla).
--   * Gestionar equipo y roles sigue siendo EXCLUSIVO del administrador (no es un permiso delegable).
--   * Roles existentes que no son administrador conservan lo que ya podían hacer (vender, fiados, reportes de su sede).
-- =============================================================================
create table if not exists permisos_catalogo (
  clave       text primary key,
  grupo       text not null,
  nombre      text not null,
  descripcion text not null,
  orden       integer not null
);
alter table permisos_catalogo enable row level security;
revoke all on permisos_catalogo from anon, authenticated;
grant select on permisos_catalogo to authenticated;
drop policy if exists "permcat_select" on permisos_catalogo;
create policy "permcat_select" on permisos_catalogo for select to authenticated using (true);

insert into permisos_catalogo (clave, grupo, nombre, descripcion, orden) values
  ('vender',       'Caja',      'Vender y manejar la caja',       'Abrir y cerrar caja, cobrar ventas, registrar gastos y devoluciones.', 1),
  ('fiados',       'Clientes',  'Fiados y clientes',              'Crear clientes, fiar y registrar abonos.', 2),
  ('inventario',   'Productos', 'Editar productos e inventario',  'Crear productos, ajustar stock, importar desde Excel.', 3),
  ('compras',      'Productos', 'Ver sugerencias de compra',      'Qué pedir a proveedores según lo que se vende.', 4),
  ('reportes',     'Ventas',    'Reportes y facturas',            'Reporte para el contador y consulta de facturas.', 5),
  ('panel',        'Ventas',    'Panel del negocio (Hoy)',        'Resumen de ventas, caja e inventario de todo el negocio.', 6),
  ('autoservicio', 'Clientes',  'Autoservicio y pagos Bre-B',     'Verificar comprobantes, aprobar clientes y configurar el autoservicio.', 7),
  ('todas_sedes',  'Alcance',   'Ver todas las sedes',            'Sin esto, la persona solo ve la información de su sede.', 8)
on conflict (clave) do update set grupo = excluded.grupo, nombre = excluded.nombre, descripcion = excluded.descripcion, orden = excluded.orden;

create table if not exists roles_permisos (
  id_role integer not null references roles(id_role) on delete cascade,
  permiso text    not null references permisos_catalogo(clave) on update cascade on delete cascade,
  primary key (id_role, permiso)
);
alter table roles_permisos enable row level security;
revoke all on roles_permisos from anon, authenticated;
grant select on roles_permisos to authenticated;
drop policy if exists "rolperm_select" on roles_permisos;
create policy "rolperm_select" on roles_permisos for select to authenticated
  using (exists (select 1 from roles r where r.id_role = roles_permisos.id_role and r.id_comercio = (select app.mi_comercio())));

-- ---------- Helper ----------
create or replace function app.tiene_permiso(p_clave text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select r.es_administrador or exists (select 1 from roles_permisos rp where rp.id_role = r.id_role and rp.permiso = p_clave)
                     from empleados e join roles r on r.id_role = e.id_role
                    where e.auth_user_id = auth.uid() and e.activo limit 1), false)
$$;
revoke all on function app.tiene_permiso(text) from public, anon;
grant execute on function app.tiene_permiso(text) to authenticated;

-- ---------- Visibilidad por sede: "todas_sedes" reemplaza a "ser administrador" ----------
create or replace function app.puede_ver_sucursal(p_id_sucursal integer)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from sucursales s
                 where s.id_sucursal = p_id_sucursal
                   and s.id_comercio = app.mi_comercio()
                   and (app.tiene_permiso('todas_sedes') or s.id_sucursal = app.mi_sucursal()))
$$;

drop policy if exists "sesiones_select" on sesiones_caja;
create policy "sesiones_select" on sesiones_caja for select to authenticated
  using (app.puede_ver_sucursal(id_sucursal) and ((select app.tiene_permiso('todas_sedes')) or id_empleado = (select app.mi_empleado())));
drop policy if exists "cliauto_select" on clientes_autoservicio;
create policy "cliauto_select" on clientes_autoservicio for select to authenticated
  using (id_comercio = (select app.mi_comercio()) and (select app.tiene_permiso('autoservicio')));

-- ---------- Datos: roles actuales + Bodega y Contabilidad por comercio ----------
-- Los roles no administradores que ya existían conservan lo que hacían.
insert into roles_permisos (id_role, permiso)
select r.id_role, p.clave from roles r cross join (values ('vender'), ('fiados'), ('reportes')) p(clave)
 where not r.es_administrador
   and not exists (select 1 from roles_permisos x where x.id_role = r.id_role)
on conflict do nothing;

insert into roles (id_comercio, nombre_rol, descripcion, es_administrador)
select c.id_comercio, v.nombre, v.descr, false
  from comercios c cross join (values
    ('Bodega',       'Maneja productos, inventario y compras. No vende ni ve la plata.'),
    ('Contabilidad', 'Ve reportes, facturas y fiados de todas las sedes. No modifica inventario.')) v(nombre, descr)
 where not exists (select 1 from roles r where r.id_comercio = c.id_comercio and lower(r.nombre_rol) = lower(v.nombre));

insert into roles_permisos (id_role, permiso)
select r.id_role, p.clave from roles r
  join (values ('Bodega','inventario'), ('Bodega','compras'),
               ('Contabilidad','reportes'), ('Contabilidad','fiados'), ('Contabilidad','todas_sedes'), ('Contabilidad','panel')) p(rol, clave)
    on lower(r.nombre_rol) = lower(p.rol)
 where not r.es_administrador
   and not exists (select 1 from roles_permisos x where x.id_role = r.id_role)
on conflict do nothing;

-- ---------- Cambiar las compuertas de las funciones existentes ----------
-- (se reescribe la definición actual de cada función: mismo código, otra condición)
do $$
declare
  rec record; v_def text; v_new text;
  v_guard constant text := ' if not app.tiene_permiso(%L) then raise exception ''Tu rol no tiene permiso para esto'' using errcode = ''42501''; end if;';
begin
  -- 1) Funciones que exigían ser administrador: ahora exigen el permiso que corresponde
  for rec in select * from (values
      ('ajustar_stock(integer,integer,integer,integer)',            'inventario'),
      ('crear_producto(text,numeric,numeric,text,integer,integer,integer,integer)', 'inventario'),
      ('importar_productos(integer,jsonb,boolean)',                  'inventario'),
      ('panel_multisede(integer)',                                   'panel'),
      ('sugerencias_compra(integer,integer,integer)',                'compras'),
      ('autoservicio_clientes()',                                    'autoservicio'),
      ('autoservicio_configurar(integer,text,text,text,numeric)',    'autoservicio'),
      ('autoservicio_decidir_cliente(integer,boolean,numeric)',      'autoservicio'),
      ('autoservicio_verificar(uuid,text,text)',                     'autoservicio')) t(f, perm) loop
    v_def := pg_get_functiondef(('public.' || rec.f)::regprocedure);
    v_new := replace(v_def, 'app.es_admin()', format('app.tiene_permiso(%L)', rec.perm));
    if v_new = v_def then raise exception 'Sin cambios en %', rec.f; end if;
    execute v_new;
  end loop;

  -- 2) Funciones de caja y clientes: antes las podía usar cualquier empleado activo; ahora exigen su permiso
  for rec in select * from (values
      ('abrir_caja(numeric)',                          'vender'),
      ('cerrar_caja(numeric)',                         'vender'),
      ('resumen_caja()',                               'vender'),
      ('registrar_gasto(numeric,text,text)',           'vender'),
      ('registrar_venta(jsonb,text,numeric,integer,text)', 'vender'),
      ('registrar_devolucion(integer,jsonb,text)',     'vender'),
      ('devolucion_disponible(integer)',               'vender'),
      ('crear_cliente(text,text,text,numeric)',        'fiados'),
      ('registrar_abono(integer,numeric,text,text)',   'fiados'),
      ('estado_cuenta(integer)',                       'fiados')) t(f, perm) loop
    v_def := pg_get_functiondef(('public.' || rec.f)::regprocedure);
    if position('app.tiene_permiso' in v_def) > 0 then continue; end if;
    v_new := regexp_replace(v_def, '\mbegin\M', 'begin' || format(v_guard, rec.perm), 1, 1, 'i');
    if v_new = v_def then raise exception 'Sin cambios en %', rec.f; end if;
    execute v_new;
  end loop;

  -- 3) Reporte del contador: exige "reportes"; el alcance (todas las sedes o solo la suya) lo da "todas_sedes"
  v_def := pg_get_functiondef('public.reporte_contador(date,date,integer)'::regprocedure);
  v_new := replace(v_def, 'v_adm boolean := app.es_admin()', 'v_adm boolean := app.tiene_permiso(''todas_sedes'')');
  if v_new = v_def then raise exception 'Sin cambios en reporte_contador'; end if;
  v_def := v_new;
  v_new := regexp_replace(v_def, '\mbegin\M', 'begin' || format(v_guard, 'reportes'), 1, 1, 'i');
  if v_new = v_def then raise exception 'Sin guardia en reporte_contador'; end if;
  execute v_new;
end $$;

-- ---------- Perfil: incluye la lista de permisos ----------
create or replace function public.perfil_actual()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id_empleado', e.id_empleado, 'nombre', e.nombre, 'email', e.email,
    'id_sucursal', e.id_sucursal, 'nombre_sucursal', s.nombre_sucursal,
    'id_comercio', s.id_comercio, 'nombre_comercial', c.nombre_comercial,
    'rol', r.nombre_rol, 'es_administrador', coalesce(r.es_administrador, false),
    'permisos', case when coalesce(r.es_administrador, false)
                  then (select coalesce(jsonb_agg(clave order by orden), '[]'::jsonb) from permisos_catalogo)
                  else coalesce((select jsonb_agg(rp.permiso order by pc.orden) from roles_permisos rp
                                  join permisos_catalogo pc on pc.clave = rp.permiso where rp.id_role = r.id_role), '[]'::jsonb) end)
  from empleados e
  join sucursales s on s.id_sucursal = e.id_sucursal
  join comercios c on c.id_comercio = s.id_comercio
  left join roles r on r.id_role = e.id_role
  where e.auth_user_id = auth.uid() and e.activo
$$;

-- ---------- Gestión de roles (solo administrador) ----------
create or replace function public.roles_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_com integer := app.mi_comercio();
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede gestionar los roles' using errcode = '42501'; end if;
  return jsonb_build_object(
    'catalogo', coalesce((select jsonb_agg(jsonb_build_object('clave', clave, 'grupo', grupo, 'nombre', nombre, 'descripcion', descripcion) order by orden)
                           from permisos_catalogo), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(jsonb_build_object(
        'id_role', r.id_role, 'nombre_rol', r.nombre_rol, 'descripcion', r.descripcion, 'es_administrador', r.es_administrador,
        'permisos', coalesce((select jsonb_agg(rp.permiso order by pc.orden) from roles_permisos rp join permisos_catalogo pc on pc.clave = rp.permiso
                               where rp.id_role = r.id_role), '[]'::jsonb),
        'personas', (select count(*) from empleados e where e.id_role = r.id_role and e.activo))
        order by r.es_administrador desc, r.nombre_rol) from roles r where r.id_comercio = v_com), '[]'::jsonb));
end $$;

create or replace function public.roles_guardar(p_id_role integer, p_nombre text, p_descripcion text, p_permisos text[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_com integer := app.mi_comercio(); v_id integer; v_nom text := btrim(coalesce(p_nombre, '')); v_perm text[] := coalesce(p_permisos, '{}');
        v_rol roles%rowtype; v_antes text;
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede gestionar los roles' using errcode = '42501'; end if;
  if char_length(v_nom) < 2 or char_length(v_nom) > 40 then raise exception 'El nombre del rol debe tener entre 2 y 40 letras'; end if;
  if char_length(coalesce(p_descripcion, '')) > 160 then raise exception 'La descripción es muy larga (máximo 160 letras)'; end if;
  if exists (select 1 from unnest(v_perm) x where x not in (select clave from permisos_catalogo)) then raise exception 'Permiso no válido'; end if;
  if exists (select 1 from roles r where r.id_comercio = v_com and lower(r.nombre_rol) = lower(v_nom) and r.id_role is distinct from p_id_role)
    then raise exception 'Ya existe un rol con ese nombre'; end if;

  if p_id_role is null then
    insert into roles (id_comercio, nombre_rol, descripcion, es_administrador) values (v_com, v_nom, nullif(btrim(coalesce(p_descripcion, '')), ''), false)
      returning id_role into v_id;
    perform app.equipo_log(v_com, app.mi_empleado(), null, 'rol_creado', v_nom);
  else
    select * into v_rol from roles where id_role = p_id_role and id_comercio = v_com;
    if not found then raise exception 'Rol no encontrado'; end if;
    if v_rol.es_administrador then raise exception 'El rol de administrador no se puede modificar'; end if;
    v_id := p_id_role;
    update roles set nombre_rol = v_nom, descripcion = nullif(btrim(coalesce(p_descripcion, '')), '') where id_role = v_id;
    perform app.equipo_log(v_com, app.mi_empleado(), null, 'rol_editado', v_nom);
  end if;

  delete from roles_permisos where id_role = v_id;
  insert into roles_permisos (id_role, permiso) select distinct v_id, x from unnest(v_perm) x;
  return v_id;
end $$;

create or replace function public.roles_eliminar(p_id_role integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_com integer := app.mi_comercio(); v_rol roles%rowtype;
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede gestionar los roles' using errcode = '42501'; end if;
  select * into v_rol from roles where id_role = p_id_role and id_comercio = v_com;
  if not found then raise exception 'Rol no encontrado'; end if;
  if v_rol.es_administrador then raise exception 'El rol de administrador no se puede eliminar'; end if;
  if exists (select 1 from empleados where id_role = p_id_role) then
    raise exception 'Hay personas con este rol. Cámbiales el rol antes de eliminarlo';
  end if;
  delete from roles where id_role = p_id_role;
  perform app.equipo_log(v_com, app.mi_empleado(), null, 'rol_eliminado', v_rol.nombre_rol);
end $$;

do $$ declare f text; begin
  foreach f in array array['roles_listar()', 'roles_guardar(integer,text,text,text[])', 'roles_eliminar(integer)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
