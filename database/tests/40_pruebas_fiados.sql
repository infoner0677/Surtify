-- Pruebas de fiados (08_fiados.sql). Todo se revierte al final (PRUEBAS_OK ... rollback).
do $$
declare
  v_rol text := current_user; log text := '';
  u_carlos uuid; u_diana uuid; v_rest int; v_jamon int; v_stock0 int; v_ses int; v_esp0 numeric;
  r jsonb; cli int; fac int; rep jsonb; est jsonb;
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
  select id_sesion into v_ses from sesiones_caja where id_empleado=(select id_empleado from empleados where email='diana.gomez@eltriunfo.com') and estado_caja='Abierta';
  select stock into v_stock0 from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon;

  -- T1 crear cliente y vender fiado
  begin perform public.crear_cliente('  ', '3001234567'); raise exception 'FALLO nombre vacío';
  exception when others then if sqlerrm not like '%nombre%' then raise exception 'T1a: %', sqlerrm; end if; end;
  begin perform public.crear_cliente('Prueba', '12'); raise exception 'FALLO teléfono';
  exception when others then if sqlerrm not like '%teléfono%' then raise exception 'T1b: %', sqlerrm; end if; end;
  r := public.crear_cliente('Doña Marta (prueba)', '300 123 4567', null, 50000);
  cli := (r->>'id_cliente')::int;
  assert r->>'telefono' = '3001234567', 'teléfono normalizado';
  select monto_cierre_esperado into v_esp0 from sesiones_caja where id_sesion=v_ses;
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',2)),'Fiado',null,cli);
  fac := (r->>'id_factura')::int;
  assert (r->>'total')::numeric = 33000 and (r->>'saldo_cliente')::numeric = 33000, 'venta fiada 33000 y saldo 33000';
  assert (select monto_cierre_esperado from sesiones_caja where id_sesion=v_ses) = v_esp0, 'fiado no mueve el efectivo esperado';
  assert (select saldo from v_cartera where id_cliente=cli) = 33000, 'v_cartera muestra la deuda';
  log := log || 'T1 venta fiada; ';

  -- T2 validaciones: sin cliente, sobre cupo (la venta fallida no descuenta stock)
  begin perform public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',1)),'Fiado');
        raise exception 'FALLO sin cliente';
  exception when others then if sqlerrm not like '%cliente%' then raise exception 'T2a: %', sqlerrm; end if; end;
  begin perform public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',2)),'Fiado',null,cli);
        raise exception 'FALLO cupo';
  exception when others then if sqlerrm not like '%cupo%' then raise exception 'T2b: %', sqlerrm; end if; end;
  assert (select stock from inventarios_sucursal where id_sucursal=v_rest and id_producto=v_jamon) = v_stock0 - 2, 'la venta rechazada no descontó stock';
  log := log || 'T2 cliente obligatorio y cupo; ';

  -- T3 abonos
  r := public.registrar_abono(cli, 10000, 'Efectivo', 'abono de prueba');
  assert (r->>'saldo_nuevo')::numeric = 23000, 'saldo 23000 tras abono';
  assert (select monto_cierre_esperado from sesiones_caja where id_sesion=v_ses) = v_esp0 + 10000, 'abono en efectivo suma al cajón';
  assert (r->'caja'->>'abonos_efectivo')::numeric = 10000, 'resumen de caja informa abonos en efectivo';
  r := public.registrar_abono(cli, 3000, 'Nequi');
  assert (select monto_cierre_esperado from sesiones_caja where id_sesion=v_ses) = v_esp0 + 10000, 'abono por Nequi no suma al cajón';
  begin perform public.registrar_abono(cli, 999999, 'Efectivo'); raise exception 'FALLO abono excesivo';
  exception when others then if sqlerrm not like '%supera la deuda%' then raise exception 'T3a: %', sqlerrm; end if; end;
  begin perform public.registrar_abono(cli, 0, 'Efectivo'); raise exception 'FALLO abono cero';
  exception when others then if sqlerrm not like '%mayor que cero%' then raise exception 'T3b: %', sqlerrm; end if; end;
  log := log || 'T3 abonos efectivo y digital; ';

  -- T4 devolución de venta fiada baja la deuda (no sale efectivo)
  r := public.registrar_devolucion(fac, jsonb_build_array(jsonb_build_object('id_producto',v_jamon,'cantidad',1)), 'Producto dañado');
  assert (r->>'a_fiado')::boolean and (r->>'efectivo_a_entregar')::numeric = 0, 'devolución a cuenta del cliente';
  assert (select saldo from v_cartera where id_cliente=cli) = 20000 - 16500, 'saldo baja con la nota crédito (20000-16500)';
  assert (select monto_cierre_esperado from sesiones_caja where id_sesion=v_ses) = v_esp0 + 10000, 'devolución fiada no saca efectivo';
  log := log || 'T4 devolución sobre fiado; ';

  -- T5 estado de cuenta y reportes
  est := public.estado_cuenta(cli);
  assert jsonb_array_length(est->'movimientos') = 4 and (est->>'saldo')::numeric = 3500, 'estado de cuenta: 4 movimientos y saldo 3500';
  rep := public.reporte_contador(current_date, current_date);
  assert (rep->'por_metodo'->>'Fiado')::numeric >= 33000, 'reporte lista ventas fiadas';
  assert (rep->>'abonos_cartera')::numeric >= 13000, 'reporte suma abonos';
  assert (rep->>'por_cobrar')::numeric >= 3500, 'reporte informa por cobrar';
  log := log || 'T5 estado de cuenta y reporte; ';

  -- T6 permisos: sin sesión/anon no puede
  perform set_config('role','anon',true);
  begin perform public.registrar_abono(cli, 1, 'Efectivo'); raise exception 'FALLO anon';
  exception when insufficient_privilege then null; end;
  begin perform 1 from cartera_movimientos limit 1; raise exception 'FALLO anon lee cartera';
  exception when insufficient_privilege then null; end;
  log := log || 'T6 anon sin acceso; ';

  perform set_config('role', v_rol, true);
  raise exception 'PRUEBAS_OK (rollback): %', log;
end $$;
