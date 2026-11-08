-- Surtify 09: listado de facturas
--   * v_facturas_recientes ahora expone sede, empleado, cliente y número de unidades
--     (solo se AÑADEN columnas al final; no cambia lo que ya usa Devolver).
--   * El cajero filtra "Mis ventas" por su id_empleado; el administrador ve todas las sedes.
--   * El detalle de cada factura se consulta con devolucion_disponible() (ya valida la sede).
create or replace view v_facturas_recientes with (security_invoker = true) as
select f.id_factura, f.numero_factura, f.fecha_emision, f.total_facturado, f.metodo_pago,
       s.nombre_sucursal as sucursal, e.nombre as cajero,
       coalesce((select sum(nc.total_reversado) from notas_credito nc where nc.id_factura = f.id_factura), 0) as devuelto,
       p.id_sucursal, p.id_empleado, c.nombre as cliente,
       coalesce((select sum(df.cantidad) from detalles_factura df where df.id_factura = f.id_factura), 0)::int as unidades
  from facturas f
  join pedidos p on p.id_pedido = f.id_pedido
  join sucursales s on s.id_sucursal = p.id_sucursal
  left join empleados e on e.id_empleado = p.id_empleado
  left join clientes c on c.id_cliente = p.id_cliente;
grant select on v_facturas_recientes to authenticated;
