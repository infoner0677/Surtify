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
