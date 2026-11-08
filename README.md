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
