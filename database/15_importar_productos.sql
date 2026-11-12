-- =============================================================================
-- SURTIFY · 15_importar_productos.sql
--   Carga masiva de productos desde Excel/CSV (solo administrador).
--   - Una sola función: importar_productos(sucursal, filas, aplicar). Con aplicar=false solo VALIDA (vista previa).
--   - Producto existente (mismo código de barras, o mismo nombre si la fila no trae código): actualiza nombre,
--     precio, IVA y categoría. NO toca el stock (para no pisar conteos reales al reimportar).
--   - Producto nuevo: se crea con stock inicial en la sede elegida y 0 en las demás.
--   - Categorías nuevas se crean por nombre. Máx. 2000 filas por carga. Todo o nada por llamada.
-- =============================================================================
create or replace function public.importar_productos(p_sucursal integer, p_filas jsonb, p_aplicar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_com integer := app.mi_comercio();
  f jsonb; i integer := 0;
  v_nombre text; v_precio numeric; v_iva numeric; v_cod text; v_cat text; v_stock integer; v_min integer;
  v_id integer; v_idcat integer; v_err text; v_estado text;
  v_res jsonb := '[]'::jsonb; v_nuevos integer := 0; v_act integer := 0; v_errs integer := 0;
  v_cods text[] := '{}'; v_noms text[] := '{}';
begin
  if not app.es_admin() then raise exception 'Solo el administrador puede importar productos' using errcode = '42501'; end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' or jsonb_array_length(p_filas) = 0 then
    raise exception 'El archivo no trae productos'; end if;
  if jsonb_array_length(p_filas) > 2000 then raise exception 'Máximo 2000 productos por carga; divide el archivo'; end if;
  if not exists (select 1 from sucursales where id_sucursal = p_sucursal and id_comercio = v_com) then
    raise exception 'Sucursal no válida'; end if;

  for f in select value from jsonb_array_elements(p_filas) loop
    i := i + 1; v_err := null; v_id := null; v_idcat := null;
    v_nombre := btrim(coalesce(f->>'nombre', ''));
    v_cod := nullif(btrim(coalesce(f->>'codigo_barras', '')), '');
    v_cat := nullif(btrim(coalesce(f->>'categoria', '')), '');
    begin
      v_precio := nullif(btrim(coalesce(f->>'precio', '')), '')::numeric;
      v_iva    := coalesce(nullif(btrim(coalesce(f->>'iva', '')), '')::numeric, 0);
      v_stock  := coalesce(nullif(btrim(coalesce(f->>'stock', '')), '')::numeric, 0)::integer;
      v_min    := coalesce(nullif(btrim(coalesce(f->>'stock_minimo', '')), '')::numeric, 5)::integer;
    exception when others then v_err := 'Hay un número mal escrito (precio, IVA o stock)';
    end;

    if v_err is null then
      if v_nombre = '' then v_err := 'Falta el nombre';
      elsif length(v_nombre) > 150 then v_err := 'El nombre supera 150 caracteres';
      elsif v_precio is null then v_err := 'Falta el precio';
      elsif v_precio < 0 or v_precio > 99999999 then v_err := 'El precio no es válido';
      elsif v_iva < 0 or v_iva > 100 then v_err := 'El IVA debe estar entre 0 y 100';
      elsif v_stock < 0 or v_stock > 1000000 or v_min < 0 or v_min > 1000000 then v_err := 'El stock no es válido';
      elsif v_cod is not null and length(v_cod) > 100 then v_err := 'El código de barras es demasiado largo';
      elsif v_cat is not null and length(v_cat) > 100 then v_err := 'La categoría es demasiado larga';
      elsif v_cod is not null and v_cod = any (v_cods) then v_err := 'Código de barras repetido en el archivo';
      elsif v_cod is null and lower(v_nombre) = any (v_noms) then v_err := 'Producto repetido en el archivo (mismo nombre sin código)';
      end if;
    end if;

    if v_err is null then
      if v_cod is not null then
        v_cods := v_cods || v_cod;
        select id_producto into v_id from productos where id_comercio = v_com and codigo_barras = v_cod;
      else
        v_noms := v_noms || lower(v_nombre);
        select min(id_producto) into v_id from productos where id_comercio = v_com and lower(btrim(nombre)) = lower(v_nombre);
      end if;
      v_estado := case when v_id is null then 'Nuevo' else 'Actualiza' end;

      if p_aplicar then
        if v_cat is not null then
          select id_categoria into v_idcat from categorias where id_comercio = v_com and lower(btrim(nombre)) = lower(v_cat) limit 1;
          if v_idcat is null then insert into categorias (id_comercio, nombre) values (v_com, v_cat) returning id_categoria into v_idcat; end if;
        end if;
        if v_id is null then
          insert into productos (id_comercio, id_categoria, nombre, precio_venta, iva_porcentaje, codigo_barras)
          values (v_com, v_idcat, v_nombre, v_precio, v_iva, v_cod) returning id_producto into v_id;
          insert into inventarios_sucursal (id_sucursal, id_producto, stock, stock_minimo)
          select s.id_sucursal, v_id, case when s.id_sucursal = p_sucursal then v_stock else 0 end, v_min
            from sucursales s where s.id_comercio = v_com;
        else
          update productos set nombre = v_nombre, precio_venta = v_precio, iva_porcentaje = v_iva,
                 id_categoria = coalesce(v_idcat, id_categoria), codigo_barras = coalesce(codigo_barras, v_cod)
           where id_producto = v_id and id_comercio = v_com;
        end if;
      end if;
      if v_estado = 'Nuevo' then v_nuevos := v_nuevos + 1; else v_act := v_act + 1; end if;
    else
      v_estado := 'Error'; v_errs := v_errs + 1;
    end if;
    v_res := v_res || jsonb_build_object('fila', i, 'nombre', v_nombre, 'estado', v_estado, 'error', v_err);
  end loop;

  return jsonb_build_object('aplicado', p_aplicar, 'nuevos', v_nuevos, 'actualizados', v_act, 'errores', v_errs, 'filas', v_res);
end $$;
revoke all on function public.importar_productos(integer, jsonb, boolean) from public, anon;
grant execute on function public.importar_productos(integer, jsonb, boolean) to authenticated;
