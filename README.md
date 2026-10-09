# Encargo3D

Sistema para controlar los encargos de modelado 3D a freelancers y decidir cuáles conviene producir.

- `index.html`: página web con tres pantallas (Nuevo encargo, Seguimiento y Tablero). Lee y escribe en Supabase.
- `base_de_datos.sql`: script que crea la tabla `encargos`, la regla de negocio y los permisos.

## Regla de negocio
`ventas necesarias = costo del encargo ÷ ingreso neto por venta` (redondeado hacia arriba).
Si las ventas esperadas en 30 días alcanzan las ventas necesarias, la decisión es **Encargar**; si no, **No encargar**.
La regla se calcula en la base de datos (columnas generadas), así que da el mismo resultado sin importar desde dónde se registre el encargo.

Curso Laboratorio Digital II · UPC · 2026-2
