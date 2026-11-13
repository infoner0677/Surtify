# Surtify · Base de datos en Supabase (PostgreSQL)

Migración del esquema MySQL del informe ACA (22 tablas, 6 triggers, vistas, DCL) a PostgreSQL/Supabase,
más las funciones que necesita el modo **Caja Simple** (abrir caja → vender → gasto → cerrar).

## Cómo ejecutarlo en Supabase (≈ 5 minutos)

1. En tu proyecto de Supabase abre **SQL Editor → New query**.
2. Pega el contenido de **`surtify_supabase_completo.sql`** y pulsa **Run**.
   (Es la suma de `01_esquema` + `02_funciones_y_triggers` + `03_seguridad_rls` + `04_datos_demo`.
   Si prefieres ir paso a paso, ejecuta esos cuatro archivos en orden.)
3. Crea los usuarios de prueba: **Authentication → Users → Add user → Create new user**,
   marcando *Auto Confirm User*:
   - `carlos.mendoza@eltriunfo.com` → Administrador (modo Carlos)
   - `diana.gomez@eltriunfo.com` → Cajera (modo Rosa)

   Elige contraseñas propias. Un trigger enlaza cada usuario con su empleado por correo.
4. **Desactiva el registro abierto**: en Authentication → (Sign In / Providers) apaga
   *Allow new users to sign up*. Así nadie puede crearse una cuenta con un correo de empleado.
5. Comprueba que quedó bien, en el SQL Editor:
   ```sql
   select count(*) from productos;                 -- 9
   select nombre, auth_user_id is not null as enlazado from empleados;   -- ambos true
   select * from v_reporte_critico_inventario;
   ```
   > El SQL Editor corre como `postgres`, sin sesión de usuario: allí `perfil_actual()` o `registrar_venta()`
   > no funcionan (necesitan `auth.uid()`). Se prueban desde la app o con las pruebas de `tests/`.

## Qué cambió respecto a MySQL

| Tema | MySQL (informe) | PostgreSQL (Supabase) |
|---|---|---|
| Contraseñas | `contrasena_hash` con SHA2 sin salt | Supabase Auth (bcrypt); `empleados.auth_user_id` |
| Usuarios de BD (DCL) | `GRANT/REVOKE` a usuarios API/auditor | Roles `anon`/`authenticated` + **RLS** por comercio y sucursal |
| Triggers | 6 (2 duplicados en `facturas`) | 5 + 1 de inmutabilidad; el duplicado se eliminó |
| Stock | podía quedar negativo | `CHECK (stock >= 0)` + la venta completa se revierte |
| Caja | el saldo esperado sumaba todos los pagos | solo **efectivo** entra al cajón; el libro registra todos los métodos |
| Multi-inquilino | `productos` sin `id_comercio` | `productos.id_comercio`; identificación única **por comercio** |
| Facturas | "inmutables" solo en el comentario | triggers que impiden modificarlas o borrarlas |

Columnas nuevas: `roles.es_administrador`, `productos.iva_porcentaje/activo`, `empleados.activo`,
`comercios.prefijo_factura/consecutivo_factura`, `facturas.monto_recibido/monto_cambio`.

## Funciones que usará el frontend (`supabase.rpc(...)`)

| Función | Qué hace |
|---|---|
| `perfil_actual()` | Quién soy, mi rol, sucursal y comercio (decide modo Rosa / Carlos) |
| `abrir_caja(base)` | Abre turno con la base de efectivo |
| `registrar_venta(items, metodo, recibido, cliente, canal)` | Pedido + stock + factura + IVA + caja en **una transacción**. Los precios salen de la BD |
| `registrar_gasto(monto, concepto, descripcion)` | Vale de caja; resta del efectivo esperado |
| `resumen_caja()` | Estado en vivo del turno (esperado, ventas por método, gastos) |
| `cerrar_caja(efectivo_contado)` | Arqueo: esperado vs. contado y diferencia |
| `ajustar_stock(sucursal, producto, delta, stock_minimo)` | **Admin.** Entrada o corrección de stock y stock mínimo; nunca deja stock negativo |
| `crear_producto(...)` | **Admin.** Producto nuevo con inventario en todas las sedes |
| `panel_multisede(dias)` | **Admin.** KPIs, ventas por sede/día/método, top productos, alertas y turnos |

Vistas: `v_productos_pos` (producto + stock de mi sucursal) y `v_inventario_admin` (inventario por sede con bandera de alerta).

`06_inventario_y_panel.sql` agrega además una segunda sucursal demo, **Sede Norte - Chapinero**, con la cajera Laura Ruiz.

## Pruebas

`tests/20_pruebas_inventario_panel.sql` se puede pegar directo en el SQL Editor de Supabase: prueba inventario y panel y **revierte todo** al final (termina con un error `PRUEBAS_OK` a propósito). Además, `tests/` contiene un simulador mínimo de Supabase Auth y 11 bloques de pruebas (venta del informe al centavo,
sobreventa, aislamiento entre comercios, permisos del cajero, nota crédito, cierre de caja).
Se ejecutaron sobre PostgreSQL 16: todas pasan. Para repetirlas en local:

```bash
createdb surtify_test
for f in tests/00_shim_supabase_local.sql 01_esquema.sql 02_funciones_y_triggers.sql 03_seguridad_rls.sql 04_datos_demo.sql tests/10_pruebas_funcionales.sql; do psql -v ON_ERROR_STOP=1 -d surtify_test -f $f; done
```
(`tests/00_shim...` **no** se ejecuta en Supabase.)

## Seguridad

- La `anon key` de Supabase es pública por diseño; la protección real son las políticas RLS de `03_seguridad_rls.sql`.
- **Nunca** subas la `service_role key` al repositorio.

## 07 · Devoluciones y reporte para el contador

- `devolucion_disponible(id_factura)` y `registrar_devolucion(id_factura, items, motivo)`: crea la **nota crédito** (consecutivo `NC-<prefijo>-0001`), reingresa el stock a la sede de la venta y descuenta el efectivo de la **caja abierta de quien devuelve** (si el pago fue en efectivo). No permite devolver más de lo vendido ni sin caja abierta.
- `reporte_contador(desde, hasta, sucursal)`: facturas, base, IVA por tarifa, devoluciones, ventas netas, método de pago y gastos. El administrador ve todas las sedes; el cajero solo la suya.
- Vista `v_facturas_recientes` (respeta RLS). En la app: pestañas **Devolver** y **Reporte** (compartir por WhatsApp, copiar, CSV).
- Pruebas: `tests/30_pruebas_devoluciones_reporte.sql` (se revierte al final).

## 08 · Fiados (cuentas por cobrar)

- Tabla `cartera_movimientos` (cargos, abonos y notas crédito por cliente), columna opcional `clientes.cupo_fiado` y vista `v_cartera` (saldo por cliente, respeta RLS).
- `registrar_venta` acepta el método **Fiado**: exige cliente, respeta el cupo y no entra efectivo a la caja.
- `registrar_abono(cliente, monto, método)`: baja la deuda; si el abono es en efectivo suma al efectivo esperado del cajón. No deja abonar más de lo que se debe.
- `crear_cliente(...)` y `estado_cuenta(cliente)`.
- Devolver una venta fiada baja la deuda del cliente (no sale efectivo). `resumen_sesion` y `reporte_contador` incluyen abonos y total por cobrar.
- En la app: pestaña **Fiados** (clientes, saldo, estado de cuenta, abonos, recordatorio por WhatsApp), opción **Fiado** al cobrar y KPI "Por cobrar" en el panel del administrador.
- Pruebas: `tests/40_pruebas_fiados.sql` (se revierte al final).

## 09 · Listado de facturas
- `v_facturas_recientes` ahora incluye sede, empleado, cliente y unidades (solo se añadieron columnas).
- En la app: pestaña **Mis ventas** para el cajero (solo sus facturas) y **Facturas** para el administrador (todas las sedes, con filtros por periodo, sede, medio de pago y búsqueda por número, cliente o cajero). Tocar una factura muestra su detalle.

## 10 · Códigos de demo válidos / 11 · Sugerencias de compra
- `10`: corrige el dígito verificador EAN-13 de los códigos de la demo (para el escáner de cámara).
- `11`: `sugerencias_compra(p_dias, p_cobertura, p_entrega)` (solo administrador). Con las ventas netas de los últimos `p_dias` días (facturas − devoluciones) calcula por producto y sede el promedio diario, cuántos días alcanza el stock, la fecha ideal de pedido y la cantidad sugerida = ceil(promedio × (entrega + cobertura)) − stock. Marca **Urgente** (se acaba antes de que llegue el pedido o está agotado) y **Pronto**. Si el negocio lleva menos de `p_dias` días vendiendo, usa los días reales.
- En la app (administrador): pestaña **Compras** (con globo de urgentes), aviso en el Panel, ajuste de días de entrega y cobertura, y envío del pedido por WhatsApp o copiado.

## 12 · Comprobantes de pago
- Bucket **privado** `comprobantes` (solo JPG/PNG/WebP, máx. 3 MB) y tabla `comprobantes_pago` (una foto por fila, ligada a una factura **o** a un abono de fiado).
- `adjuntar_comprobante(p_id_factura, p_id_movimiento, p_ruta)`: valida que la ruta sea de la carpeta del comercio (`{id_comercio}/archivo`), que la imagen exista y que el usuario pueda ver esa factura/abono.
- Evidencia inmutable: nadie puede actualizar ni borrar comprobantes. Subir solo a la carpeta del propio comercio; leer una foto solo si el usuario ve su comprobante (la sede del cajero, o todas para el administrador). Las fotos se abren con enlaces firmados de 5 minutos.
- `registrar_abono` ahora devuelve también `id_movimiento`; `v_facturas_recientes` añade `n_comprobantes` al final.
- En la app: botón **📎 Adjuntar foto del comprobante** al cobrar con Nequi/Daviplata/Bre-B/Tarjeta, al recibir un abono digital y en el detalle de la factura; el listado marca ⚠ *sin comprobante* y se puede filtrar. La foto se comprime en el celular (~100–300 KB) antes de subirse.

## 13 · Autoservicio con pasarela de pago
- Sede con `autoservicio = true` (demo: *Autoservicio Centro*). El cliente **no tiene cuenta**: usa `autoservicio.html?s=<id_sucursal>` con la clave anon.
- Solo 3 funciones son públicas: `autoservicio_catalogo` (productos con stock), `autoservicio_crear_pago` (precios e IVA **siempre** del servidor; el navegador no puede cambiarlos) y `autoservicio_estado` (el cliente consulta con su `id_pago`, un UUID no adivinable).
- `autoservicio_confirmar_pago` solo la puede ejecutar la **clave de servicio** (Edge Function). Crea pedido, factura y descuenta stock **solo cuando la pasarela confirma**. Es idempotente (webhooks repetidos no venden dos veces), acepta un pago aprobado aunque el cobro haya vencido, y si el producto se agotó mientras pagaba deja el pago como `Pago sin venta` (para reembolso) sin tocar inventario ni consecutivo.
- Tabla `pagos_autoservicio` (estados: Pendiente, Aprobado, Rechazado, Vencido, Pago sin venta) con RLS: el personal solo ve su sede; el administrador, todas. `v_facturas_recientes` añade `ref_pasarela` y muestra *Autoservicio* como cajero.
- Edge Function `supabase/functions/pasarela-simulada`: **simula** la pasarela (sin dinero real). Para producción se reemplaza por un webhook que verifique la firma del proveedor (Wompi, ePayco…) y llame a la misma función de confirmación.

## 14 · Autoservicio: pago Bre-B con comprobante y fiado con Google
- **Sin comisión de pasarela.** Cada sede de autoservicio tiene `modo_pago_auto` (`comprobante` o `pasarela`), `llave_breb`, `titular_breb` y `tope_sin_verificar`. En modo comprobante el cliente paga a la llave Bre-B de la tienda con su propia app, sube la captura y escribe la referencia; la venta queda registrada con `verificacion = 'Por verificar'` y el dueño la concilia (`Verificado` / `Dudoso`) contra los movimientos reales de su cuenta.
- Bucket privado `capturas-autoservicio` (3 MB, máx. 3 fotos): el cliente anónimo solo puede subir a la carpeta `{id_pago}` de un pago pendiente en modo comprobante; no puede leer nada. El personal las ve con enlaces firmados.
- `autoservicio_enviar_comprobante`: referencia normalizada (6–40, A–Z/0–9/-), única por comercio, un solo envío por pago, la imagen debe existir en la carpeta del pago. Un comprobante **Dudoso** no revierte la venta automáticamente: queda marcado para que el dueño decida (cobrar, devolver o reportar).
- **Fiado con cuenta de Google** (`clientes_autoservicio`): el cliente entra con Google, da su celular y acepta el tratamiento de datos (Ley 1581 de 2012, queda `acepta_datos_en`). El dueño lo aprueba y fija el cupo (`autoservicio_decidir_cliente`; `clientes.cupo_fiado` solo cambia por esa función). Fiar exige cliente aprobado y cupo disponible; el cargo entra a la cartera de Fiados.
- Funciones del dueño (solo administrador): `autoservicio_clientes`, `autoservicio_decidir_cliente`, `autoservicio_verificar`, `autoservicio_configurar`. `v_facturas_recientes` añade `verificacion`.
- En la app: pestaña **Autoservicio** del administrador (por verificar, dudosos, verificados, clientes y configuración) con insignia de pendientes.
- Requiere configurar Google en el panel de Supabase (Authentication → Providers → Google, y Site URL / Redirect URLs con `https://infoner0677.github.io/Surtify/autoservicio.html?s=4`).

## 15 · Carga masiva de productos (Excel/CSV)
- `importar_productos(p_sucursal, p_filas jsonb, p_aplicar boolean)` (solo administrador, máx. 2000 filas). Con `p_aplicar = false` solo valida y devuelve el resumen por fila (nuevo / actualiza / error); con `true` aplica, todo o nada por llamada.
- Producto existente (mismo código de barras, o mismo nombre si la fila no trae código): actualiza nombre, precio, IVA y categoría y **no toca el stock** (reimportar no pisa conteos reales). Producto nuevo: stock inicial en la sede elegida y 0 en las demás. Las categorías nuevas se crean por nombre.
- Validaciones: nombre y precio obligatorios, IVA 0–100, stock no negativo, códigos o nombres repetidos dentro del archivo.
- En la app: Inventario → **⬆ Importar Excel** (descarga plantilla, resumen previo, confirmar). El archivo se lee en el navegador (SheetJS) y acepta precios como `$ 3.200`, IVA como `19%` y avisa si Excel convirtió los códigos de barras a notación científica.

## 16 · Equipo: accesos desde la app
- Funciones solo para administrador y siempre dentro de su comercio: `equipo_listar`, `equipo_persona`, `equipo_crear`, `equipo_actualizar` (rol, sede, activo), `equipo_descartar`, `equipo_registrar`. Reglas: nadie puede desactivarse ni quitarse el rol de administrador a sí mismo, debe quedar al menos un administrador activo, no se asignan roles o sedes de otro comercio ni la sede de autoservicio, y un correo no puede repetirse.
- Tabla `equipo_eventos`: quién agregó, desactivó, cambió rol/sede o entregó/restableció un acceso (sin contraseñas). Solo la ve el administrador.
- Edge Function `supabase/functions/equipo-acceso` (clave de servicio solo en el servidor). Acciones: `crear`, `restablecer`, `estado`. Dos formas de dar acceso, a elección del dueño: **contraseña temporal** (el usuario queda confirmado y debe cambiarla al entrar) o **correo de invitación**. Desactivar bloquea el inicio de sesión (ban) y la base de datos le quita el acceso a los datos al instante.
- App: pestaña **Equipo**; pantalla de nueva contraseña (invitación, recuperación o contraseña temporal) y enlace «¿Olvidaste tu contraseña?» en el login.
- **Correo:** el correo integrado de Supabase es muy limitado (pocos correos por hora y solo a miembros del equipo del proyecto). Para invitaciones reales a cualquier persona configura un SMTP propio (Authentication → Emails → SMTP, p. ej. Resend o Brevo). Mientras tanto usa contraseña temporal.
- Los roles con permisos propios están en la sección 17.

## 17 · Roles con permisos
- Catálogo cerrado `permisos_catalogo` (vender, fiados, inventario, compras, reportes, panel, autoservicio, todas_sedes) y tabla `roles_permisos`. `app.tiene_permiso(clave)` es verdadero para el rol administrador o si el rol de la persona tiene ese permiso. **Se exige en la base de datos** (funciones y políticas), no solo en la pantalla.
- Qué exige cada función: caja (abrir/cerrar, vender, gasto, devolución, resumen) → `vender`; crear cliente, abonos, estado de cuenta → `fiados`; ajustar stock, crear producto, importar → `inventario`; sugerencias → `compras`; reporte del contador → `reportes`; `panel_multisede` → `panel`; funciones del autoservicio → `autoservicio`. `todas_sedes` decide si la persona ve todas las sedes (y todas las sesiones de caja) o solo la suya.
- Gestionar **equipo y roles** sigue siendo exclusivo del administrador (no es un permiso delegable). El rol administrador no se puede editar ni eliminar; un rol con personas no se puede eliminar.
- Datos iniciales: los roles no administradores existentes conservan lo que hacían (vender, fiados, reportes de su sede) y se crean **Bodega** (inventario, compras) y **Contabilidad** (reportes, fiados, panel, todas las sedes).
- Funciones: `roles_listar`, `roles_guardar(id, nombre, descripcion, permisos[])`, `roles_eliminar`; `perfil_actual` devuelve `permisos`. En la app: Equipo → **Roles** (casillas) y menú según permisos.
- Pruebas: `tests/80_pruebas_roles.sql`.

## 18 · Mi cuenta (el cliente ve su deuda)
- Página pública `cuenta.html`: saldo, cupo disponible, desde cuándo debe (los abonos se aplican a la compra más vieja), cada compra con lo que se llevó, abonos y la llave Bre-B para pagar. Un cliente solo ve **su** cuenta.
- **Dos formas de entrar.** A) Google: los clientes del autoservicio ya entran así; a un cliente que el tendero creó a mano se le da un **código de vinculación** (8 caracteres, un solo uso, vence en 7 días) que escribe una vez con su sesión de Google (`cuenta_vincular_codigo`, con consentimiento Ley 1581). B) **Enlace personal + PIN de 6 dígitos** para quien no usa Google (`cuenta_por_enlace`, sin sesión): el secreto del enlace (192 bits) va en el fragmento `#t=` de la URL (no viaja al servidor) y el PIN se entrega en un mensaje aparte.
- Seguridad: enlace y código se guardan como SHA-256 y el PIN con bcrypt (nada en claro); PIN: bloqueo de 15 min cada 5 fallos y el enlace se revoca a los 15; código: 5 fallos por hora por usuario; el enlace vence a los 90 días; respuestas genéricas que no revelan si un enlace existe; las tablas `cliente_accesos` y `cliente_vinculo_intentos` no son accesibles desde el cliente.
- Tendero (permiso `fiados`): `cliente_acceso_crear(id, 'enlace'|'codigo')`, `cliente_acceso_estado`, `cliente_acceso_revocar(id, 'enlace'|'codigo'|'google'|'todo')`. En la app: Fiados → cliente → **🔑 Acceso del cliente a su cuenta** (envío por WhatsApp del enlace y del PIN en mensajes separados). Cada acción queda en el registro de movimientos.
- Pruebas: `tests/90_pruebas_cuenta_cliente.sql`.

## 19 · Recordatorios de cobro (los decide el dueño)
- La app **no envía nada sola**: arma la lista «a quién recordar hoy» y el tendero toca *Enviar* (se abre WhatsApp con el mensaje listo). Va en Fiados.
- El dueño (administrador) configura en `recordatorio_config`: activar (apagado por defecto), desde cuántos días de deuda, cada cuánto (mínimo 7), valor mínimo y el mensaje (`{nombre}`, `{tienda}`, `{saldo}`; obligatorio `{saldo}`; sin enlaces).
- Reglas fijas en la base (buena práctica tomada de la Ley 2300 de 2023): solo lunes a viernes 7:00–19:00 y sábados 8:00–15:00 hora de Colombia, nunca domingos ni festivos (los festivos se calculan: fijos, trasladados al lunes y los de Semana Santa); máximo un recordatorio por semana por cliente; solo a clientes con `clientes.recordatorios_ok = true` (el tendero registra en la ficha si autorizó o no quiere); teléfono celular válido; saldo ≥ mínimo.
- `recordatorios_pendientes` (lista), `recordatorio_registrar` (revalida todo, guarda el envío en `recordatorios_enviados` y devuelve teléfono y mensaje), `recordatorios_config[_guardar]`, `cliente_recordatorios`. Quedan eventos de auditoría.
- Pruebas: `tests/95_pruebas_recordatorios.sql`.

