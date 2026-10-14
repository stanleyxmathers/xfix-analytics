-- ============================================================
-- XFIX Analytics — KPI руководителя отдела диагностики
-- Отдельный слой: свой месячный аплоад, не трогает actions/employee_stats.
-- Прогнать целиком в Supabase SQL Editor (идемпотентно).
-- ============================================================

-- 1. Месячные аплоады KPI-отчёта (снимок месяца; повторная заливка заменяет)
CREATE TABLE IF NOT EXISTS kpi_uploads (
  id          SERIAL PRIMARY KEY,
  month       DATE         NOT NULL UNIQUE,   -- первый день месяца (YYYY-MM-01)
  filename    VARCHAR(500) NOT NULL,
  row_count   INTEGER      DEFAULT 0,
  upload_date TIMESTAMPTZ  DEFAULT NOW()
);

-- 2. Сырые строки KPI-отчёта. Храним только поля, нужные для показателей.
--    Действия ВСЕХ сотрудников (инженеры/логисты тоже) — по персоналиям не
--    агрегируем, считаем показатели руководителя по месяцу целиком.
CREATE TABLE IF NOT EXISTS kpi_rows (
  id            BIGSERIAL PRIMARY KEY,
  kpi_upload_id INTEGER      NOT NULL REFERENCES kpi_uploads(id) ON DELETE CASCADE,
  month         DATE         NOT NULL,
  employee      VARCHAR(255),
  action_type   VARCHAR(255),   -- "Тип"
  subgroup      VARCHAR(500),   -- "Подгруппа"
  is_corp       SMALLINT DEFAULT 0,   -- "Маркер корп" = 1
  is_overdue    SMALLINT DEFAULT 0,   -- "Ключ просрочен" = 1
  price         NUMERIC(12,2) DEFAULT 0
);
-- "Группа" (с октября 2026: «Проверка перед выдачей» с Группой «Ошибки»)
ALTER TABLE kpi_rows ADD COLUMN IF NOT EXISTS group_name VARCHAR(255);
CREATE INDEX IF NOT EXISTS idx_kpi_rows_month  ON kpi_rows(month);
CREATE INDEX IF NOT EXISTS idx_kpi_rows_upload ON kpi_rows(kpi_upload_id);

-- 3. Настройки показателей: шкалы (порог %, баллы) + названия действий и фильтры.
--    Одна строка на показатель. config хранит редактируемую часть определения.
CREATE TABLE IF NOT EXISTS kpi_settings (
  metric_key TEXT PRIMARY KEY,
  config     JSONB       NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3a. Версии схемы KPI (веса, шкалы, правила отбора) по месяцам.
--     Схема действует с effective_from и до следующей версии. Месяцы до
--     октября 2026 считаются по старой схеме (код + kpi_settings) и не меняются.
--     config: {threshold, pointRub, metrics: [{key, title, maxPts, scale, …}]}
CREATE TABLE IF NOT EXISTS kpi_schemes (
  effective_from DATE        PRIMARY KEY,   -- первый день месяца
  config         JSONB       NOT NULL,
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Личный план сотрудников по месяцам (метрика 6). Руководитель выставляет
--    план заработка и фикс; фактический заработок берём из kpi_rows.
CREATE TABLE IF NOT EXISTS kpi_plan (
  month      DATE          NOT NULL,   -- первый день месяца
  employee   TEXT          NOT NULL,
  plan       NUMERIC(12,2) DEFAULT 0,  -- плановый заработок
  fix        NUMERIC(12,2) DEFAULT 0,  -- фикс (для будущего расчёта премии)
  updated_at TIMESTAMPTZ   DEFAULT NOW(),
  PRIMARY KEY (month, employee)
);

-- 5. Сотрудники, исключённые из личного плана (не мой отдел). Глобальный
--    список (членство в отделе стабильно между месяцами).
CREATE TABLE IF NOT EXISTS kpi_plan_excluded (
  employee   TEXT PRIMARY KEY,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- RLS — внутренний инструмент без авторизации: анонимам полный CRUD
-- (как action_settings/employee_departments в основной схеме).
-- ============================================================
ALTER TABLE kpi_uploads  ENABLE ROW LEVEL SECURITY;
ALTER TABLE kpi_rows     ENABLE ROW LEVEL SECURITY;
ALTER TABLE kpi_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE kpi_schemes  ENABLE ROW LEVEL SECURITY;
ALTER TABLE kpi_plan     ENABLE ROW LEVEL SECURITY;
ALTER TABLE kpi_plan_excluded ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_all ON kpi_plan_excluded;
CREATE POLICY anon_all ON kpi_plan_excluded FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS anon_all ON kpi_uploads;
CREATE POLICY anon_all ON kpi_uploads  FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS anon_all ON kpi_rows;
CREATE POLICY anon_all ON kpi_rows     FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS anon_all ON kpi_settings;
CREATE POLICY anon_all ON kpi_settings FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS anon_all ON kpi_schemes;
CREATE POLICY anon_all ON kpi_schemes  FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS anon_all ON kpi_plan;
CREATE POLICY anon_all ON kpi_plan     FOR ALL TO anon USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON kpi_uploads, kpi_rows, kpi_settings, kpi_schemes, kpi_plan, kpi_plan_excluded TO anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon;
