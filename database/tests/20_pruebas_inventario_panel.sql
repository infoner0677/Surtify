-- =============================================================================
-- Pruebas de inventario y panel multisede (06_inventario_y_panel.sql).
-- Se pueden ejecutar directo en el SQL Editor de Supabase: TODO se revierte al final
-- (la última línea lanza un error a propósito: "PRUEBAS_OK ... rollback"), así no queda
-- ninguna venta, usuario ni producto de prueba en tu base de datos.
-- Requiere los datos demo (04 y 06). Si Carlos/Diana no existen en Auth, se crean temporalmente.
-- =============================================================================
do $$
declare
  v_rol text := current_user;
  log text := '';
  u_carlos uuid; u_diana uuid;
  v_rest int; v_norte int; v_jamon int; v_stock0 int; v_nuevo int;
  r jsonb; n int;
begin
  select auth_user_id into u_carlos from empleados where email = 'carlos.mendoza@eltriunfo.com';
  if u_carlos is null then
    insert into auth.users (id, email, email_confirmed_at) values (gen_random_uuid(), 'carlos.mendoza@eltriunfo.com', now()) returning id into u_carlos;
  end if;
  select auth_user_id into u_diana from empleados where email = 'diana.gomez@eltriunfo.com';
  if u_diana is null then
    insert into auth.users (id, email, email_confirmed_at) values (gen_random_uuid(), 'diana.gomez@eltriunfo.com', now()) returning id into u_diana;
  end if;
  assert (select auth_user_id from empleados where email = 'carlos.mendoza@eltriunfo.com') = u_carlos, 'Carlos enlazado con Auth';
  assert (select auth_user_id from empleados where email = 'diana.gomez@eltriunfo.com') = u_diana, 'Diana enlazada con Auth';

  select id_sucursal into v_rest  from sucursales where nombre_sucursal = 'Sede Principal - Restrepo';
  select id_sucursal into v_norte from sucursales where nombre_sucursal = 'Sede Norte - Chapinero';
  select id_producto into v_jamon from productos where codigo_barras = '7701234560012';
  assert v_rest is not null and v_norte is not null and v_jamon is not null, 'datos demo presentes (04 y 06)';

  -- ===== T1: el cajero NO puede usar funciones de administrador =====
  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  perform set_config('role', 'authenticated', true);
  begin perform public.ajustar_stock(v_rest, v_jamon, 5);
        raise exception 'FALLO: ajustar_stock debía fallar para el cajero';
  exception when others then if sqlerrm not like '%administrador%' then raise exception 'T1a inesperado: %', sqlerrm; end if; end;
  begin perform public.panel_multisede(7);
        raise exception 'FALLO: panel_multisede debía fallar para el cajero';
  exception when others then if sqlerrm not like '%administrador%' then raise exception 'T1b inesperado: %', sqlerrm; end if; end;
  begin perform public.crear_producto('X', 1, 0, null, null, v_rest, 1, 1);
        raise exception 'FALLO: crear_producto debía fallar para el cajero';
  exception when others then if sqlerrm not like '%administrador%' then raise exception 'T1c inesperado: %', sqlerrm; end if; end;
  assert (select count(distinct id_sucursal) from v_inventario_admin) = 1, 'el cajero solo ve el inventario de su sede';
  log := log || 'T1 cajero sin acceso a funciones de admin y solo ve su sede; ';

  -- ===== T2: el cajero vende (alimenta el panel) =====
  perform set_config('role', v_rol, true);
  perform set_config('role', 'authenticated', true);
  if not exists (select 1 from sesiones_caja where id_empleado = (select id_empleado from empleados where email = 'diana.gomez@eltriunfo.com') and estado_caja = 'Abierta') then
    perform public.abrir_caja(50000);
  end if;
  select stock into v_stock0 from inventarios_sucursal where id_sucursal = v_rest and id_producto = v_jamon;
  r := public.registrar_venta(jsonb_build_array(jsonb_build_object('id_producto', v_jamon, 'cantidad', 2)), 'Efectivo', 40000);
  assert (r->>'total')::numeric = 33000 and (r->>'cambio')::numeric = 7000, 'venta de 2 jamones';
  log := log || 'T2 venta registrada; ';

  -- ===== T3: Carlos gestiona inventario =====
  perform set_config('role', v_rol, true);
  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into n from v_inventario_admin;
  assert n >= 18, 'el admin ve el inventario de las dos sedes';
  assert (select count(*) from v_inventario_admin where en_alerta and sucursal like 'Sede Norte%') >= 1, 'alerta demo en Sede Norte (Salchicha 6 < 10)';

  r := public.ajustar_stock(v_rest, v_jamon, 20);
  assert (r->>'stock')::int = v_stock0 - 2 + 20, 'entrada de mercancía suma al stock (después de la venta)';
  r := public.ajustar_stock(v_rest, v_jamon, 0, 25);
  assert (r->>'stock_minimo')::int = 25, 'cambia el stock mínimo';
  begin perform public.ajustar_stock(v_rest, v_jamon, -99999);
        raise exception 'FALLO: no debía dejar stock negativo';
  exception when others then if sqlerrm not like '%negativo%' then raise exception 'T3a inesperado: %', sqlerrm; end if; end;
  begin perform public.ajustar_stock(999999, v_jamon, 1);
        raise exception 'FALLO: sucursal inexistente';
  exception when others then if sqlerrm not like '%Sucursal no válida%' then raise exception 'T3b inesperado: %', sqlerrm; end if; end;
  log := log || 'T3 entradas, mínimo y validaciones; ';

  -- ===== T4: producto nuevo =====
  r := public.crear_producto('Producto de prueba', 9900, 19, 'TEST-0001', null, v_norte, 15, 4);
  v_nuevo := (r->>'id_producto')::int;
  assert (select count(*) from inventarios_sucursal where id_producto = v_nuevo) = 2, 'queda en las dos sedes';
  assert (select stock from inventarios_sucursal where id_producto = v_nuevo and id_sucursal = v_norte) = 15, 'stock inicial en la sede elegida';
  assert (select stock from inventarios_sucursal where id_producto = v_nuevo and id_sucursal = v_rest) = 0, 'stock 0 en la otra sede';
  begin perform public.crear_producto('Duplicado', 100, 0, 'TEST-0001', null, v_norte, 1, 1);
        raise exception 'FALLO: debía rechazar código duplicado';
  exception when others then if sqlerrm not like '%código de barras%' then raise exception 'T4 inesperado: %', sqlerrm; end if; end;
  log := log || 'T4 producto nuevo en todas las sedes; ';

  -- ===== T5: panel multisede =====
  r := public.panel_multisede(7);
  assert jsonb_array_length(r->'sucursales') = 2, 'el panel lista las dos sucursales';
  assert (r->'totales'->>'num_ventas')::int >= 1 and (r->'totales'->>'ventas')::numeric >= 33000, 'totales incluyen la venta';
  assert (select (x->>'ventas_hoy')::numeric from jsonb_array_elements(r->'sucursales') x where x->>'nombre' like 'Sede Principal%') >= 33000, 'ventas de hoy en Restrepo';
  assert (select jsonb_array_length(x->'cajas_abiertas') from jsonb_array_elements(r->'sucursales') x where x->>'nombre' like 'Sede Principal%') >= 1, 'caja abierta de Diana visible';
  assert jsonb_array_length(r->'ventas_por_dia') = 7, 'serie de 7 días';
  assert (r->'ventas_por_metodo'->>'Efectivo')::numeric >= 33000, 'ventas por método';
  assert jsonb_array_length(r->'top_productos') >= 1 and jsonb_array_length(r->'alertas_stock') >= 1 and jsonb_array_length(r->'turnos_recientes') >= 1, 'top, alertas y turnos';
  assert jsonb_array_length(public.panel_multisede(30)->'ventas_por_dia') = 30, 'periodo de 30 días';
  log := log || 'T5 panel multisede completo; ';

  perform set_config('role', v_rol, true);
  raise exception 'PRUEBAS_OK (rollback, no queda ningún dato de prueba): %', log;
end $$;
