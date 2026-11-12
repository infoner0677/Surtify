-- Surtify 11: sugerencias de compra
-- sugerencias_compra(p_dias, p_cobertura, p_entrega): solo administrador.
-- Con las ventas netas (facturas - devoluciones) de los últimos p_dias días calcula, por producto y sede:
--   promedio diario, cuántos días alcanza el stock, fecha ideal para pedir y cantidad sugerida.
--   * p_entrega   = días que tarda el proveedor en entregar (por defecto 3)
--   * p_cobertura = para cuántos días quieres quedar surtido después de la entrega (por defecto 14)
-- Si el negocio lleva menos de p_dias días vendiendo, el promedio se calcula con los días reales.
create or replace function public.sugerencias_compra(p_dias integer default 30, p_cobertura integer default 14, p_entrega integer default 3)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_com integer := app.mi_comercio();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_dias integer := least(greatest(coalesce(p_dias, 30), 7), 90);
  v_cob integer := least(greatest(coalesce(p_cobertura, 14), 1), 60);
  v_ent integer := least(greatest(coalesce(p_entrega, 3), 0), 30);
  v_desde date; v_primera date; v_base integer; res jsonb;
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede ver las sugerencias de compra' using errcode = '42501'; end if;
  v_desde := v_hoy - (v_dias - 1);
  select min((f.fecha_emision at time zone 'America/Bogota')::date) into v_primera
    from facturas f join pedidos p on p.id_pedido = f.id_pedido join sucursales s on s.id_sucursal = p.id_sucursal
   where s.id_comercio = v_com;
  v_base := case when v_primera is null then v_dias else least(v_dias, greatest(1, v_hoy - v_primera + 1)) end;

  with ven as (
    select p.id_sucursal, df.id_producto, sum(df.cantidad)::numeric as u
      from detalles_factura df
      join facturas f on f.id_factura = df.id_factura
      join pedidos p on p.id_pedido = f.id_pedido
      join sucursales s on s.id_sucursal = p.id_sucursal
     where s.id_comercio = v_com and df.id_producto is not null
       and (f.fecha_emision at time zone 'America/Bogota')::date >= v_desde
     group by p.id_sucursal, df.id_producto),
  dev as (
    select p.id_sucursal, dn.id_producto, sum(dn.cantidad_devuelta)::numeric as u
      from detalles_nota_credito dn
      join notas_credito nc on nc.id_nota_credito = dn.id_nota_credito
      join facturas f on f.id_factura = nc.id_factura
      join pedidos p on p.id_pedido = f.id_pedido
      join sucursales s on s.id_sucursal = p.id_sucursal
     where s.id_comercio = v_com and dn.id_producto is not null
       and (nc.fecha_emision at time zone 'America/Bogota')::date >= v_desde
     group by p.id_sucursal, dn.id_producto),
  base as (
    select s.id_sucursal, s.nombre_sucursal, pr.id_producto, pr.nombre, pr.codigo_barras, i.stock, coalesce(i.stock_minimo, 0) as minimo,
           greatest(coalesce(v.u, 0) - coalesce(d.u, 0), 0) as vendidas
      from inventarios_sucursal i
      join sucursales s on s.id_sucursal = i.id_sucursal and s.id_comercio = v_com
      join productos pr on pr.id_producto = i.id_producto and pr.activo
      left join ven v on v.id_sucursal = i.id_sucursal and v.id_producto = i.id_producto
      left join dev d on d.id_sucursal = i.id_sucursal and d.id_producto = i.id_producto),
  calc as (
    select b.*, b.vendidas / v_base as prom,
           case when b.vendidas > 0 then round(b.stock / (b.vendidas / v_base), 1) end as alcanza
      from base b),
  sug as (
    select c.*,
           case when c.prom > 0 then greatest(ceil(c.prom * (v_ent + v_cob))::int - c.stock, 0)
                else greatest(c.minimo * 2 - c.stock, 0) end as sugerido,
           case when c.stock <= 0 or (c.alcanza is not null and c.alcanza <= v_ent) then 'Urgente'
                when c.stock <= c.minimo or (c.alcanza is not null and c.alcanza <= v_ent + 7) then 'Pronto'
                else 'Ok' end as urgencia
      from calc c)
  select jsonb_build_object(
    'hoy', v_hoy, 'dias', v_dias, 'dias_base', v_base, 'cobertura', v_cob, 'entrega', v_ent,
    'items', coalesce(jsonb_agg(jsonb_build_object(
        'id_sucursal', id_sucursal, 'sucursal', nombre_sucursal, 'id_producto', id_producto, 'producto', nombre,
        'codigo_barras', codigo_barras, 'stock', stock, 'stock_minimo', minimo, 'vendidas', vendidas,
        'promedio_dia', round(prom, 2), 'dias_alcanza', alcanza,
        'fecha_pedido', case when alcanza is not null then v_hoy + greatest(floor(alcanza - v_ent)::int, 0) end,
        'sugerido', sugerido, 'urgencia', urgencia)
      order by case urgencia when 'Urgente' then 0 else 1 end, alcanza nulls last, nombre_sucursal, nombre), '[]'::jsonb))
    into res
    from sug where urgencia <> 'Ok' and sugerido > 0;
  return res;
end $$;
revoke all on function public.sugerencias_compra(integer, integer, integer) from public, anon;
grant execute on function public.sugerencias_compra(integer, integer, integer) to authenticated;
