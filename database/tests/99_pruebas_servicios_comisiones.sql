-- Pruebas de 22_servicios_y_comisiones.sql. Todo se revierte al final (patrón: do $$ ... raise exception 'PRUEBAS_OK ...' $$).
do $$
declare
  log text := '';
  u_carlos uuid; u_diana uuid; e_carlos int; e_diana int; e_laura int; v_rest int; v_jamon int; v_ses int;
  s_corte int; s_barba int; r jsonb; rep jsonb; fac int; stock0 int; n int;
begin
  select auth_user_id, id_empleado into u_carlos, e_carlos from empleados where email='carlos.mendoza@eltriunfo.com';
  if u_carlos is null then insert into auth.users (id,email,email_confirmed_at) values (gen_random_uuid(),'carlos.mendoza@eltriunfo.com',now()) returning id into u_carlos; end if;
  select auth_user_id, id_empleado into u_diana, e_diana from empleados where email='diana.gomez@eltriunfo.com';
  if u_diana is null then insert into auth.users (id,email,email_confirmed_at) values (gen_random_uuid(),'diana.gomez@eltriunfo.com',now()) returning id into u_diana; end if;
  select id_empleado into e_laura from empleados where email='laura.ruiz@eltriunfo.com';
  select id_sucursal into v_rest from sucursales where nombre_sucursal='Sede Principal - Restrepo';
  select id_producto into v_jamon from productos where codigo_barras='7701234560010';

  -- T1 el administrador crea servicios (con validaciones) y fija comisiones
  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  perform set_config('role','authenticated',true);
  begin perform public.crear_servicio('  ', 20000); raise exception 'FALLO nombre';
  exception when others then if sqlerrm not like '%nombre%' then raise exception 'T1a: %', sqlerrm; end if; end;
  begin perform public.crear_servicio('Corte', -1); raise exception 'FALLO precio';
  exception when others then if sqlerrm not like '%precio%' then raise exception 'T1b: %', sqlerrm; end if; end;
  begin perform public.crear_servicio('Corte', 20000, 0, 120); raise exception 'FALLO comision';
  exception when others then if sqlerrm not like '%comisión%' then raise exception 'T1c: %', sqlerrm; end if; end;
  s_corte := (public.crear_servicio('Corte de cabello', 20000))->>'id_producto';
  s_barba := (public.crear_servicio('Arreglo de barba', 10000, 0, 60))->>'id_producto';
  assert not exists (select 1 from inventarios_sucursal where id_producto in (s_corte, s_barba)), 'los servicios no tienen inventario';
  assert not exists (select 1 from v_inventario_admin where id_producto in (s_corte, s_barba)), 'no salen en el inventario';
  assert jsonb_array_length(public.servicios_listar()) = 2, 'servicios_listar';
  begin perform public.equipo_comision(e_diana, 101); raise exception 'FALLO pct';
  exception when others then if sqlerrm not like '%comisión%' then raise exception 'T1d: %', sqlerrm; end if; end;
  perform public.equipo_comision(e_diana, 40);
  assert (select comision_pct from empleados where id_empleado = e_diana) = 40, 'comisión de Diana 40';
  assert (select (p->>'comision_pct')::numeric from jsonb_array_elements(public.equipo_listar()->'personas') p where (p->>'id_empleado')::int = e_diana) = 40, 'equipo_listar trae la comisión';
  assert exists (select 1 from equipo_eventos where id_empleado = e_diana and accion = 'comision'), 'queda en el registro de eventos';
  log := log || 'T1 crear servicios y comisiones; ';

  -- T2 el cajero vende servicios sin stock; la comisión sale de la persona o del servicio
  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  if not exists (select 1 from sesiones_caja where id_empleado=e_diana and estado_caja='Abierta') then perform public.abrir_caja(50000); end if;
  select id_sesion into v_ses from sesiones_caja where id_empleado=e_diana and estado_caja='Abierta';
  select stock into stock0 from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon;
  assert exists (select 1 from v_productos_pos where id_producto = s_corte and not maneja_inventario), 'el servicio aparece en el catálogo de venta';
  assert exists (select 1 from v_productos_pos where id_producto = v_jamon and maneja_inventario), 'el producto sigue llevando inventario';
  assert jsonb_array_length(public.equipo_atiende()) >= 2, 'equipo_atiende lista a las personas';
  r := public.registrar_venta(jsonb_build_array(
         jsonb_build_object('id_producto', s_corte, 'cantidad', 2, 'id_empleado', e_diana),      -- 40 000 * 40 % = 16 000
         jsonb_build_object('id_producto', s_barba, 'cantidad', 1, 'id_empleado', e_diana),      -- 10 000 * 60 % (del servicio) = 6 000
         jsonb_build_object('id_producto', v_jamon, 'cantidad', 1)),                             -- producto sin persona: sin comisión
       'Efectivo', 100000);
  fac := (r->>'id_factura')::int;
  assert (r->>'total')::numeric = 50000 + 16500, 'total 66 500 (jamón 16 500)';
  assert (select stock from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon) = stock0 - 1, 'solo el producto descontó stock';
  assert (select sum(comision_valor) from detalles_pedido where id_pedido = (r->>'id_pedido')::int) = 22000, 'comisión total 22 000';
  assert (select comision_valor from detalles_pedido where id_pedido = (r->>'id_pedido')::int and id_producto = s_barba) = 6000, 'comisión del servicio manda sobre la de la persona';
  assert (select comision_valor from detalles_pedido where id_pedido = (r->>'id_pedido')::int and id_producto = v_jamon) = 0, 'sin persona no hay comisión';
  log := log || 'T2 venta de servicios; ';

  -- T3 validaciones de la persona que atiende
  begin perform public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', s_corte, 'cantidad', 1, 'id_empleado', 999999)), 'Efectivo');
        raise exception 'FALLO persona';
  exception when others then if sqlerrm not like '%persona que atiende%' then raise exception 'T3a: %', sqlerrm; end if; end;
  -- un servicio se puede vender muchas veces sin que "se agote"
  perform public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', s_corte, 'cantidad', 500, 'id_empleado', e_diana)), 'Efectivo');
  log := log || 'T3 persona válida y sin límite de stock; ';

  -- T4 reporte: la cajera ve solo lo suyo; el administrador ve a todos
  rep := public.reporte_comisiones(current_date - 1, current_date + 1);
  assert jsonb_array_length(rep->'personas') = 1 and (rep->'personas'->0->>'id_empleado')::int = e_diana, 'la cajera solo se ve a sí misma';
  assert (rep->'personas'->0->>'comision_neta')::numeric = 22000 + 500 * 20000 * 0.40, 'comisión neta de Diana';
  begin perform public.reporte_comisiones(current_date, current_date - 5); raise exception 'FALLO rango';
  exception when others then if sqlerrm not like '%rango%' then raise exception 'T4a: %', sqlerrm; end if; end;
  begin perform public.crear_servicio('Intruso', 1000); raise exception 'FALLO permiso';
  exception when others then if sqlerrm not like '%permiso%' then raise exception 'T4b: %', sqlerrm; end if; end;
  begin perform public.equipo_comision(e_diana, 90); raise exception 'FALLO equipo';
  exception when others then if sqlerrm not like '%administrador%' then raise exception 'T4c: %', sqlerrm; end if; end;
  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  rep := public.reporte_comisiones(current_date - 1, current_date + 1);
  assert jsonb_array_length(rep->'personas') = 1 and (rep->>'todos')::boolean, 'el administrador ve a todos';
  rep := public.reporte_comisiones(current_date - 1, current_date + 1, e_carlos);
  assert jsonb_array_length(rep->'personas') = 0, 'filtro por persona sin ventas';
  log := log || 'T4 reporte y permisos; ';

  -- T5 devolución: la comisión baja en proporción a lo devuelto (1 de los 2 cortes de la factura)
  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  perform public.registrar_devolucion(fac, jsonb_build_array(jsonb_build_object('id_producto', s_corte, 'cantidad', 1)), 'Cliente inconforme');
  assert (select stock from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon) = stock0 - 1, 'devolver un servicio no toca stock';
  rep := public.reporte_comisiones(current_date - 1, current_date + 1);
  assert (rep->'personas'->0->>'comision_devuelta')::numeric = 8000, 'comisión devuelta 8 000 (1 corte de 20 000 al 40 %)';
  assert (rep->'personas'->0->>'devuelto')::numeric = 20000, 'valor devuelto 20 000';
  assert (rep->'personas'->0->>'comision_neta')::numeric = 22000 + 500 * 20000 * 0.40 - 8000, 'comisión neta tras la devolución';
  log := log || 'T5 devolución resta comisión; ';

  -- T6 el cajero no puede cambiar nada del catálogo y los cambios de porcentaje no reescriben el pasado
  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  perform public.equipo_comision(e_diana, 10);
  perform public.servicio_editar(s_corte, 'Corte de cabello', 25000, null, true);
  rep := public.reporte_comisiones(current_date - 1, current_date + 1, e_diana);
  assert (rep->'personas'->0->>'comision_bruta')::numeric = 22000 + 500 * 20000 * 0.40, 'la comisión vieja se conserva';
  perform public.servicio_editar(s_corte, 'Corte de cabello', 25000, null, false);
  assert not exists (select 1 from v_productos_pos where id_producto = s_corte), 'un servicio desactivado sale del catálogo de venta';
  perform public.producto_comision(v_jamon, 5);
  assert (select comision_pct from productos where id_producto = v_jamon) = 5, 'comisión propia en un producto';
  log := log || 'T6 histórico y edición; ';

  -- T7 anónimo no entra
  perform set_config('role','anon',true);
  begin perform public.reporte_comisiones(current_date, current_date); raise exception 'FALLO anon';
  exception when insufficient_privilege then null; end;
  log := log || 'T7 anon no; ';

  raise exception 'PRUEBAS_OK %', log;
end $$;
