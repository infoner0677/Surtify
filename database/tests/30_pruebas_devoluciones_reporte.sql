-- Pruebas de devoluciones y reporte contador (07). Todo se revierte al final (PRUEBAS_OK ... rollback).
do $$
declare
  v_rol text := current_user; log text := '';
  u_carlos uuid; u_diana uuid; v_rest int; v_jamon int; v_stock0 int; v_ses int; v_esp0 numeric;
  r jsonb; f int; d jsonb; rep jsonb;
begin
  select auth_user_id into u_carlos from empleados where email='carlos.mendoza@eltriunfo.com';
  if u_carlos is null then insert into auth.users (id,email,email_confirmed_at) values (gen_random_uuid(),'carlos.mendoza@eltriunfo.com',now()) returning id into u_carlos; end if;
  select auth_user_id into u_diana from empleados where email='diana.gomez@eltriunfo.com';
  if u_diana is null then insert into auth.users (id,email,email_confirmed_at) values (gen_random_uuid(),'diana.gomez@eltriunfo.com',now()) returning id into u_diana; end if;
  select id_sucursal into v_rest from sucursales where nombre_sucursal='Sede Principal - Restrepo';
  select id_producto into v_jamon from productos where codigo_barras='7701234560010';

  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  perform set_config('role','authenticated',true);
  if not exists (select 1 from sesiones_caja where id_empleado=(select id_empleado from empleados where email='diana.gomez@eltriunfo.com') and estado_caja='Abierta') then
    perform public.abrir_caja(50000); end if;
  select stock into v_stock0 from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon;
  select id_sesion, monto_cierre_esperado into v_ses, v_esp0 from sesiones_caja where id_empleado=(select id_empleado from empleados where email='diana.gomez@eltriunfo.com') and estado_caja='Abierta';
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',2)),'Efectivo',40000);
  f := (r->>'id_factura')::int;
  assert f is not null, 'venta devuelve id_factura';
  select monto_cierre_esperado into v_esp0 from sesiones_caja where id_sesion=v_ses;

  -- T1 devolver 1
  d := public.devolucion_disponible(f);
  assert (d->'lineas'->0->>'disponible')::int = 2, 'disponible 2';
  r := public.registrar_devolucion(f, jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',1)), 'Producto en mal estado');
  assert (r->>'total')::numeric = 16500, 'total devuelto 16500';
  assert (r->>'numero_nota') like 'NC-%', 'numero nota';
  assert (select stock from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon) = v_stock0 - 1, 'stock +1 tras devolución';
  assert (select monto_cierre_esperado from sesiones_caja where id_sesion=v_ses) = v_esp0 - 16500, 'esperado -16500';
  assert exists (select 1 from movimientos_caja where id_sesion=v_ses and tipo_movimiento='Egreso' and monto_neto=16500), 'egreso en caja de Diana';
  log := log || 'T1 devolución parcial; ';

  -- T2 sobre-devolución, motivo vacío, items vacíos
  begin perform public.registrar_devolucion(f, jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',2)), 'x');
        raise exception 'FALLO sobre-devolución';
  exception when others then if sqlerrm not like '%solo quedan%' then raise exception 'T2a: %', sqlerrm; end if; end;
  begin perform public.registrar_devolucion(f, jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',1)), '  ');
        raise exception 'FALLO motivo';
  exception when others then if sqlerrm not like '%motivo%' then raise exception 'T2b: %', sqlerrm; end if; end;
  begin perform public.registrar_devolucion(f, '[]'::jsonb, 'x');
        raise exception 'FALLO vacío';
  exception when others then if sqlerrm not like '%al menos un producto%' then raise exception 'T2c: %', sqlerrm; end if; end;
  r := public.registrar_devolucion(f, jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',1)), 'Cliente se arrepintió');
  assert (public.devolucion_disponible(f)->'lineas'->0->>'disponible')::int = 0, 'nada por devolver';
  log := log || 'T2 validaciones y devolución total; ';

  -- T3 reporte (cajero)
  rep := public.reporte_contador(current_date, current_date);
  assert (rep->'facturas'->>'num')::int >= 1, 'reporte cuenta facturas';
  assert (rep->'devoluciones'->>'total')::numeric >= 33000, 'devoluciones en reporte';
  assert (rep->>'ventas_netas')::numeric = (rep->'facturas'->>'total')::numeric - (rep->'devoluciones'->>'total')::numeric, 'neto';
  assert abs((rep->'facturas'->>'iva')::numeric - (select sum((x->>'iva')::numeric) from jsonb_array_elements(rep->'iva_por_tarifa') x)) <= 1, 'IVA consistente';
  assert rep->>'sucursal' = 'Sede Principal - Restrepo', 'cajero solo su sede';
  begin perform public.reporte_contador(current_date, current_date, 999999);
  exception when others then raise exception 'cajero con sucursal ajena no debe fallar: %', sqlerrm; end;
  begin perform public.reporte_contador(current_date, current_date - 1);
        raise exception 'FALLO rango';
  exception when others then if sqlerrm not like '%rango%' then raise exception 'T3: %', sqlerrm; end if; end;
  log := log || 'T3 reporte cajero; ';

  -- T4 admin
  perform set_config('role', v_rol, true);
  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  perform set_config('role','authenticated',true);
  rep := public.reporte_contador(current_date - 30, current_date);
  assert jsonb_array_length(rep->'por_sucursal') >= 1 and rep->>'sucursal' is null, 'admin ve todas las sedes';
  assert (select count(*) from v_facturas_recientes) >= 1, 'vista facturas';
  log := log || 'T4 reporte admin; ';

  perform set_config('role', v_rol, true);
  raise exception 'PRUEBAS_OK (rollback): %', log;
end $$;
