-- Pruebas de sugerencias_compra (11_sugerencias_compra.sql). Todo se revierte al final (PRUEBAS_OK ... rollback).
do $$
declare
  u_carlos uuid; u_diana uuid; v_rest int; v_jamon int; r jsonb; it jsonb; v_ven int; v_base int; v_prom numeric; v_dev int;
begin
  select auth_user_id into u_carlos from empleados where email='carlos.mendoza@eltriunfo.com';
  select auth_user_id into u_diana from empleados where email='diana.gomez@eltriunfo.com';
  select id_sucursal into v_rest from sucursales where nombre_sucursal='Sede Principal - Restrepo';
  select id_producto into v_jamon from productos where codigo_barras='7701234560010';
  update inventarios_sucursal set stock=4, stock_minimo=2 where id_sucursal=v_rest and id_producto=v_jamon;

  perform set_config('role','authenticated',true);
  perform set_config('request.jwt.claim.sub', u_diana::text, true);
  begin perform public.sugerencias_compra(); raise exception 'FALLO cajero no debe ver';
  exception when others then if sqlerrm not like '%administrador%' then raise exception 'T1: %', sqlerrm; end if; end;

  perform set_config('request.jwt.claim.sub', u_carlos::text, true);
  r := public.sugerencias_compra();
  select x into it from jsonb_array_elements(r->'items') x where (x->>'id_producto')::int=v_jamon and (x->>'id_sucursal')::int=v_rest;
  assert it is not null, 'jamón con stock 4 debe aparecer: '||r::text;
  select coalesce(sum(df.cantidad),0) into v_ven from detalles_factura df join facturas f on f.id_factura=df.id_factura join pedidos p on p.id_pedido=f.id_pedido
    where p.id_sucursal=v_rest and df.id_producto=v_jamon and f.fecha_emision >= now()-interval '30 days';
  select coalesce(sum(dn.cantidad_devuelta),0) into v_dev from detalles_nota_credito dn join notas_credito nc on nc.id_nota_credito=dn.id_nota_credito join facturas f on f.id_factura=nc.id_factura join pedidos p on p.id_pedido=f.id_pedido
    where p.id_sucursal=v_rest and dn.id_producto=v_jamon and nc.fecha_emision >= now()-interval '30 days';
  assert (it->>'vendidas')::numeric = v_ven - v_dev, 'vendidas netas';
  v_base := (r->>'dias_base')::int; v_prom := (v_ven - v_dev)::numeric / v_base;
  assert abs((it->>'promedio_dia')::numeric - round(v_prom,2)) < 0.01, 'promedio';
  assert (it->>'sugerido')::int = greatest(ceil(v_prom*17)::int - 4, 0), 'sugerido = ceil(prom*(entrega+cobertura)) - stock';
  assert it->>'urgencia' in ('Urgente','Pronto'), 'urgencia';
  perform set_config('role','postgres',true);
  update inventarios_sucursal set stock=5000 where id_sucursal=v_rest and id_producto=v_jamon;
  perform set_config('role','authenticated',true);
  r := public.sugerencias_compra();
  assert not exists (select 1 from jsonb_array_elements(r->'items') x where (x->>'id_producto')::int=v_jamon and (x->>'id_sucursal')::int=v_rest), 'con stock 5000 no se sugiere';
  raise exception 'PRUEBAS_OK sugerencias_compra base_dias=% total_items=%', v_base, jsonb_array_length(r->'items');
end $$;
