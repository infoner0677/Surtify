// PASARELA SIMULADA (solo para pruebas y sustentación; no mueve dinero real).
// Hace lo mismo que haría el webhook de una pasarela real (Wompi, ePayco...):
//   1) recibe el resultado del pago, 2) lo confirma en la base de datos con la CLAVE DE SERVICIO,
//   que vive solo aquí en el servidor y nunca llega al navegador.
// Para pasar a producción: reemplazar esta función por un webhook que VERIFIQUE LA FIRMA de la
// pasarela antes de llamar a autoservicio_confirmar_pago (la lógica de venta no cambia).
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const METODOS = ["Nequi", "Daviplata", "Bre-B", "PSE", "Tarjeta"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  try {
    const { id_pago, resultado, metodo } = await req.json();
    if (!UUID.test(String(id_pago))) return json({ error: "Pago no válido" }, 400);
    if (!["aprobado", "rechazado"].includes(resultado)) return json({ error: "Resultado no válido" }, 400);
    if (!METODOS.includes(metodo)) return json({ error: "Método de pago no válido" }, 400);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const ref = "SIM-" + crypto.randomUUID().slice(0, 8).toUpperCase();
    const { data, error } = await sb.rpc("autoservicio_confirmar_pago", {
      p_id_pago: id_pago,
      p_aprobado: resultado === "aprobado",
      p_metodo: metodo,
      p_proveedor: "Simulado",
      p_ref_externa: ref,
    });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true, ...data, ref_externa: ref });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
