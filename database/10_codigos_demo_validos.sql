-- Surtify 10: códigos de barras de la demo con dígito verificador EAN-13 válido
-- (el lector de cámara descarta los códigos con dígito verificador incorrecto).
-- En instalaciones nuevas ya vienen correctos desde 04_datos_demo.sql; esto corrige bases ya cargadas.
update productos set codigo_barras = '7701234560010' where codigo_barras = '7701234560012';
update productos set codigo_barras = '7709876540032' where codigo_barras = '7709876540034';
update productos set codigo_barras = '7702222000013' where codigo_barras = '7702222000019';
update productos set codigo_barras = '7702222000020' where codigo_barras = '7702222000026';
update productos set codigo_barras = '7703333000015' where codigo_barras = '7703333000014';
update productos set codigo_barras = '7703333000022' where codigo_barras = '7703333000021';
