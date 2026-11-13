-- =============================================================================
-- SURTIFY · 20_cuenta_aviso_y_autorizacion.sql
--   "Mi cuenta" avisa de la deuda (solo si el dueño activó los recordatorios y la deuda ya pasó sus días de inicio y su
--   valor mínimo) y deja que el propio cliente autorice o rechace los recordatorios por WhatsApp.
--   * app.cuenta_cliente devuelve además: id_comercio, recordatorios_ok, aviso.
--   * cuenta_recordatorios_google(id_comercio, valor): cliente con sesión de Google (cuenta aprobada en esa tienda).
--   * cuenta_recordatorios_enlace(token, pin, valor): cliente con enlace + PIN (reutiliza el bloqueo por intentos).
--   Cada decisión queda en equipo_eventos. Ver la definición aplicada en el proyecto (migración 20).
-- Pruebas con rollback: PRUEBAS_OK aviso_segun_config_del_dueno;autoriza_por_enlace;autoriza_por_google;aislado;eventos;anon_no_google;
-- =============================================================================

-- (El parche a app.cuenta_cliente que agrega id_comercio, recordatorios_ok y aviso se aplicó como migración 20 en el
--  proyecto; la definición vigente de la función queda en 18 + este parche + el de 21.)
create or replace function public.cuenta_recordatorios_enlace(p_token text, p_pin text, p_valor boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_r jsonb; v_id integer; v_com integer; v_nom text;
begin
  v_r := public.cuenta_por_enlace(p_token, p_pin);
  if not (v_r->>'ok')::boolean then return v_r; end if;
  if p_valor is null then raise exception 'Elige una opción'; end if;
  select a.id_cliente, a.id_comercio, c.nombre into v_id, v_com, v_nom from cliente_accesos a join clientes c on c.id_cliente = a.id_cliente
   where a.tipo = 'enlace' and a.secreto_hash = extensions.digest(convert_to(btrim(p_token), 'utf8'), 'sha256');
  update clientes set recordatorios_ok = p_valor where id_cliente = v_id;
  perform app.equipo_log(v_com, null, null, 'recordatorio_cliente', v_nom || case when p_valor then ' autorizó recordatorios por WhatsApp (desde su cuenta)' else ' no quiere recordatorios (desde su cuenta)' end);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cuenta_recordatorios_google(p_id_comercio integer, p_valor boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id integer; v_nom text;
begin
  if v_uid is null then raise exception 'Inicia sesión'; end if;
  if p_valor is null then raise exception 'Elige una opción'; end if;
  select ca.id_cliente, c.nombre into v_id, v_nom from clientes_autoservicio ca join clientes c on c.id_cliente = ca.id_cliente
   where ca.auth_user_id = v_uid and ca.id_comercio = p_id_comercio and ca.estado = 'Aprobado';
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'No encontramos tu cuenta en esa tienda.'); end if;
  update clientes set recordatorios_ok = p_valor where id_cliente = v_id;
  perform app.equipo_log(p_id_comercio, null, null, 'recordatorio_cliente', v_nom || case when p_valor then ' autorizó recordatorios por WhatsApp (desde su cuenta)' else ' no quiere recordatorios (desde su cuenta)' end);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.cuenta_recordatorios_google(integer, boolean) from public, anon;
revoke all on function public.cuenta_recordatorios_enlace(text, text, boolean) from public, anon;
grant execute on function public.cuenta_recordatorios_google(integer, boolean) to authenticated;
grant execute on function public.cuenta_recordatorios_enlace(text, text, boolean) to anon, authenticated;
