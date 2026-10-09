-- =====================================================================
-- Encargo3D · Script que crea la base de datos en Supabase
-- Cómo usarlo: Supabase → SQL Editor → New query → pegar todo → Run
-- =====================================================================

-- 1. Tabla principal: un registro por encargo de modelado
create table if not exists public.encargos (
  id                     bigint generated always as identity primary key,
  fecha                  date        not null default current_date,      -- día en que se registra o publica el encargo
  titulo                 text        not null,                           -- qué modelo o accesorio se encarga
  categoria              text,                                           -- tipo de producto (sombrero, cabello, etc.)
  modelador              text,                                           -- freelancer al que se le encarga
  pais                   text,                                           -- país del modelador o del encargo
  tipo_pago              text        not null check (tipo_pago in ('Precio fijo', 'Por hora')),
  costo_usd              numeric(10,2) check (costo_usd > 0),           -- lo que cuesta el encargo (precio fijo o total acordado)
  tarifa_hora_usd        numeric(10,2) check (tarifa_hora_usd > 0),     -- tarifa media por hora, si el encargo se paga por hora
  ingreso_por_venta_usd  numeric(10,4) check (ingreso_por_venta_usd > 0), -- lo que queda limpio por cada venta
  ventas_esperadas_30d   integer     check (ventas_esperadas_30d >= 0),  -- ventas que se esperan en 30 días

  -- REGLA DE NEGOCIO (la que antes se calculaba de memoria)
  -- ventas necesarias = costo del encargo / ingreso neto por venta, redondeado hacia arriba
  ventas_necesarias      integer generated always as (
                           ceil(costo_usd / nullif(ingreso_por_venta_usd, 0))::integer
                         ) stored,
  -- si las ventas esperadas alcanzan para recuperar el costo, conviene encargar
  decision               text generated always as (
                           case
                             when costo_usd is null or ingreso_por_venta_usd is null or ventas_esperadas_30d is null then null
                             when ceil(costo_usd / ingreso_por_venta_usd) <= ventas_esperadas_30d then 'Encargar'
                             else 'No encargar'
                           end
                         ) stored,

  estado                 text        not null default 'Registrado'
                         check (estado in ('Registrado', 'En modelado', 'En revisión', 'Aprobado', 'Publicado', 'Descartado')),
  fecha_entrega          date,                                           -- fecha de entrega acordada con el modelador
  origen                 text        not null default 'Formulario web'
                         check (origen in ('Formulario web', 'Histórico mensual')),
  creado_en              timestamptz not null default now()
);

create index if not exists encargos_fecha_idx  on public.encargos (fecha);
create index if not exists encargos_origen_idx on public.encargos (origen);

-- 2. Seguridad (Row Level Security)
-- La página web usa la llave pública (anon). Puede leer, registrar encargos nuevos
-- y cambiar solo el estado y la fecha de entrega. No puede borrar ni tocar costos.
alter table public.encargos enable row level security;

drop policy if exists "leer encargos"      on public.encargos;
drop policy if exists "registrar encargos" on public.encargos;
drop policy if exists "actualizar estado"  on public.encargos;

create policy "leer encargos" on public.encargos
  for select to anon, authenticated using (true);

create policy "registrar encargos" on public.encargos
  for insert to anon, authenticated with check (origen = 'Formulario web' and costo_usd is not null);

create policy "actualizar estado" on public.encargos
  for update to anon, authenticated
  using (origen = 'Formulario web') with check (origen = 'Formulario web');

revoke update on public.encargos from anon, authenticated;
grant  update (estado, fecha_entrega) on public.encargos to anon, authenticated;

-- 3. Parámetros de la regla (valores de referencia del negocio)
-- costo máximo recuperable = ventas esperadas de referencia × ingreso neto por venta de referencia
create table if not exists public.parametros (
  id                    integer primary key default 1 check (id = 1),
  ventas_esperadas_ref  integer       not null default 400,
  ingreso_ref_usd       numeric(10,4) not null default 0.09,
  segmento              text          not null default 'Modelado 3D (assets/personajes)'  -- segmento del histórico que se compara con el negocio
);
insert into public.parametros (id) values (1) on conflict (id) do nothing;

alter table public.parametros enable row level security;
drop policy if exists "leer parametros" on public.parametros;
create policy "leer parametros" on public.parametros for select to anon, authenticated using (true);

-- 4. Vista con los indicadores por mes (la leen los dos tableros)
create or replace view public.indicadores_mes with (security_invoker = true) as
with p as (select ventas_esperadas_ref * ingreso_ref_usd as costo_max from public.parametros where id = 1)
select
  to_char(date_trunc('month', e.fecha), 'YYYY-MM')                                        as mes,
  count(*)                                                                               as total_encargos,
  -- I1 costo promedio por encargo de precio fijo
  count(*) filter (where e.tipo_pago = 'Precio fijo' and e.costo_usd is not null)        as fijos_con_costo,
  coalesce(sum(e.costo_usd) filter (where e.tipo_pago = 'Precio fijo'), 0)               as suma_costo_fijo,
  round(avg(e.costo_usd) filter (where e.tipo_pago = 'Precio fijo'), 2)                  as i1_costo_promedio_fijo,
  -- I2 tasa de encargos recuperables
  count(*) filter (where e.tipo_pago = 'Precio fijo' and e.costo_usd <= p.costo_max)     as fijos_recuperables,
  round(count(*) filter (where e.tipo_pago = 'Precio fijo' and e.costo_usd <= p.costo_max)::numeric
        / nullif(count(*) filter (where e.tipo_pago = 'Precio fijo' and e.costo_usd is not null), 0), 4) as i2_tasa_recuperables,
  -- I3 participación de encargos por hora
  count(*) filter (where e.tipo_pago = 'Por hora')                                       as por_hora,
  round(count(*) filter (where e.tipo_pago = 'Por hora')::numeric / nullif(count(*), 0), 4) as i3_participacion_por_hora,
  -- I4 tasa de decisión "Encargar" (solo encargos con decisión calculada)
  count(*) filter (where e.decision is not null)                                         as con_decision,
  count(*) filter (where e.decision = 'Encargar')                                        as decision_encargar,
  round(count(*) filter (where e.decision = 'Encargar')::numeric
        / nullif(count(*) filter (where e.decision is not null), 0), 4)                  as i4_tasa_encargar,
  max(p.costo_max)                                                                       as costo_max_usd
from public.encargos e cross join p
-- encargos propios (web) + histórico del segmento de modelado 3D, igual que el Excel
where e.origen = 'Formulario web'
   or e.categoria = (select segmento from public.parametros where id = 1)
group by 1
order by 1;

grant select on public.indicadores_mes to anon, authenticated;
