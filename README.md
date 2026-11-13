# Surtify · POS & ERP para microempresas

- `index.html` + `config.js` + `assets/`: app web móvil (sin build ni Node). Se publica tal cual en GitHub Pages.
  - **Modo Rosa (cajero):** abrir caja → vender (buscar/escanear, carrito, cobrar, factura) → gastos → cerrar caja con arqueo. Avisa de productos con stock bajo.
  - **Modo Carlos (administrador):** además ve el **Panel multisede** (ventas por sede, por día y por método, top productos, cajas abiertas, turnos y alertas) y el **Inventario** (entradas de mercancía, conteo físico, stock mínimo y productos nuevos).
- `database/`: esquema PostgreSQL, triggers, RLS y funciones para Supabase (ver `database/README.md`).

## Publicar
1. Ejecuta en el SQL Editor de Supabase, en orden, `database/01_…` a `database/08_…` (o `surtify_supabase_completo.sql`, que ya incluye hasta la 08) y crea los usuarios demo: `carlos.mendoza@eltriunfo.com` (admin), `diana.gomez@eltriunfo.com` (cajera) y, opcional, `laura.ruiz@eltriunfo.com` (cajera de Sede Norte).
2. Edita `config.js` con la URL y la clave anon/publishable de tu proyecto (no la `service_role`).
3. Sube todo a un repositorio público de GitHub: **Settings → Pages → Deploy from a branch → `main` / root**.
4. Abre `https://TU-USUARIO.github.io/NOMBRE-DEL-REPO/` e inicia sesión.

Recuerda: los proyectos gratis de Supabase se pausan tras 7 días sin actividad; reactívalo antes de la sustentación.

## Instalar como app (PWA)
Surtify es una aplicación web instalable: `manifest.webmanifest`, `sw.js` e íconos en `assets/`.
- **Android / Chrome / Edge:** botón "Instalar app" dentro de Surtify (o menú ⋮ → "Instalar aplicación").
- **iPhone / iPad:** en Safari, Compartir → "Agregar a inicio".
- El service worker guarda la interfaz para que la app abra sin internet, pero **no** guarda datos ni ventas: vender y consultar requieren conexión (el modo sin conexión con sincronización queda como siguiente etapa).
- **Escáner por cámara:** botón "📷 Escanear" en Vender (lee códigos de barras y QR); en Inventario, "📷 Recibir mercancía" (suma 1 unidad por lectura y registra todo junto), 📷 en la búsqueda y 📷 en el código de barras de "+ Producto". Usa el lector nativo del navegador (Chrome/Android) o, si no existe (iPhone/Safari), la librería ZXing. Necesita HTTPS y permiso de cámara. `assets/codigos_demo.png` es una hoja con los códigos de la demo para probarlo.
- **Comprobante de pago:** en pagos con Nequi, Daviplata, Bre-B o tarjeta (y abonos digitales) el cajero adjunta la foto o el pantallazo del pago; queda guardado en un almacenamiento privado, ligado a la factura, y el listado marca las ventas digitales sin comprobante.
- **Autoservicio (demo):** `autoservicio.html?s=4` — el cliente escanea el QR de la tienda (`assets/qr_autoservicio.png`), escanea los productos con su cámara, paga en una **pasarela simulada** (Nequi, Daviplata, Bre-B, PSE, tarjeta; sin dinero real) y recibe su comprobante, sin cuenta ni app. La venta solo se registra cuando el servidor confirma el pago. Para producción falta: cuenta real en una pasarela (p. ej. Wompi) con webhook firmado, factura electrónica DIAN y reembolsos.
- **Autoservicio sin comisión (Bre-B):** la tienda puede cobrar a su llave Bre-B: el cliente sube la captura y la referencia, la venta queda *por verificar* y el dueño la concilia en la pestaña **Autoservicio**. Los clientes de confianza pueden **fiar** entrando con Google (celular + autorización de datos, aprobación y cupo del dueño). Requiere activar el proveedor Google en Supabase Auth.
- Al cambiar `index.html`, sube la versión `V` en `sw.js` si quieres forzar la renovación de la copia guardada.
- **Carga masiva por Excel:** en Inventario, el administrador descarga una plantilla, sube su lista de productos (xlsx/CSV), revisa el resumen con errores por fila y confirma. Reimportar actualiza precios sin pisar el stock.
- Plantilla pública para el tendero (con instrucciones): https://infoner0677.github.io/Surtify/assets/plantilla_productos_surtify.xlsx
- **Equipo:** el administrador agrega personas, les da acceso (contraseña temporal o correo de invitación), cambia rol/sede, restablece contraseñas y desactiva/reactiva accesos desde la pestaña Equipo, sin tocar la base de datos.
