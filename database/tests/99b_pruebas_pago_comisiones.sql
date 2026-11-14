-- Pruebas de 23_pago_comisiones.sql (se revierte al final)
do $$
declare
  log text := ''; u_carlos uuid; u_diana uuid; e_diana int; v_rest int; s_corte int; r jsonb; fac int; pg jsonb; pend jsonb; rep jsonb;
begin
  select auth_user_id into u_carlos from empleados where email='carlos.mendoza@eltriunfo.com';
  if u_carlos is null then insert into auth.users (id,email,email_confirmed_at) values (gen_random_uuid(),'carlos.mendoza@eltriunfo.com',now()) returning id into u_carlos; end if;
  select auth_user_id, id_empleado into u_diana, e_diana from empleados where email='diana.gomez@eltriunfo.com';
  if u_diana is null then insert into auth.users (id,email,email_confirmed_at) values (gen_random_uuid(),'diana.gomez@eltriunfo.com',now()) returning id into u_diana; end if;

  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  perform set_config('role','authenticated',true);
  s_corte := (public.crear_servicio('Corte P', 20000, 0, 40))->>'id_producto';

  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  if not exists (select 1 from sesiones_caja where id_empleado=e_diana and estado_caja='Abierta') then perform public.abrir_caja(50000); end if;
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', s_corte,'cantidad',2,'id_empleado',e_diana)),'Efectivo',100000);
  fac := (r->>'id_factura')::int;

  -- T1 pendiente
  pend := public.comisiones_pendientes();
  assert (pend->'personas'->0->>'pendiente')::numeric = 16000, 'pendiente 16000: '||pend::text;
  log := log||'T1 pendiente; ';

  -- T2 no admin no paga
  begin perform public.comisiones_pagar(e_diana); raise exception 'FALLO';
  exception when others then if sqlerrm not like '%administrador%' then raise exception 'T2: %', sqlerrm; end if; end;
  log := log||'T2 solo admin; ';

  -- T3 admin paga
  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  pg := public.comisiones_pagar(e_diana, null, 'Quincena');
  assert (pg->>'monto')::numeric = 16000, 'monto pagado';
  assert jsonb_array_length(public.comisiones_pendientes()->'personas') = 0, 'nada pendiente';
  assert jsonb_array_length(public.comisiones_pagos_listar()) = 1, 'historial';
  rep := public.reporte_comisiones(current_date-1,current_date+1);
  assert (rep->'detalle'->0->>'pagada')::boolean, 'detalle marcado pagada';
  assert exists (select 1 from equipo_eventos where accion='comision_pago'), 'evento';
  log := log||'T3 pago; ';

  -- T4 nada por pagar
  begin perform public.comisiones_pagar(e_diana); raise exception 'FALLO';
  exception when others then if sqlerrm not like '%No hay comisi%' then raise exception 'T4: %', sqlerrm; end if; end;
  log := log||'T4 doble pago; ';

  -- T5 devolución posterior = ajuste negativo; luego nueva venta absorbe el ajuste
  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  perform public.registrar_devolucion(fac, jsonb_build_array(jsonb_build_object('id_producto', s_corte,'cantidad',1)),'x');
  pend := public.comisiones_pendientes();
  assert (pend->'personas'->0->>'pendiente')::numeric = -8000, 'ajuste -8000: '||pend::text;
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', s_corte,'cantidad',1,'id_empleado',e_diana)),'Efectivo',100000);
  pend := public.comisiones_pendientes();
  assert (pend->'personas'->0->>'pendiente')::numeric = 0 or jsonb_array_length(pend->'personas')=0, 'ajuste +venta = 0';
  log := log||'T5 devolución tras pago; ';

  -- T6 anon
  perform set_config('role','anon',true);
  begin perform public.comisiones_pendientes(); raise exception 'FALLO';
  exception when insufficient_privilege then null; end;
  log := log||'T6 anon; ';
  raise exception 'PRUEBAS_OK %', log;
end $$;
