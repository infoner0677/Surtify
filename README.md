# Surtify · POS & ERP para microempresas (modo Caja Simple)

- `index.html` + `config.js`: app web móvil (sin build ni Node). Se publica tal cual en GitHub Pages.
- `database/`: esquema PostgreSQL, triggers, RLS y funciones para Supabase (ver `database/README.md`).

## Publicar
1. Ejecuta `database/surtify_supabase_completo.sql` en el SQL Editor de Supabase y crea los usuarios demo.
2. Edita `config.js` con la URL y la clave anon/publishable de tu proyecto (no la `service_role`).
3. Sube todo a un repositorio público de GitHub: **Settings → Pages → Deploy from a branch → `main` / root**.
4. Abre `https://TU-USUARIO.github.io/NOMBRE-DEL-REPO/` e inicia sesión.

Recuerda: los proyectos gratis de Supabase se pausan tras 7 días sin actividad; reactívalo antes de la sustentación.
