-- ============================================================
-- Аналитика сервисного центра Apple / Яндекс
-- PostgreSQL Schema
-- ============================================================

-- 1. Загрузки — еженедельные отчёты
CREATE TABLE IF NOT EXISTS uploads (
  id           SERIAL PRIMARY KEY,
  upload_date  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  report_week  DATE        NOT NULL,
  filename     VARCHAR(500) NOT NULL,
  row_count    INTEGER      DEFAULT 0,
  UNIQUE(report_week)
);

-- 2. Действия — все строки из Excel
CREATE TABLE IF NOT EXISTS actions (
  id           BIGINT       NOT NULL,
  report_id    INTEGER      NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  employee     VARCHAR(255),
  action_date  DATE,
  office       VARCHAR(100),
  department   VARCHAR(100),
  action_type  VARCHAR(255),
  group_name   VARCHAR(500),
  subgroup     VARCHAR(500),
  comment      TEXT,
  price        NUMERIC(10,2) DEFAULT 0,
  service_id   BIGINT,
  vendor       VARCHAR(100),
  PRIMARY KEY (id, report_id)
);

CREATE INDEX IF NOT EXISTS idx_actions_service_id  ON actions(service_id);
CREATE INDEX IF NOT EXISTS idx_actions_report_id   ON actions(report_id);
CREATE INDEX IF NOT EXISTS idx_actions_employee    ON actions(employee);
CREATE INDEX IF NOT EXISTS idx_actions_vendor      ON actions(vendor);
CREATE INDEX IF NOT EXISTS idx_actions_action_type ON actions(action_type);

-- 3. Обращения — агрегированные данные по id сервис
CREATE TABLE IF NOT EXISTS services (
  id             SERIAL PRIMARY KEY,
  service_id     BIGINT        NOT NULL,
  report_id      INTEGER       NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  vendor         VARCHAR(100),
  group_name     VARCHAR(255),
  total_price    NUMERIC(10,2) DEFAULT 0,
  actions_count  INTEGER       DEFAULT 0,
  employee_count INTEGER       DEFAULT 0,
  employees      TEXT[]        DEFAULT '{}',
  action_types   TEXT[]        DEFAULT '{}',
  extra_actions  TEXT[]        DEFAULT '{}',
  base_cost      NUMERIC(10,2) DEFAULT 0,
  overrun        NUMERIC(10,2) DEFAULT 0,
  overrun_pct    NUMERIC(10,2) DEFAULT 0,
  overrun_reason TEXT,
  zone           VARCHAR(20)   DEFAULT 'normal',  -- normal | yellow | red
  UNIQUE(service_id, report_id)
);

CREATE INDEX IF NOT EXISTS idx_services_report_id ON services(report_id);
CREATE INDEX IF NOT EXISTS idx_services_vendor    ON services(vendor);
CREATE INDEX IF NOT EXISTS idx_services_zone      ON services(zone);
CREATE INDEX IF NOT EXISTS idx_services_overrun   ON services(overrun DESC);

-- 4. Базовая стоимость — самообучающаяся модель
CREATE TABLE IF NOT EXISTS base_costs (
  id               SERIAL PRIMARY KEY,
  vendor           VARCHAR(100)  NOT NULL,
  group_name       VARCHAR(255)  NOT NULL,
  base_combo       TEXT[]        DEFAULT '{}',   -- типичный набор действий
  combo_frequency  INTEGER       DEFAULT 0,
  median_cost      NUMERIC(10,2) DEFAULT 0,
  avg_cost         NUMERIC(10,2) DEFAULT 0,
  min_typical_cost NUMERIC(10,2) DEFAULT 0,
  sample_count     INTEGER       DEFAULT 0,
  last_updated     TIMESTAMPTZ   DEFAULT NOW(),
  UNIQUE(vendor, group_name)
);

-- 5. История изменений базовой стоимости
CREATE TABLE IF NOT EXISTS base_cost_history (
  id            SERIAL PRIMARY KEY,
  vendor        VARCHAR(100),
  group_name    VARCHAR(255),
  old_combo     TEXT[],
  new_combo     TEXT[],
  old_cost      NUMERIC(10,2),
  new_cost      NUMERIC(10,2),
  change_reason TEXT,
  changed_at    TIMESTAMPTZ DEFAULT NOW(),
  report_id     INTEGER REFERENCES uploads(id)
);

-- 6. Аномалии
CREATE TABLE IF NOT EXISTS anomalies (
  id            SERIAL PRIMARY KEY,
  report_id     INTEGER      NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
  anomaly_type  VARCHAR(50),   -- employee | service
  entity_id     VARCHAR(500),  -- имя сотрудника или service_id
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

-- 7. Инсайты по неделям
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

-- 8. Статистика сотрудников по отчётам
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
  UNIQUE(report_id, employee)
);

CREATE INDEX IF NOT EXISTS idx_empstats_report_id ON employee_stats(report_id);
CREATE INDEX IF NOT EXISTS idx_empstats_employee  ON employee_stats(employee);

-- ============================================================
-- Представления (Views)
-- ============================================================

-- Сводка по неделям
CREATE OR REPLACE VIEW v_weekly_summary AS
SELECT
  u.id                                                          AS report_id,
  u.report_week,
  u.filename,
  u.row_count,
  COUNT(DISTINCT s.service_id)                                  AS total_services,
  COALESCE(SUM(s.total_price), 0)                               AS total_payments,
  COALESCE(AVG(s.total_price), 0)                               AS avg_service_cost,
  COUNT(DISTINCT CASE WHEN s.zone <> 'normal' THEN s.id END)   AS non_standard_count,
  COALESCE(SUM(CASE WHEN s.overrun > 0 THEN s.overrun END), 0) AS total_overrun,
  COALESCE(SUM(COALESCE(bc.median_cost, 0)), 0)                AS expected_payments
FROM uploads u
LEFT JOIN services s  ON s.report_id = u.id
LEFT JOIN base_costs bc ON bc.vendor = s.vendor AND bc.group_name = s.group_name
GROUP BY u.id, u.report_week, u.filename, u.row_count
ORDER BY u.report_week DESC;

-- Потенциальная экономия
CREATE OR REPLACE VIEW v_savings AS
SELECT
  u.id          AS report_id,
  u.report_week,
  SUM(s.total_price)             AS actual_payments,
  SUM(COALESCE(bc.median_cost, s.total_price)) AS expected_payments,
  SUM(s.total_price) - SUM(COALESCE(bc.median_cost, s.total_price)) AS potential_savings
FROM uploads u
JOIN services s  ON s.report_id = u.id
LEFT JOIN base_costs bc ON bc.vendor = s.vendor AND bc.group_name = s.group_name
GROUP BY u.id, u.report_week
ORDER BY u.report_week;

-- ТОП причин перерасходов
CREATE OR REPLACE VIEW v_overrun_reasons AS
SELECT
  s.report_id,
  unnest(s.extra_actions)           AS reason,
  COUNT(*)                          AS cases_count,
  SUM(s.overrun)                    AS total_overrun,
  ROUND(SUM(s.overrun) /
    NULLIF(SUM(SUM(s.overrun)) OVER (PARTITION BY s.report_id), 0) * 100, 2) AS pct_of_total
FROM services s
WHERE s.overrun > 0 AND array_length(s.extra_actions, 1) > 0
GROUP BY s.report_id, reason
ORDER BY s.report_id, total_overrun DESC;

-- ============================================================
-- Полезные SQL-запросы для аналитики
-- (сохранены как комментарии для справки)
-- ============================================================

/*
-- Обзор за неделю
SELECT * FROM v_weekly_summary WHERE report_id = $1;

-- Динамика по всем неделям
SELECT report_week, total_services, total_payments, avg_service_cost, total_overrun
FROM v_weekly_summary ORDER BY report_week;

-- Перерасходы по обращениям
SELECT s.service_id, s.vendor, s.group_name, s.total_price,
       s.base_cost, s.overrun, s.overrun_pct, s.zone, s.overrun_reason,
       ARRAY_TO_STRING(s.extra_actions, ', ') AS extra,
       ARRAY_TO_STRING(s.employees, ', ')     AS who
FROM services s
WHERE s.report_id = $1 AND s.overrun > 0
ORDER BY s.overrun DESC;

-- ТОП причин перерасходов
SELECT * FROM v_overrun_reasons WHERE report_id = $1;

-- Сотрудники
SELECT es.*,
       ROUND(es.avg_service_cost / NULLIF(AVG(es.avg_service_cost) OVER (), 0) * 100 - 100, 2) AS vs_dept_avg_pct
FROM employee_stats es
WHERE es.report_id = $1
ORDER BY es.total_overrun DESC;

-- Вендоры
SELECT vendor,
       COUNT(DISTINCT service_id)  AS services,
       SUM(total_price)            AS payments,
       AVG(total_price)            AS avg_cost,
       SUM(overrun)                AS overrun
FROM services WHERE report_id = $1
GROUP BY vendor;

-- Потенциальная экономия
SELECT * FROM v_savings;
*/
