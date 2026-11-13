-- Pruebas de autoservicio (ejecutadas en Supabase; terminan en excepción PRUEBAS_OK = rollback)
-- Resultado esperado:
-- PRUEBAS_OK catalogo;sede_normal_rechazada;vacio_rechazado;cant_100_rechazada;precio_servidor;anon_no_confirma;anon_no_lee_tabla;aprobado;stock_descontado;idempotente;estado_aprobado;rechazado;carrera_stock_sin_venta;vencido_aprobado;consecutivo_ok;personal_ok;panel_reporte_ok;
-- Cubre: anon solo catálogo/crear/estado; precio del cliente ignorado; confirmación solo service_role; idempotencia;
-- dos clientes pagando el último stock (el segundo queda 'Pago sin venta' sin descontar ni gastar consecutivo);
-- pago aprobado tras vencer; visibilidad por sede; panel y reporte con ventas sin cajero.

-- ===== Migración 14 (comprobante Bre-B y fiado). Resultado esperado de las dos pruebas (rollback) =====
-- Parte A: PRUEBAS_OK catalogo_modo;crear_comprobante;tope_rechaza;pasarela_no_aplica;anon_sube_su_captura;sin_pago_no_sube;carpeta_libre_rechazada;anon_no_lee;ref_corta_rechazada;sin_imagen_rechazada;ruta_ajena_rechazada;comprobante_ok;por_verificar;doble_envio_rechazado;ref_repetida_rechazada;sin_stock_sin_venta;cajero_no_concilia;concilia_una_vez;carlos_concilia;configurar_ok;cajero_no_configura;cupo_no_editable;
-- Parte B: PRUEBAS_OK cliente_sin_acceso;exige_consentimiento;celular_validado;registro_unico;fiado_requiere_aprobacion;dueno_ve_pendiente;mostrador_bloquea_no_aprobado;cupo_obligatorio;fiado_ok;comprobante_fiado;cupo_respetado;cartera_ok;cuenta_ajena_rechazada;dueno_ve_saldo;rechazado_no_fia;pasarela_sigue_ok;panel_reporte_ok;

-- ===== Migración 15 (importar_productos). Resultado esperado (rollback) =====
-- PRUEBAS_OK cajero_no_importa;vacio_rechazado;sede_ajena;preview_sin_escribir;validaciones;crea_con_inventarios;reimport_actualiza_sin_tocar_stock;sin_duplicar;

-- ===== Migración 16 (equipo). Resultado esperado (rollback) =====
-- PRUEBAS_OK anon_no;cajero_no_lista;cajero_no_crea;lista_ok;aislado;correo_invalido;sede_ajena;sede_autoservicio_no;rol_ajeno;correo_repetido;correo_de_otro_comercio_bloqueado;crea_normaliza;persona_ajena;actualizar_ajena;no_se_desactiva_a_si_mismo;no_se_quita_admin;rol_ajeno_update;cambia_rol_sede;desactivada_sin_acceso;reactivada;accion_cerrada;registrar_ajena;eventos;descartar;
