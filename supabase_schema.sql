-- ============================================================
-- XFIX Analytics — Supabase schema
-- Полная замена n8n+Postgres. Прогнать целиком в Supabase SQL Editor.
-- ============================================================

-- 1. Загрузки — еженедельные отчёты (снимок недели, не пересчитывается)
CREATE TABLE IF NOT EXISTS uploads (
  id           SERIAL PRIMARY KEY,
  upload_date  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  report_week  DATE        NOT NULL,
  filename     VARCHAR(500) NOT NULL,
  row_count    INTEGER      DEFAULT 0,
  UNIQUE(report_week)
);

-- 2. Действия — все строки из Excel (главная единица анализа: service_id)
CREATE TABLE IF NOT EXISTS actions (
  id           BIGINT       NOT NULL,
  report_id    INTEGER      NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  employee     VARCHAR(255),
  action_date  DATE,
  office       VARCHAR(100),
  department   VARCHAR(100),
  action_type  VARCHAR(255),   -- "Тип": Обработано / Ненормированная работа / ...
  group_name   VARCHAR(500),   -- "Группа" (device model)
  subgroup     VARCHAR(500),   -- "Подгруппа" (device type: iPhone/iPad/Watch/Mac/AirPods)
  comment      TEXT,
  price        NUMERIC(10,2) DEFAULT 0,
  service_id   BIGINT,         -- "id сервис" — единица анализа
  vendor       VARCHAR(100),   -- Apple / Яндекс
  PRIMARY KEY (id, report_id)
);

CREATE INDEX IF NOT EXISTS idx_actions_service_id  ON actions(service_id);
CREATE INDEX IF NOT EXISTS idx_actions_report_id   ON actions(report_id);
CREATE INDEX IF NOT EXISTS idx_actions_employee    ON actions(employee);
CREATE INDEX IF NOT EXISTS idx_actions_vendor      ON actions(vendor);
CREATE INDEX IF NOT EXISTS idx_actions_action_type ON actions(action_type);
CREATE INDEX IF NOT EXISTS idx_actions_subgroup    ON actions(subgroup);

-- 3. Обращения — агрегат по service_id (база/доп. действия через action_settings.is_base)
CREATE TABLE IF NOT EXISTS services (
  id             SERIAL PRIMARY KEY,
  service_id     BIGINT        NOT NULL,
  report_id      INTEGER       NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  vendor         VARCHAR(100),
  group_name     VARCHAR(255),  -- subgroup/device_type
  total_price    NUMERIC(10,2) DEFAULT 0,
  actions_count  INTEGER       DEFAULT 0,
  employee_count INTEGER       DEFAULT 0,
  employees      TEXT[]        DEFAULT '{}',
  action_types   TEXT[]        DEFAULT '{}',
  extra_actions  TEXT[]        DEFAULT '{}',
  base_cost      NUMERIC(10,2) DEFAULT 0,   -- SUM(price) где is_base=true
  overrun        NUMERIC(10,2) DEFAULT 0,   -- SUM(price) где is_base=false (доп. стоимость)
  overrun_pct    NUMERIC(10,2) DEFAULT 0,
  overrun_reason TEXT,
  zone           VARCHAR(20)   DEFAULT 'normal',  -- normal | small | elevated | critical
  UNIQUE(service_id, report_id)
);

CREATE INDEX IF NOT EXISTS idx_services_report_id ON services(report_id);
CREATE INDEX IF NOT EXISTS idx_services_vendor    ON services(vendor);
CREATE INDEX IF NOT EXISTS idx_services_zone      ON services(zone);
CREATE INDEX IF NOT EXISTS idx_services_overrun   ON services(overrun DESC);

-- 4. Аномалии
CREATE TABLE IF NOT EXISTS anomalies (
  id            SERIAL PRIMARY KEY,
  report_id     INTEGER      NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  anomaly_type  VARCHAR(50),   -- employee | service
  entity_id     VARCHAR(500),
  message       TEXT,
  severity      VARCHAR(20)   DEFAULT 'warning',  -- warning | critical
  metric        VARCHAR(200),
  value         NUMERIC(10,2),
  avg_value     NUMERIC(10,2),
  deviation_pct NUMERIC(10,2),
  created_at    TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_anomalies_report_id ON anomalies(report_id);
CREATE INDEX IF NOT EXISTS idx_anomalies_severity  ON anomalies(severity);
CREATE INDEX IF NOT EXISTS idx_anomalies_type      ON anomalies(anomaly_type);

-- 5. Инсайты по неделям (week-over-week, |delta| >= 5%)
CREATE TABLE IF NOT EXISTS weekly_insights (
  id           SERIAL PRIMARY KEY,
  report_id    INTEGER      NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  insight_type VARCHAR(200),
  message      TEXT,
  change_pct   NUMERIC(10,2),
  direction    VARCHAR(10),     -- up | down
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_insights_report_id ON weekly_insights(report_id);

-- 6. Статистика сотрудников по отчётам (снимок недели)
CREATE TABLE IF NOT EXISTS employee_stats (
  id                 SERIAL PRIMARY KEY,
  report_id          INTEGER       NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  employee           VARCHAR(255)  NOT NULL,
  department         VARCHAR(100),
  services_count     INTEGER       DEFAULT 0,
  total_earnings     NUMERIC(10,2) DEFAULT 0,
  avg_service_cost   NUMERIC(10,2) DEFAULT 0,
  non_standard_count INTEGER       DEFAULT 0,
  total_overrun      NUMERIC(10,2) DEFAULT 0,
  non_standard_pct   NUMERIC(10,2) DEFAULT 0,
  extra_action_count INTEGER       DEFAULT 0,
  overrun_index      NUMERIC(10,2) DEFAULT 0,
  UNIQUE(report_id, employee)
);

CREATE INDEX IF NOT EXISTS idx_empstats_report_id ON employee_stats(report_id);
CREATE INDEX IF NOT EXISTS idx_empstats_employee  ON employee_stats(employee);

-- 7. Настройки действий: какие действия "базовые" (входят в стоимость по умолчанию),
--    какие "дополнительные" (накручивают стоимость обращения). Wildcard '*' на department/device_type.
CREATE TABLE IF NOT EXISTS action_settings (
  id           SERIAL PRIMARY KEY,
  department   TEXT NOT NULL DEFAULT '*',
  device_type  TEXT NOT NULL DEFAULT '*',
  action_name  TEXT NOT NULL,
  is_base      BOOLEAN NOT NULL DEFAULT false,
  base_cost    NUMERIC(10,2),
  updated_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(department, device_type, action_name)
);

-- индекс под LATERAL-джойн в recompute_services_for_report (action_name = ... AND department/device_type)
CREATE INDEX IF NOT EXISTS idx_action_settings_lookup ON action_settings(action_name);

-- 8. Ручное переопределение отдела сотрудника (если не совпадает с тем, что в отчёте)
CREATE TABLE IF NOT EXISTS employee_departments (
  employee     TEXT PRIMARY KEY,
  department   TEXT NOT NULL,
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- Представления (Views)
-- ============================================================

DROP VIEW IF EXISTS v_weekly_summary CASCADE;
DROP VIEW IF EXISTS v_savings CASCADE;
DROP VIEW IF EXISTS v_overrun_reasons CASCADE;

CREATE OR REPLACE VIEW v_weekly_summary AS
SELECT
  u.id                                                          AS report_id,
  u.report_week,
  u.filename,
  u.row_count,
  COUNT(DISTINCT s.service_id)                                  AS total_services,
  COALESCE(SUM(s.total_price), 0)                               AS total_payments,
  COALESCE(AVG(s.total_price), 0)                               AS avg_service_cost,
  COUNT(DISTINCT CASE WHEN s.zone <> 'normal' THEN s.id END)    AS non_standard_count,
  COALESCE(SUM(CASE WHEN s.overrun > 0 THEN s.overrun END), 0)  AS total_overrun
FROM uploads u
LEFT JOIN services s ON s.report_id = u.id
GROUP BY u.id, u.report_week, u.filename, u.row_count
ORDER BY u.report_week DESC;

CREATE OR REPLACE VIEW v_savings AS
SELECT
  u.id AS report_id,
  u.report_week,
  SUM(s.total_price)                                  AS actual_payments,
  SUM(CASE WHEN s.base_cost > 0 THEN s.base_cost ELSE 0 END) AS base_total,
  SUM(GREATEST(s.overrun, 0))                         AS total_overrun_amount
FROM uploads u
JOIN services s ON s.report_id = u.id
GROUP BY u.id, u.report_week
ORDER BY u.report_week;

CREATE OR REPLACE VIEW v_overrun_reasons AS
SELECT
  s.report_id,
  unnest(s.extra_actions) AS reason,
  COUNT(*)                AS cases_count,
  SUM(s.overrun)           AS total_overrun,
  ROUND(SUM(s.overrun) /
    NULLIF(SUM(SUM(s.overrun)) OVER (PARTITION BY s.report_id), 0) * 100, 2) AS pct_of_total
FROM services s
WHERE s.overrun > 0 AND array_length(s.extra_actions, 1) > 0
GROUP BY s.report_id, reason
ORDER BY s.report_id, total_overrun DESC;

-- ============================================================
-- RLS — анонимный фронт работает только через RPC (SECURITY DEFINER)
-- кроме action_settings/employee_departments, где разрешён прямой CRUD
-- (как и сейчас, инструмент внутренний, без авторизации).
-- ============================================================

ALTER TABLE uploads           ENABLE ROW LEVEL SECURITY;
ALTER TABLE actions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE services            ENABLE ROW LEVEL SECURITY;
ALTER TABLE anomalies           ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_insights     ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_stats      ENABLE ROW LEVEL SECURITY;
ALTER TABLE action_settings     ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_departments ENABLE ROW LEVEL SECURITY;

-- Таблицы с данными отчётов: только чтение анонимам напрямую (для отладки),
-- запись — только через RPC (SECURITY DEFINER обходит RLS своего владельца).
DROP POLICY IF EXISTS anon_select ON uploads;
CREATE POLICY anon_select ON uploads FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON actions;
CREATE POLICY anon_select ON actions FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON services;
CREATE POLICY anon_select ON services FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON anomalies;
CREATE POLICY anon_select ON anomalies FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON weekly_insights;
CREATE POLICY anon_select ON weekly_insights FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON employee_stats;
CREATE POLICY anon_select ON employee_stats FOR SELECT TO anon USING (true);

-- action_settings / employee_departments: полный CRUD анонимам (внутренний инструмент)
DROP POLICY IF EXISTS anon_all ON action_settings;
CREATE POLICY anon_all ON action_settings FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS anon_all ON employee_departments;
CREATE POLICY anon_all ON employee_departments FOR ALL TO anon USING (true) WITH CHECK (true);

GRANT SELECT ON uploads, actions, services, anomalies, weekly_insights, employee_stats TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON action_settings, employee_departments TO anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon;
