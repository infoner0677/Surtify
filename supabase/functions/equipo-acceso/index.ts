// EQUIPO: crea y administra el ACCESO (usuario de Supabase Auth) de las personas del comercio.
// Seguridad: quien llama debe ser ADMINISTRADOR. Eso lo decide la base de datos: todas las acciones pasan primero por
// funciones (equipo_crear, equipo_persona, equipo_actualizar...) ejecutadas con el token de quien llama, y esas funciones
// solo funcionan para un administrador y solo dentro de su propio comercio. La clave de servicio (que puede crear
// usuarios) vive aquí y nunca llega al navegador. Nunca se guardan ni se registran contraseñas.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SITE = "https://infoner0677.github.io/Surtify/";

class Falla extends Error {}

function claveValida(p: unknown): string {
  const s = typeof p === "string" ? p : "";
  if (s.length < 8 || s.length > 72) throw new Falla("La contraseña debe tener entre 8 y 72 caracteres");
  return s;
}
function mensajeCorreo(msg: string): string {
  const m = (msg || "").toLowerCase();
  if (m.includes("rate limit") || m.includes("too many")) {
    return "Se alcanzó el límite de correos del sistema. Usa una contraseña temporal o configura un servicio de correo propio (SMTP) en Supabase.";
  }
  if (m.includes("not authorized") || m.includes("not allowed") || m.includes("authorized")) {
    return "El correo del sistema todavía solo puede escribir a miembros del equipo de Supabase. Usa una contraseña temporal o configura un servicio de correo propio (SMTP).";
  }
  return "No se pudo enviar el correo: " + msg;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Inicia sesión para continuar" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const yo = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false, autoRefreshToken: false },
  });
  const sb = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });

  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await yo.rpc(fn, args);
    if (error) throw new Falla(error.message);
    return data;
  };
  const buscarUsuario = async (email: string) => {
    for (let page = 1; page <= 5; page++) {
      const { data, error } = await sb.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) throw new Falla("No se pudo consultar los usuarios: " + error.message);
      const u = data.users.find((x: { email?: string }) => (x.email ?? "").toLowerCase() === email);
      if (u) return u;
      if (data.users.length < 1000) break;
    }
    return null;
  };
  const yaExiste = (e: { message?: string; code?: string; status?: number }) =>
    e.code === "email_exists" || e.code === "user_already_exists" || e.status === 422 || /already (been )?registered|already exists/i.test(e.message ?? "");

  // Da acceso (contraseña temporal o invitación) a un correo. Devuelve qué pasó para decírselo al dueño.
  const darAcceso = async (email: string, nombre: string, modo: string, password: string | null) => {
    if (modo === "password") {
      const { error } = await sb.auth.admin.createUser({
        email, password: password!, email_confirm: true, user_metadata: { nombre, debe_cambiar_clave: true },
      });
      if (!error) return { resultado: "creado" };
      if (!yaExiste(error)) throw new Falla("No se pudo crear el acceso: " + error.message);
    } else {
      const { error } = await sb.auth.admin.inviteUserByEmail(email, { redirectTo: SITE, data: { nombre } });
      if (!error) return { resultado: "invitado" };
      if (!yaExiste(error)) throw new Falla(mensajeCorreo(error.message));
    }
    // Ya existía una cuenta con ese correo
    const u = await buscarUsuario(email);
    if (!u) throw new Falla("Ese correo ya tiene una cuenta pero no pude encontrarla. Intenta de nuevo.");
    if (u.email_confirmed_at) return { resultado: "existente", auth_user_id: u.id };
    // Cuenta sin confirmar: nadie ha demostrado que el correo es suyo, se puede reemplazar por el acceso que da el dueño
    if (modo === "password") {
      const { error } = await sb.auth.admin.updateUserById(u.id, { password: password!, email_confirm: true, user_metadata: { nombre, debe_cambiar_clave: true } });
      if (error) throw new Falla("No se pudo crear el acceso: " + error.message);
      return { resultado: "creado" };
    }
    await sb.auth.admin.deleteUser(u.id);
    const { error } = await sb.auth.admin.inviteUserByEmail(email, { redirectTo: SITE, data: { nombre } });
    if (error) throw new Falla(mensajeCorreo(error.message));
    return { resultado: "invitado" };
  };

  try {
    const b = await req.json();
    const accion = String(b.accion ?? "");
    const modo = b.modo === "correo" ? "correo" : "password";

    if (accion === "crear") {
      const password = modo === "password" ? claveValida(b.password) : null;
      const c = await rpc("equipo_crear", { p_nombre: b.nombre, p_email: b.email, p_id_sucursal: b.id_sucursal, p_id_role: b.id_role });
      const id = c.id_empleado as number, email = c.email as string;
      try {
        const r = await darAcceso(email, String(b.nombre).trim(), modo, password);
        if (r.resultado === "existente") {
          const { error } = await sb.from("empleados").update({ auth_user_id: r.auth_user_id }).eq("id_empleado", id).is("auth_user_id", null);
          if (error) throw new Falla("No se pudo vincular la cuenta existente: " + error.message);
        }
        await rpc("equipo_registrar", { p_id_empleado: id, p_accion: modo === "correo" && r.resultado === "invitado" ? "invitacion" : "acceso_creado", p_detalle: r.resultado });
        return json({ ok: true, id_empleado: id, resultado: r.resultado, modo });
      } catch (e) {
        await yo.rpc("equipo_descartar", { p_id_empleado: id }); // no dejar una persona a medias
        throw e;
      }
    }

    if (accion === "restablecer") {
      const password = modo === "password" ? claveValida(b.password) : null;
      const p = await rpc("equipo_persona", { p_id_empleado: b.id_empleado });
      if (!p.activo) throw new Falla("Esa persona está desactivada. Reactívala primero.");
      if (p.auth_user_id) {
        if (modo === "password") {
          const { error } = await sb.auth.admin.updateUserById(p.auth_user_id, { password: password!, user_metadata: { debe_cambiar_clave: true } });
          if (error) throw new Falla("No se pudo cambiar la contraseña: " + error.message);
        } else {
          const { error } = await anon.auth.resetPasswordForEmail(p.email, { redirectTo: SITE });
          if (error) throw new Falla(mensajeCorreo(error.message));
        }
        await rpc("equipo_registrar", { p_id_empleado: p.id_empleado, p_accion: "clave_restablecida", p_detalle: modo });
        return json({ ok: true, resultado: modo === "password" ? "clave_cambiada" : "correo_enviado", modo });
      }
      // Aún no tiene acceso (p. ej. la invitación no se aceptó): se entrega de nuevo
      const r = await darAcceso(p.email, p.nombre, modo, password);
      if (r.resultado === "existente") {
        const { error } = await sb.from("empleados").update({ auth_user_id: r.auth_user_id }).eq("id_empleado", p.id_empleado).is("auth_user_id", null);
        if (error) throw new Falla("No se pudo vincular la cuenta existente: " + error.message);
      }
      await rpc("equipo_registrar", { p_id_empleado: p.id_empleado, p_accion: modo === "correo" ? "invitacion" : "acceso_creado", p_detalle: r.resultado });
      return json({ ok: true, resultado: r.resultado, modo });
    }

    if (accion === "estado") {
      const activo = b.activo === true;
      const r = await rpc("equipo_actualizar", { p_id_empleado: b.id_empleado, p_activo: activo });
      let aviso: string | null = null;
      if (r.auth_user_id) {
        const { error } = await sb.auth.admin.updateUserById(r.auth_user_id, { ban_duration: activo ? "none" : "876000h" });
        if (error) aviso = "Quedó " + (activo ? "reactivada" : "desactivada") + " en el sistema, pero no pude bloquear/desbloquear su inicio de sesión: " + error.message;
      }
      return json({ ok: true, activo, aviso });
    }

    return json({ error: "Acción no válida" }, 400);
  } catch (e) {
    if (e instanceof Falla) return json({ error: e.message }, 400);
    return json({ error: "Error inesperado: " + (e as Error).message }, 500);
  }
});
