-- =============================================================================
-- SURTIFY · 04_datos_demo.sql
-- Datos de demostración del informe ACA: "Carnes & Salsas El Triunfo" (Restrepo).
-- Es idempotente: si el comercio demo ya existe, no hace nada.
--
-- Los empleados se crean SIN contraseña aquí. Para poder iniciar sesión, crea los
-- usuarios en Supabase: Authentication > Users > Add user (marca "Auto Confirm User")
-- con estos correos; el trigger los enlaza solo con su empleado:
--     carlos.mendoza@eltriunfo.com   (Administrador)
--     diana.gomez@eltriunfo.com      (Cajera)
-- =============================================================================
do $$
declare
  v_com int; v_suc int; v_rol_admin int; v_rol_cajero int; v_cat_carnes int; v_cat_lacteos int; v_cat_despensa int;
  v_prod int; rec record;
begin
  if exists (select 1 from comercios where nit_rut = '901234567-8') then
    raise notice 'El comercio demo ya existe; no se insertó nada.'; return;
  end if;

  insert into comercios (nombre_comercial, razon_social, nit_rut, prefijo_factura)
  values ('Carnes & Salsas El Triunfo', 'Distribuidora El Triunfo SAS', '901234567-8', 'SETR') returning id_comercio into v_com;

  if not exists (select 1 from modulos_suscripcion) then
    insert into modulos_suscripcion (nombre_modulo, descripcion, precio_mensual) values
      ('Control de Inventarios', 'Gestión de stock mínimo y alertas automáticas', 0),
      ('Facturación Electrónica DIAN', 'Emisión de facturas legales y notas crédito', 45000),
      ('Control Financiero y Caja', 'Arqueos, movimientos de caja, métodos de pago y vales', 25000);
  end if;

  insert into suscripciones_comercio (id_comercio, id_modulo, fecha_activacion, fecha_vencimiento, ciclo_facturacion, metodo_pago, estado)
  select v_com, id_modulo, current_date,
         case when nombre_modulo = 'Control de Inventarios' then current_date + interval '1 year' else current_date + interval '1 month' end,
         case when nombre_modulo = 'Control de Inventarios' then 'Anual' else 'Mensual' end,
         case when nombre_modulo = 'Control de Inventarios' then 'Gratuito' else 'Nequi' end, 'Activo'
    from modulos_suscripcion where nombre_modulo in ('Control de Inventarios', 'Control Financiero y Caja');

  insert into sucursales (id_comercio, nombre_sucursal, direccion, telefono)
  values (v_com, 'Sede Principal - Restrepo', 'Calle 18 Sur # 24-45', '6013214567') returning id_sucursal into v_suc;

  insert into roles (id_comercio, nombre_rol, descripcion, es_administrador)
  values (v_com, 'Administrador General', 'Acceso total: reportes, inventarios y personal', true) returning id_role into v_rol_admin;
  insert into roles (id_comercio, nombre_rol, descripcion, es_administrador)
  values (v_com, 'Cajero / Operador', 'Ventas POS, apertura/cierre de caja y gastos menores', false) returning id_role into v_rol_cajero;

  insert into empleados (id_sucursal, id_role, numero_identificacion, tipo_documento, nombre, salario, email) values
    (v_suc, v_rol_admin,  '1000000001', 'CC', 'Carlos Mendoza', 2500000, 'carlos.mendoza@eltriunfo.com'),
    (v_suc, v_rol_cajero, '1000000002', 'CC', 'Diana Gómez',    1400000, 'diana.gomez@eltriunfo.com');

  insert into categorias (id_comercio, nombre, descripcion) values (v_com, 'Carnes Frías y Embutidos', 'Salchichas, jamones, cábanos y embutidos') returning id_categoria into v_cat_carnes;
  insert into categorias (id_comercio, nombre, descripcion) values (v_com, 'Lácteos y Quesos', 'Quesos, mantequillas y derivados lácteos') returning id_categoria into v_cat_lacteos;
  insert into categorias (id_comercio, nombre, descripcion) values (v_com, 'Despensa', 'Huevos, salsas y abarrotes') returning id_categoria into v_cat_despensa;

  -- Los dos productos originales del informe (IVA 19 %) + productos de ejemplo. IVA de ejemplo: ajústalo a tu caso.
  for rec in select * from (values
    (v_cat_carnes,  'Jamón Premium Pierna x 500g',   16500, 19, '7701234560010', 120, 15),
    (v_cat_lacteos, 'Bloque Queso Doble Crema 1kg',  24000, 19, '7709876540032',  80, 10),
    (v_cat_carnes,  'Salchicha Ranchera x 8 und',    12500, 19, '7701111000011',  60, 10),
    (v_cat_carnes,  'Chorizo Antioqueño x 500g',     15800, 19, '7701111000028',  45,  8),
    (v_cat_carnes,  'Mortadela Especial x 450g',      9200, 19, '7701111000035',  50, 10),
    (v_cat_lacteos, 'Queso Costeño x 500g',          14500, 19, '7702222000013',  40,  8),
    (v_cat_lacteos, 'Mantequilla con Sal x 250g',     8900,  5, '7702222000020',  35,  6),
    (v_cat_despensa,'Huevos AA x 30 und',            21000,  0, '7703333000015',  70, 12),
    (v_cat_despensa,'Salsa de Tomate x 400g',         6200, 19, '7703333000022',  90, 15)
  ) as t(cat, nombre, precio, iva, barras, stock, minimo) loop
    insert into productos (id_comercio, id_categoria, nombre, precio_venta, iva_porcentaje, codigo_barras)
    values (v_com, rec.cat, rec.nombre, rec.precio, rec.iva, rec.barras) returning id_producto into v_prod;
    insert into inventarios_sucursal (id_sucursal, id_producto, stock, stock_minimo) values (v_suc, v_prod, rec.stock, rec.minimo);
  end loop;

  insert into proveedores (id_comercio, nombre_proveedor, contacto, telefono, email) values
    (v_com, 'Distribuidores de Carne El Ganadero', 'Jaime Forero', '3101234567', 'ventas@elganadero.com.co'),
    (v_com, 'Lácteos y Quesos del Campo SAS',      'Marta Gómez',  '3159876543', 'pedidos@lacteosdelcampo.com');

  insert into clientes (id_comercio, numero_identificacion, nombre, telefono, email, puntos_fidelidad) values
    (v_com, '1010101010', 'Juan Carlos Pérez',       '3204567890', 'juan.perez@email.com', 0),
    (v_com, '1020202020', 'María Camila Restrepo',   '3127894561', 'camila.restrepo@email.com', 150);
end $$;

insert into sistema_acerca_de (parametro, valor) values
  ('Año Desarrollo', '2026'),
  ('Autor Principal', 'David Eduardo Puentes Castro'),
  ('Entregable', 'Proyecto de Aula - ACA'),
  ('Institución', 'Corporación Unificada Nacional de Educación Superior (CUN)'),
  ('Programa', 'Ingeniería de Sistemas'),
  ('Proyecto', 'Surtify - Plataforma POS & ERP Multi-sucursal para Microempresarios'),
  ('Rol', 'Arquitecto de Software & Diseñador de Base de Datos'),
  ('Versión Base de Datos', '2.0.0 (PostgreSQL / Supabase: RLS, triggers y funciones RPC)')
on conflict (parametro) do update set valor = excluded.valor;

-- Si los usuarios de Auth ya existían antes de correr este script, se enlazan ahora.
update empleados e set auth_user_id = u.id
  from auth.users u
 where lower(u.email) = lower(e.email) and u.email_confirmed_at is not null and e.auth_user_id is null;
