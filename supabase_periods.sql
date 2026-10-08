-- ============================================================
-- XFIX Analytics — произвольные периоды (неделя / месяц / квартал / диапазон)
-- Прогнать ПОСЛЕ supabase_schema.sql и supabase_functions.sql.
--
-- Зачем: весь дашборд был завязан на один report_id (снимок недели).
-- Здесь вводится «период» — набор report_id, для которого обращения
-- пересчитываются заново, группировкой по service_id БЕЗ разбивки по неделям.
-- Обращение, растянутое на две недели, считается один раз: base_cost
-- не задваивается, overrun_pct и зоны корректны.
--
-- Результат кэшируется в period_services / period_employee_stats.
-- Сборка разбита на чанки, т.к. платформа режет statement_timeout на 3s.
-- ============================================================

-- ------------------------------------------------------------
-- Хранилище периодов
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS periods (
  period_key     TEXT PRIMARY KEY,      -- 'p' || md5 от отсортированного списка report_id
  report_ids     INT[]       NOT NULL,
  date_from      DATE,
  date_to        DATE,
  buckets        INT         NOT NULL DEFAULT 1,
  built_at       TIMESTAMPTZ,           -- NULL = не собран / собирается
  settings_stamp TIMESTAMPTZ,           -- max(action_settings.updated_at) на момент сборки
  data_stamp     TIMESTAMPTZ,           -- max(uploads.upload_date) по входящим отчётам
  svc_min        BIGINT,                -- границы service_id: чанк = диапазон,
  svc_max        BIGINT,                -- чтобы читать по индексу, а не сканом
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE periods ADD COLUMN IF NOT EXISTS svc_min BIGINT;
ALTER TABLE periods ADD COLUMN IF NOT EXISTS svc_max BIGINT;

-- Снимок обращений за период (аналог services, но ключ — период, а не отчёт)
CREATE TABLE IF NOT EXISTS period_services (
  period_key     TEXT          NOT NULL REFERENCES periods(period_key) ON DELETE CASCADE,
  service_id     BIGINT        NOT NULL,
  vendor         VARCHAR(100),
  group_name     VARCHAR(255),
  total_price    NUMERIC(12,2) DEFAULT 0,
  actions_count  INTEGER       DEFAULT 0,
  employee_count INTEGER       DEFAULT 0,
  employees      TEXT[]        DEFAULT '{}',
  action_types   TEXT[]        DEFAULT '{}',
  extra_actions  TEXT[]        DEFAULT '{}',
  base_cost      NUMERIC(12,2) DEFAULT 0,
  overrun        NUMERIC(12,2) DEFAULT 0,
  overrun_pct    NUMERIC(12,2) DEFAULT 0,
  overrun_reason TEXT,
  zone           VARCHAR(20)   DEFAULT 'normal',
  PRIMARY KEY (period_key, service_id)
);

-- чанк читает actions по (report_id, service_id) — без этого индекса скан всей недели
CREATE INDEX IF NOT EXISTS idx_actions_report_service ON actions(report_id, service_id);

CREATE INDEX IF NOT EXISTS idx_period_services_zone    ON period_services(period_key, zone);
CREATE INDEX IF NOT EXISTS idx_period_services_overrun ON period_services(period_key, overrun DESC);

-- Снимок сотрудников за период (аналог employee_stats)
CREATE TABLE IF NOT EXISTS period_employee_stats (
  period_key         TEXT          NOT NULL REFERENCES periods(period_key) ON DELETE CASCADE,
  employee           VARCHAR(255)  NOT NULL,
  department         VARCHAR(100),
  services_count     INTEGER       DEFAULT 0,
  total_earnings     NUMERIC(12,2) DEFAULT 0,
  avg_service_cost   NUMERIC(12,2) DEFAULT 0,
  non_standard_count INTEGER       DEFAULT 0,
  total_overrun      NUMERIC(12,2) DEFAULT 0,
  non_standard_pct   NUMERIC(12,2) DEFAULT 0,
  extra_action_count INTEGER       DEFAULT 0,
  overrun_index      NUMERIC(12,2) DEFAULT 0,
  PRIMARY KEY (period_key, employee)
);

ALTER TABLE periods               ENABLE ROW LEVEL SECURITY;
ALTER TABLE period_services       ENABLE ROW LEVEL SECURITY;
ALTER TABLE period_employee_stats ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_select ON periods;
CREATE POLICY anon_select ON periods FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON period_services;
CREATE POLICY anon_select ON period_services FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS anon_select ON period_employee_stats;
CREATE POLICY anon_select ON period_employee_stats FOR SELECT TO anon USING (true);

GRANT SELECT ON periods, period_services, period_employee_stats TO anon;

-- ------------------------------------------------------------
-- Ключ периода и проверка актуальности кэша
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION period_key_of(p_report_ids INT[])
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT 'p' || md5(array_to_string(ARRAY(SELECT DISTINCT unnest(p_report_ids) ORDER BY 1), ','));
$$;

-- Открыть период: создаёт запись, отвечает нужна ли сборка и сколько чанков.
-- Кэш считается протухшим, если после сборки менялись action_settings
-- (пересчёт базы/перерасхода) или перезаливался любой из входящих отчётов.
CREATE OR REPLACE FUNCTION period_begin(p_report_ids INT[])
RETURNS TABLE(period_key TEXT, needs_build BOOLEAN, buckets INT, report_count INT, date_from TEXT, date_to TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
-- имена выходных колонок совпадают с колонками periods; внутри тела нам нужны
-- всегда колонки таблицы, значения отдаём через локальные v_-переменные
#variable_conflict use_column
DECLARE
  v_key      TEXT;
  v_ids      INT[];
  v_rows     BIGINT;
  v_buckets  INT;
  v_from     DATE;
  v_to       DATE;
  v_settings TIMESTAMPTZ;
  v_data     TIMESTAMPTZ;
  v_stale    BOOLEAN;
  v_svc_min  BIGINT;
  v_svc_max  BIGINT;
BEGIN
  v_ids := ARRAY(SELECT DISTINCT unnest(p_report_ids) ORDER BY 1);
  IF array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Пустой список отчётов для периода';
  END IF;

  v_key := period_key_of(v_ids);

  SELECT MIN(u.report_week), MAX(u.report_week + 6), MAX(u.upload_date)
    INTO v_from, v_to, v_data
  FROM uploads u WHERE u.id = ANY(v_ids);

  SELECT COALESCE(MAX(a.updated_at), 'epoch'::timestamptz) INTO v_settings FROM action_settings a;

  -- statement_timeout = 3s, поэтому чанк держим мелким (~5k строк действий).
  -- Если и этого мало, клиент дробит дальше через параметр p_buckets.
  SELECT COUNT(*), MIN(service_id), MAX(service_id)
    INTO v_rows, v_svc_min, v_svc_max
  FROM actions WHERE report_id = ANY(v_ids) AND service_id IS NOT NULL;
  v_buckets := GREATEST(1, LEAST(1024, CEIL(v_rows / 5000.0)::int));

  SELECT (p.built_at IS NULL
          OR p.settings_stamp IS DISTINCT FROM v_settings
          OR p.data_stamp IS DISTINCT FROM v_data
          OR p.buckets <> v_buckets)
    INTO v_stale
  FROM periods p WHERE p.period_key = v_key;

  IF v_stale IS NULL THEN                       -- периода ещё нет
    INSERT INTO periods(period_key, report_ids, date_from, date_to, buckets, svc_min, svc_max)
    VALUES (v_key, v_ids, v_from, v_to, v_buckets, v_svc_min, v_svc_max)
    ON CONFLICT (period_key) DO NOTHING;
    v_stale := true;
  END IF;

  IF v_stale THEN
    UPDATE periods SET report_ids = v_ids, date_from = v_from, date_to = v_to,
                       buckets = v_buckets, svc_min = v_svc_min, svc_max = v_svc_max,
                       built_at = NULL
    WHERE periods.period_key = v_key;
    DELETE FROM period_services       WHERE period_services.period_key = v_key;
    DELETE FROM period_employee_stats WHERE period_employee_stats.period_key = v_key;
  END IF;

  RETURN QUERY SELECT v_key, v_stale, v_buckets, array_length(v_ids, 1), v_from::text, v_to::text;
END;
$$;

-- ------------------------------------------------------------
-- Сборка обращений периода — один чанк (та же логика, что
-- recompute_services_for_report, но группировка только по service_id)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION period_build_services(p_period TEXT, p_bucket INT, p_buckets INT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ids     INT[];
  v_buckets INT;
  v_min     BIGINT;
  v_max     BIGINT;
  v_step    BIGINT;
  v_lo      BIGINT;
  v_hi      BIGINT;
BEGIN
  SELECT report_ids, COALESCE(p_buckets, buckets), svc_min, svc_max
    INTO v_ids, v_buckets, v_min, v_max
  FROM periods WHERE period_key = p_period;
  IF v_ids IS NULL THEN RAISE EXCEPTION 'Неизвестный период %', p_period; END IF;
  IF v_min IS NULL THEN RETURN; END IF;                    -- в периоде нет обращений

  -- чанк — диапазон service_id: ложится на индекс actions(report_id, service_id)
  v_step := GREATEST(1, CEIL((v_max - v_min + 1)::numeric / v_buckets)::bigint);
  v_lo   := v_min + p_bucket::bigint * v_step;
  v_hi   := CASE WHEN p_bucket = v_buckets - 1 THEN v_max + 1 ELSE v_lo + v_step END;
  IF v_lo > v_max THEN RETURN; END IF;

  WITH scope AS (
    SELECT * FROM actions
    WHERE report_id = ANY(v_ids)
      AND service_id >= v_lo AND service_id < v_hi
  ),
  svc_agg AS (
    SELECT service_id,
      MAX(vendor) AS vendor,
      MAX(group_name) AS group_name,
      SUM(price) AS total_price,
      COUNT(*) AS actions_count,
      COUNT(DISTINCT employee) AS employee_count,
      ARRAY_AGG(DISTINCT employee) FILTER (WHERE employee IS NOT NULL) AS employees,
      ARRAY_AGG(DISTINCT action_type) FILTER (WHERE action_type IS NOT NULL) AS action_types
    FROM scope
    GROUP BY service_id
  ),
  spd AS (
    SELECT DISTINCT ON (a.service_id)
      a.service_id,
      COALESCE(ed.department, a.department) AS department
    FROM scope a
    LEFT JOIN employee_departments ed ON ed.employee = a.employee
    WHERE a.employee IS NOT NULL
    ORDER BY a.service_id, a.action_date DESC NULLS LAST
  ),
  ssg AS (
    SELECT DISTINCT ON (a.service_id, a.action_type)
      a.service_id, a.action_type, a.subgroup, a.group_name
    FROM scope a
    WHERE a.action_type IS NOT NULL
    ORDER BY a.service_id, a.action_type, a.action_date DESC NULLS LAST
  ),
  sac AS (
    SELECT sal.service_id, sal.action_type,
      cfg.is_base, COALESCE(cfg.base_cost, 0) AS cfg_base_cost
    FROM (
      SELECT DISTINCT service_id, action_type FROM scope WHERE action_type IS NOT NULL
    ) sal
    JOIN svc_agg sv ON sv.service_id = sal.service_id
    LEFT JOIN spd ON spd.service_id = sal.service_id
    LEFT JOIN ssg ON ssg.service_id = sal.service_id AND ssg.action_type = sal.action_type
    LEFT JOIN LATERAL (
      SELECT is_base, base_cost FROM action_settings
      WHERE action_name = sal.action_type
        AND (department = '*' OR department = spd.department)
        AND (device_type = '*' OR device_type = COALESCE(ssg.group_name, sv.group_name))
        AND (subgroup = '*' OR subgroup = ssg.subgroup)
      ORDER BY (department = spd.department)::int DESC,
               (device_type = COALESCE(ssg.group_name, sv.group_name))::int DESC,
               (subgroup = ssg.subgroup)::int DESC
      LIMIT 1
    ) cfg ON true
  ),
  sap AS (
    SELECT service_id, action_type, SUM(price) AS actual_price
    FROM scope WHERE action_type IS NOT NULL
    GROUP BY service_id, action_type
  ),
  enriched AS (
    SELECT sac.*,
      bool_or(sac.is_base IS NOT NULL) OVER (PARTITION BY sac.service_id) AS dept_has_cfg,
      COALESCE(sap.actual_price, 0) AS actual_price
    FROM sac LEFT JOIN sap ON sap.service_id = sac.service_id AND sap.action_type = sac.action_type
  ),
  svc_cost AS (
    SELECT service_id,
      COALESCE(SUM(CASE WHEN is_base = true THEN cfg_base_cost ELSE 0 END), 0) AS base_cost,
      COALESCE(SUM(CASE WHEN dept_has_cfg AND is_base IS NOT TRUE THEN actual_price ELSE 0 END), 0) AS extra_cost,
      ARRAY_AGG(DISTINCT action_type) FILTER (WHERE dept_has_cfg AND is_base IS NOT TRUE) AS extra_actions
    FROM enriched
    GROUP BY service_id
  )
  INSERT INTO period_services(period_key, service_id, vendor, group_name, total_price, actions_count,
    employee_count, employees, action_types, base_cost, overrun, overrun_pct, zone, overrun_reason, extra_actions)
  SELECT p_period, sa.service_id, sa.vendor, sa.group_name, sa.total_price, sa.actions_count,
    sa.employee_count, sa.employees, sa.action_types,
    sc.base_cost,
    sc.extra_cost,
    CASE WHEN sc.base_cost > 0 THEN ROUND(sc.extra_cost / sc.base_cost * 100, 2) ELSE 0 END,
    CASE
      WHEN sc.base_cost = 0 THEN 'normal'
      WHEN sc.extra_cost = 0 THEN 'normal'
      WHEN sc.extra_cost / sc.base_cost <= 0.30 THEN 'small'
      WHEN sc.extra_cost / sc.base_cost <= 1.00 THEN 'elevated'
      ELSE 'critical'
    END,
    NULLIF(ARRAY_TO_STRING(COALESCE(sc.extra_actions, ARRAY[]::text[]), ' + '), ''),
    COALESCE(sc.extra_actions, ARRAY[]::text[])
  FROM svc_agg sa JOIN svc_cost sc ON sc.service_id = sa.service_id
  ON CONFLICT (period_key, service_id) DO UPDATE SET
    vendor=EXCLUDED.vendor, group_name=EXCLUDED.group_name, total_price=EXCLUDED.total_price,
    actions_count=EXCLUDED.actions_count, employee_count=EXCLUDED.employee_count,
    employees=EXCLUDED.employees, action_types=EXCLUDED.action_types,
    base_cost=EXCLUDED.base_cost, overrun=EXCLUDED.overrun, overrun_pct=EXCLUDED.overrun_pct,
    zone=EXCLUDED.zone, overrun_reason=EXCLUDED.overrun_reason, extra_actions=EXCLUDED.extra_actions;
END;
$$;

-- ------------------------------------------------------------
-- Сборка статистики сотрудников за период + отметка готовности
-- ------------------------------------------------------------
-- Чанкуется по сотруднику: все строки сотрудника попадают в один бакет,
-- поэтому агрегат каждого чанка полный и независимый.
CREATE OR REPLACE FUNCTION period_build_stats(p_period TEXT, p_bucket INT DEFAULT NULL, p_buckets INT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ids     INT[];
  v_buckets INT;
BEGIN
  SELECT report_ids, COALESCE(p_buckets, buckets) INTO v_ids, v_buckets FROM periods WHERE period_key = p_period;
  IF v_ids IS NULL THEN RAISE EXCEPTION 'Неизвестный период %', p_period; END IF;

  IF p_bucket IS NULL THEN
    DELETE FROM period_employee_stats WHERE period_key = p_period;
  ELSE
    DELETE FROM period_employee_stats
    WHERE period_key = p_period AND ABS(hashtext(employee) % v_buckets) = p_bucket;
  END IF;

  INSERT INTO period_employee_stats(period_key, employee, department, services_count, total_earnings,
    avg_service_cost, non_standard_count, total_overrun, non_standard_pct, extra_action_count, overrun_index)
  SELECT p_period, a.employee,
    COALESCE((SELECT department FROM employee_departments WHERE employee = a.employee), MAX(a.department)),
    COUNT(DISTINCT a.service_id),
    SUM(a.price),
    COALESCE(AVG(s.total_price), 0),
    COUNT(DISTINCT CASE WHEN s.zone <> 'normal' THEN a.service_id END),
    COALESCE(SUM(CASE WHEN s.overrun > 0 THEN s.overrun ELSE 0 END), 0),
    ROUND(COUNT(DISTINCT CASE WHEN s.zone <> 'normal' THEN a.service_id END) * 100.0 / NULLIF(COUNT(DISTINCT a.service_id), 0), 2),
    COUNT(CASE WHEN a.action_type IS NOT NULL AND s.extra_actions IS NOT NULL AND a.action_type = ANY(s.extra_actions) THEN 1 END),
    ROUND(COALESCE(SUM(CASE WHEN s.overrun > 0 THEN s.overrun ELSE 0 END), 0) / NULLIF(COUNT(DISTINCT a.service_id), 0), 2)
  FROM actions a
  LEFT JOIN period_services s ON s.period_key = p_period AND s.service_id = a.service_id
  WHERE a.report_id = ANY(v_ids) AND a.employee IS NOT NULL
    AND (p_bucket IS NULL OR ABS(hashtext(a.employee) % v_buckets) = p_bucket)
  GROUP BY a.employee;
END;
$$;

CREATE OR REPLACE FUNCTION period_finish(p_period TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE periods SET
    built_at       = NOW(),
    settings_stamp = (SELECT COALESCE(MAX(updated_at), 'epoch'::timestamptz) FROM action_settings),
    data_stamp     = (SELECT MAX(u.upload_date) FROM uploads u WHERE u.id = ANY(periods.report_ids))
  WHERE period_key = p_period;
END;
$$;

-- ------------------------------------------------------------
-- ЧТЕНИЕ по периоду: те же наборы колонок, что у недельных функций,
-- чтобы фронт мог подменять вызов без изменения рендера.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_overview_p(p_period TEXT, p_prev_period TEXT DEFAULT NULL)
RETURNS TABLE(
  report_id INT, report_week TEXT, total_services BIGINT, total_payments NUMERIC,
  avg_service_cost NUMERIC, non_standard_count BIGINT, total_overrun NUMERIC,
  prev_services BIGINT, prev_payments NUMERIC, prev_avg NUMERIC, prev_nonstandard BIGINT, prev_overrun NUMERIC,
  zone_normal BIGINT, zone_small BIGINT, zone_elevated BIGINT, zone_critical BIGINT,
  zone_yellow BIGINT, zone_red BIGINT, potential_savings NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH agg AS (
    SELECT
      COUNT(*)::bigint                                            AS total_services,
      COALESCE(SUM(total_price), 0)                               AS total_payments,
      COALESCE(AVG(total_price), 0)                               AS avg_service_cost,
      COUNT(*) FILTER (WHERE zone <> 'normal')::bigint            AS non_standard_count,
      COALESCE(SUM(overrun) FILTER (WHERE overrun > 0), 0)        AS total_overrun,
      COUNT(*) FILTER (WHERE zone = 'normal')::bigint             AS zone_normal,
      COUNT(*) FILTER (WHERE zone = 'small')::bigint              AS zone_small,
      COUNT(*) FILTER (WHERE zone = 'elevated')::bigint           AS zone_elevated,
      COUNT(*) FILTER (WHERE zone = 'critical')::bigint           AS zone_critical,
      COALESCE(SUM(base_cost) FILTER (WHERE base_cost > 0), 0)    AS base_total
    FROM period_services WHERE period_key = p_period
  ),
  prev AS (
    SELECT
      COUNT(*)::bigint                                     AS total_services,
      COALESCE(SUM(total_price), 0)                        AS total_payments,
      COALESCE(AVG(total_price), 0)                        AS avg_service_cost,
      COUNT(*) FILTER (WHERE zone <> 'normal')::bigint     AS non_standard_count,
      COALESCE(SUM(overrun) FILTER (WHERE overrun > 0), 0) AS total_overrun
    FROM period_services WHERE p_prev_period IS NOT NULL AND period_key = p_prev_period
  )
  SELECT NULL::int,
    (SELECT date_from::text FROM periods WHERE period_key = p_period),
    agg.total_services, agg.total_payments, agg.avg_service_cost, agg.non_standard_count, agg.total_overrun,
    NULLIF(prev.total_services, 0), NULLIF(prev.total_payments, 0), NULLIF(prev.avg_service_cost, 0),
    NULLIF(prev.non_standard_count, 0), NULLIF(prev.total_overrun, 0),
    agg.zone_normal, agg.zone_small, agg.zone_elevated, agg.zone_critical,
    agg.zone_small + agg.zone_elevated, agg.zone_critical,
    agg.base_total
  FROM agg, prev;
$$;

-- Инсайты периода: считаются на лету «период к предыдущему периоду»
CREATE OR REPLACE FUNCTION get_insights_p(p_period TEXT, p_prev_period TEXT DEFAULT NULL)
RETURNS TABLE(insight_type TEXT, message TEXT, change_pct NUMERIC, direction TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH o AS (SELECT * FROM get_overview_p(p_period, p_prev_period))
  SELECT t.insight_type, t.message, t.change_pct, t.direction FROM (
    SELECT 'services_count' AS insight_type,
      'Кол-во обращений изменилось на ' || ROUND((o.total_services - o.prev_services)::numeric * 100 / NULLIF(o.prev_services,0),1) || '%' AS message,
      ROUND((o.total_services - o.prev_services)::numeric * 100 / NULLIF(o.prev_services,0),1) AS change_pct,
      CASE WHEN o.total_services >= o.prev_services THEN 'up' ELSE 'down' END AS direction
    FROM o
    UNION ALL
    SELECT 'payments',
      'Выплаты изменились на ' || ROUND((o.total_payments - o.prev_payments) * 100 / NULLIF(o.prev_payments,0),1) || '%',
      ROUND((o.total_payments - o.prev_payments) * 100 / NULLIF(o.prev_payments,0),1),
      CASE WHEN o.total_payments >= o.prev_payments THEN 'up' ELSE 'down' END
    FROM o
    UNION ALL
    SELECT 'overrun',
      'Перерасход изменился на ' || ROUND((o.total_overrun - o.prev_overrun) * 100 / NULLIF(o.prev_overrun,0),1) || '%',
      ROUND((o.total_overrun - o.prev_overrun) * 100 / NULLIF(o.prev_overrun,0),1),
      CASE WHEN o.total_overrun >= o.prev_overrun THEN 'up' ELSE 'down' END
    FROM o
    UNION ALL
    SELECT 'avg_cost',
      'Средняя стоимость обращения изменилась на ' || ROUND((o.avg_service_cost - o.prev_avg) * 100 / NULLIF(o.prev_avg,0),1) || '%',
      ROUND((o.avg_service_cost - o.prev_avg) * 100 / NULLIF(o.prev_avg,0),1),
      CASE WHEN o.avg_service_cost >= o.prev_avg THEN 'up' ELSE 'down' END
    FROM o
  ) t
  WHERE t.change_pct IS NOT NULL AND ABS(t.change_pct) >= 5
  ORDER BY ABS(t.change_pct) DESC;
$$;

CREATE OR REPLACE FUNCTION get_vendors_p(p_period TEXT)
RETURNS TABLE(vendor TEXT, services BIGINT, payments NUMERIC, avg_cost NUMERIC, overrun NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT vendor, COUNT(*)::bigint, SUM(total_price), AVG(total_price), SUM(overrun)
  FROM period_services WHERE period_key = p_period GROUP BY vendor ORDER BY 3 DESC;
$$;

CREATE OR REPLACE FUNCTION get_overruns_p(p_period TEXT)
RETURNS TABLE(service_id BIGINT, vendor TEXT, group_name TEXT, total_price NUMERIC, base_cost NUMERIC,
              overrun NUMERIC, overrun_pct NUMERIC, zone TEXT, overrun_reason TEXT, employees TEXT[], extra_actions TEXT[])
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT service_id, vendor, group_name, total_price, base_cost, overrun, overrun_pct, zone, overrun_reason, employees, extra_actions
  FROM period_services WHERE period_key = p_period AND overrun > 0 ORDER BY overrun DESC;
$$;

CREATE OR REPLACE FUNCTION get_reasons_p(p_period TEXT)
RETURNS TABLE(reason TEXT, cases_count BIGINT, total_overrun NUMERIC, pct_of_total NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH r AS (
    SELECT unnest(extra_actions) AS reason, COUNT(*) AS cases_count, SUM(overrun) AS total_overrun
    FROM period_services
    WHERE period_key = p_period AND overrun > 0 AND array_length(extra_actions, 1) > 0
    GROUP BY 1
  )
  SELECT reason, cases_count, total_overrun,
    ROUND(total_overrun / NULLIF(SUM(total_overrun) OVER (), 0) * 100, 2)
  FROM r ORDER BY total_overrun DESC LIMIT 20;
$$;

CREATE OR REPLACE FUNCTION get_employees_p(p_period TEXT)
RETURNS TABLE(
  employee TEXT, department TEXT, services_count INT, total_earnings NUMERIC, extra_action_count INT,
  non_standard_pct NUMERIC, overrun_index NUMERIC, avg_actions_per_service NUMERIC,
  dept_median_actions NUMERIC, duplicate_action_count BIGINT, vs_median_pct NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH ids AS (SELECT report_ids FROM periods WHERE period_key = p_period),
  action_counts AS (
    SELECT employee, COUNT(*) AS total_actions
    FROM actions, ids WHERE report_id = ANY(ids.report_ids) AND employee IS NOT NULL
    GROUP BY employee
  ),
  dept_medians AS (
    SELECT COALESCE(es.department, 'All') AS dept,
      CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ac.total_actions::numeric / NULLIF(es.services_count, 0)) AS numeric) AS median_actions_per_svc
    FROM period_employee_stats es
    JOIN action_counts ac ON ac.employee = es.employee
    WHERE es.period_key = p_period
    GROUP BY COALESCE(es.department, 'All')
  ),
  dup_raw AS (
    SELECT a.employee, a.service_id, a.action_type, COUNT(*) AS cnt
    FROM actions a, ids
    WHERE a.report_id = ANY(ids.report_ids) AND a.action_type IS NOT NULL AND a.employee IS NOT NULL
    GROUP BY a.employee, a.service_id, a.action_type HAVING COUNT(*) > 1
  ),
  dup_counts AS (
    /* разобранные вручную случаи (duplicate_reviews) из счётчика исключены */
    SELECT d.employee, COUNT(*) AS duplicate_count
    FROM dup_raw d
    LEFT JOIN duplicate_reviews dr
      ON dr.employee = d.employee AND dr.service_id = d.service_id AND dr.action_type = d.action_type
    WHERE dr.employee IS NULL OR dr.reviewed_repeat_count < d.cnt
    GROUP BY d.employee
  ),
  overrun_idx AS (
    SELECT a.employee,
      ROUND(SUM(CASE WHEN s.overrun > 0 THEN s.overrun ELSE 0 END)::numeric / NULLIF(COUNT(DISTINCT s.service_id)::numeric, 0), 2) AS overrun_index
    FROM period_services s
    JOIN ids ON true
    JOIN actions a ON a.service_id = s.service_id AND a.report_id = ANY(ids.report_ids)
    WHERE s.period_key = p_period AND a.employee IS NOT NULL
    GROUP BY a.employee
  )
  SELECT
    es.employee, es.department, es.services_count, es.total_earnings, es.extra_action_count, es.non_standard_pct,
    COALESCE(oi.overrun_index, 0),
    ROUND(ac.total_actions::numeric / NULLIF(es.services_count, 0), 2),
    ROUND(dm.median_actions_per_svc, 2),
    COALESCE(dc.duplicate_count, 0),
    ROUND((ac.total_actions::numeric / NULLIF(es.services_count, 0) / NULLIF(dm.median_actions_per_svc, 0) - 1) * 100, 1)
  FROM period_employee_stats es
  JOIN action_counts ac ON ac.employee = es.employee
  JOIN dept_medians dm ON dm.dept = COALESCE(es.department, 'All')
  LEFT JOIN dup_counts dc ON dc.employee = es.employee
  LEFT JOIN overrun_idx oi ON oi.employee = es.employee
  WHERE es.period_key = p_period
  ORDER BY 10 DESC NULLS LAST, 11 DESC NULLS LAST;
$$;

DROP FUNCTION IF EXISTS get_employee_duplicates_p(TEXT, TEXT);
CREATE OR REPLACE FUNCTION get_employee_duplicates_p(
  p_period TEXT, p_employee TEXT DEFAULT NULL, p_include_reviewed BOOLEAN DEFAULT false
)
RETURNS TABLE(employee TEXT, service_id BIGINT, action_type TEXT, repeat_count BIGINT, first_date TEXT, last_date TEXT,
              total_price NUMERIC, unit_price NUMERIC, review_status TEXT, review_note TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH d AS (
    SELECT a.employee, a.service_id, a.action_type, COUNT(*) AS cnt,
           MIN(a.action_date::text) AS first_date, MAX(a.action_date::text) AS last_date,
           SUM(a.price) AS total_price, MIN(a.price) AS unit_price
    FROM actions a, periods p
    WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids)
      AND a.action_type IS NOT NULL AND a.employee IS NOT NULL
      AND (p_employee IS NULL OR a.employee = p_employee)
    GROUP BY a.employee, a.service_id, a.action_type
    HAVING COUNT(*) > 1
  )
  SELECT d.employee, d.service_id, d.action_type, d.cnt, d.first_date, d.last_date, d.total_price, d.unit_price,
         CASE WHEN dr.reviewed_repeat_count >= d.cnt THEN dr.status END,
         CASE WHEN dr.reviewed_repeat_count >= d.cnt THEN dr.note END
  FROM d
  LEFT JOIN duplicate_reviews dr
    ON dr.employee = d.employee AND dr.service_id = d.service_id AND dr.action_type = d.action_type
  WHERE p_include_reviewed OR dr.employee IS NULL OR dr.reviewed_repeat_count < d.cnt
  ORDER BY d.cnt DESC, d.total_price DESC
  LIMIT 100;
$$;

-- Аномалии за период — объединение недельных (детектор считается при импорте)
CREATE OR REPLACE FUNCTION get_anomalies_p(p_period TEXT)
RETURNS TABLE(anomaly_type TEXT, entity_id TEXT, message TEXT, severity TEXT, metric TEXT, value NUMERIC, avg_value NUMERIC, deviation_pct NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT an.anomaly_type, an.entity_id, an.message, an.severity, an.metric, an.value, an.avg_value, an.deviation_pct
  FROM anomalies an, periods p
  WHERE p.period_key = p_period AND an.report_id = ANY(p.report_ids)
    /* разобранные вручную дубли из ленты аномалий убираем */
    AND NOT (an.metric = 'duplicate_action' AND EXISTS (
      SELECT 1 FROM duplicate_reviews dr
      WHERE dr.service_id::text = an.entity_id
        AND dr.reviewed_repeat_count >= an.value
        AND an.message LIKE '%"' || dr.action_type || '"%'
    ))
  ORDER BY an.severity DESC, an.deviation_pct DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION get_workload_daily_p(p_period TEXT)
RETURNS TABLE(date TEXT, dow INT, label TEXT, services BIGINT, employees_active BIGINT, total_actions BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.action_date::text, EXTRACT(DOW FROM a.action_date)::int, TO_CHAR(a.action_date, 'DD.MM'),
    COUNT(DISTINCT a.service_id), COUNT(DISTINCT a.employee), COUNT(*)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids)
    AND a.action_date IS NOT NULL AND a.action_type = 'Обработано'
  GROUP BY a.action_date ORDER BY a.action_date;
$$;

CREATE OR REPLACE FUNCTION get_emp_throughput_p(p_period TEXT)
RETURNS TABLE(employee TEXT, days_worked BIGINT, total_services BIGINT, avg_per_day NUMERIC, max_per_day BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH daily AS (
    SELECT a.employee, a.action_date, COUNT(DISTINCT a.service_id) AS day_services
    FROM actions a, periods p
    WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids)
      AND a.employee IS NOT NULL AND a.action_date IS NOT NULL AND a.action_type = 'Обработано'
    GROUP BY a.employee, a.action_date
  )
  SELECT employee, COUNT(DISTINCT action_date), SUM(day_services),
    ROUND(SUM(day_services)::numeric / NULLIF(COUNT(DISTINCT action_date), 0), 1), MAX(day_services)
  FROM daily GROUP BY employee ORDER BY 4 DESC;
$$;

-- ------------------------------------------------------------
-- Отчёты по методике №1–6 за период
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS report_vendor_processed_p(TEXT);
CREATE OR REPLACE FUNCTION report_vendor_processed_p(p_period TEXT, p_employees TEXT[] DEFAULT NULL)
RETURNS TABLE(vendor TEXT, devices BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.vendor, COUNT(DISTINCT a.service_id)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids) AND a.action_type = 'Обработано'
    AND (p_employees IS NULL OR a.employee = ANY(p_employees))
  GROUP BY a.vendor ORDER BY 2 DESC;
$$;

CREATE OR REPLACE FUNCTION report_employee_devices_p(p_period TEXT)
RETURNS TABLE(employee TEXT, subgroup TEXT, vendor TEXT, devices BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.employee, a.subgroup, a.vendor, COUNT(DISTINCT a.service_id)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids)
    AND a.action_type = 'Обработано' AND a.employee IS NOT NULL
  GROUP BY a.employee, a.subgroup, a.vendor ORDER BY a.employee, 4 DESC;
$$;

CREATE OR REPLACE FUNCTION report_employee_actions_p(p_period TEXT)
RETURNS TABLE(employee TEXT, action_type TEXT, cnt BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.employee, a.action_type, COUNT(DISTINCT a.service_id)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids)
    AND a.employee IS NOT NULL AND a.action_type IS NOT NULL
  GROUP BY a.employee, a.action_type ORDER BY a.employee, 3 DESC;
$$;

CREATE OR REPLACE FUNCTION report_employee_payouts_p(p_period TEXT)
RETURNS TABLE(employee TEXT, action_type TEXT, total_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.employee, a.action_type, SUM(a.price)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids) AND a.employee IS NOT NULL
  GROUP BY a.employee, a.action_type ORDER BY a.employee, 3 DESC;
$$;

CREATE OR REPLACE FUNCTION report_vendor_payouts_p(p_period TEXT)
RETURNS TABLE(vendor TEXT, employee TEXT, action_type TEXT, devices BIGINT, total_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.vendor, a.employee, a.action_type, COUNT(DISTINCT a.service_id), SUM(a.price)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids) AND a.employee IS NOT NULL
  GROUP BY a.vendor, a.employee, a.action_type ORDER BY a.vendor, 5 DESC;
$$;

CREATE OR REPLACE FUNCTION report_unscheduled_work_p(p_period TEXT)
RETURNS TABLE(employee TEXT, devices BIGINT, total_price NUMERIC, avg_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.employee, COUNT(DISTINCT a.service_id), SUM(a.price), AVG(a.price)
  FROM actions a, periods p
  WHERE p.period_key = p_period AND a.report_id = ANY(p.report_ids)
    AND a.action_type = 'Ненормированная работа' AND a.employee IS NOT NULL
  GROUP BY a.employee ORDER BY 3 DESC;
$$;

-- ------------------------------------------------------------
-- KPI за период
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_employee_kpi_p(TEXT, TEXT);
CREATE OR REPLACE FUNCTION get_employee_kpi_p(p_period TEXT, p_employee TEXT)
RETURNS TABLE(
  devices BIGINT, actions_count BIGINT, extra_actions INT, total_earnings NUMERIC,
  avg_action_cost NUMERIC, avg_service_cost NUMERIC, avg_earnings_per_service NUMERIC,
  non_standard_pct NUMERIC, apple_services BIGINT, yandex_services BIGINT,
  active_days BIGINT, avg_daily_earnings NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    COUNT(DISTINCT a.service_id),
    COUNT(*),
    MAX(es.extra_action_count),
    SUM(a.price),
    ROUND(SUM(a.price) / NULLIF(COUNT(*),0), 2),
    ROUND(SUM(a.price) / NULLIF(COUNT(DISTINCT a.service_id),0), 2),
    ROUND(SUM(a.price) / NULLIF(COUNT(DISTINCT a.service_id),0), 2),
    MAX(es.non_standard_pct),
    COUNT(DISTINCT CASE WHEN a.vendor = 'Apple' THEN a.service_id END),
    COUNT(DISTINCT CASE WHEN a.vendor = 'Яндекс' THEN a.service_id END),
    COUNT(DISTINCT a.action_date),
    ROUND(SUM(a.price) / NULLIF(COUNT(DISTINCT a.action_date),0), 2)
  FROM actions a
  JOIN periods p ON p.period_key = p_period AND a.report_id = ANY(p.report_ids)
  LEFT JOIN period_employee_stats es ON es.period_key = p_period AND es.employee = a.employee
  WHERE a.employee = p_employee;
$$;

DROP FUNCTION IF EXISTS get_employee_kpi_all_p(TEXT);
CREATE OR REPLACE FUNCTION get_employee_kpi_all_p(p_period TEXT)
RETURNS TABLE(
  employee TEXT, devices BIGINT, actions_count BIGINT, extra_actions INT, total_earnings NUMERIC,
  avg_action_cost NUMERIC, avg_service_cost NUMERIC, non_standard_pct NUMERIC,
  apple_services BIGINT, yandex_services BIGINT,
  active_days BIGINT, avg_daily_earnings NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    a.employee,
    COUNT(DISTINCT a.service_id),
    COUNT(*),
    MAX(es.extra_action_count),
    SUM(a.price),
    ROUND(SUM(a.price) / NULLIF(COUNT(*),0), 2),
    ROUND(SUM(a.price) / NULLIF(COUNT(DISTINCT a.service_id),0), 2),
    MAX(es.non_standard_pct),
    COUNT(DISTINCT CASE WHEN a.vendor = 'Apple' THEN a.service_id END),
    COUNT(DISTINCT CASE WHEN a.vendor = 'Яндекс' THEN a.service_id END),
    COUNT(DISTINCT a.action_date),
    ROUND(SUM(a.price) / NULLIF(COUNT(DISTINCT a.action_date),0), 2)
  FROM actions a
  JOIN periods p ON p.period_key = p_period AND a.report_id = ANY(p.report_ids)
  LEFT JOIN period_employee_stats es ON es.period_key = p_period AND es.employee = a.employee
  WHERE a.employee IS NOT NULL
  GROUP BY a.employee
  ORDER BY SUM(a.price) DESC NULLS LAST;
$$;

-- Дни просадки за период (логика — employee_downtime_days_core в supabase_functions.sql)
DROP FUNCTION IF EXISTS get_employee_downtime_days_p(TEXT);
CREATE OR REPLACE FUNCTION get_employee_downtime_days_p(p_period TEXT)
RETURNS TABLE(
  employee TEXT, department TEXT, action_date DATE,
  day_earnings NUMERIC, avg_day_earnings NUMERIC,
  day_actions BIGINT, dept_norm_actions NUMERIC, efficiency NUMERIC,
  active_emps BIGINT, available_work BIGINT, supply_ratio NUMERIC, dept_output_ratio NUMERIC,
  avg_day_actions NUMERIC,
  first_time TIME, last_time TIME, work_minutes INT, avg_work_minutes NUMERIC,
  idle_minutes INT, idle_with_work_minutes INT, idle_no_work_minutes INT,
  longest_gap_minutes INT, gaps JSONB, scheduled BOOLEAN,
  shift_start TIME, shift_end TIME, planned_minutes INT, expected_earnings NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT d.* FROM periods p, employee_downtime_days_core(p.report_ids) d
  WHERE p.period_key = p_period;
$$;

CREATE OR REPLACE FUNCTION get_employee_kpi_detail_p(p_period TEXT, p_employee TEXT)
RETURNS TABLE(
  service_id BIGINT, action_date DATE, vendor TEXT, group_name TEXT,
  action_type TEXT, price NUMERIC, zone TEXT, is_extra BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.service_id, a.action_date, a.vendor, a.group_name, a.action_type, a.price,
    COALESCE(s.zone, 'normal'),
    (a.action_type = ANY(COALESCE(s.extra_actions, ARRAY[]::text[])))
  FROM actions a
  JOIN periods p ON p.period_key = p_period AND a.report_id = ANY(p.report_ids)
  LEFT JOIN period_services s ON s.period_key = p_period AND s.service_id = a.service_id
  WHERE a.employee = p_employee
  ORDER BY a.service_id, a.action_date;
$$;

CREATE OR REPLACE FUNCTION get_service_structure_p(p_period TEXT, p_service_id BIGINT)
RETURNS TABLE(
  service_id BIGINT, vendor TEXT, device_type TEXT, actions_count INT, employee_count INT,
  total_price NUMERIC, base_cost NUMERIC, extra_cost NUMERIC, zone TEXT,
  action_list TEXT[], employee_list TEXT[], extra_actions TEXT[]
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT s.service_id, s.vendor, s.group_name, s.actions_count, s.employee_count,
    s.total_price, s.base_cost, s.overrun, s.zone, s.action_types, s.employees, s.extra_actions
  FROM period_services s WHERE s.period_key = p_period AND s.service_id = p_service_id;
$$;

CREATE OR REPLACE FUNCTION get_services_list_p(p_period TEXT)
RETURNS TABLE(service_id BIGINT, vendor TEXT, group_name TEXT, total_price NUMERIC,
              base_cost NUMERIC, overrun NUMERIC, zone TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT service_id, vendor, group_name, total_price, base_cost, overrun, zone
  FROM period_services WHERE period_key = p_period ORDER BY service_id;
$$;

-- Удаление отчёта должно инвалидировать периоды, куда он входил
CREATE OR REPLACE FUNCTION delete_report(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM periods         WHERE p_report_id = ANY(report_ids);
  DELETE FROM weekly_insights WHERE report_id = p_report_id;
  DELETE FROM anomalies       WHERE report_id = p_report_id;
  DELETE FROM employee_stats  WHERE report_id = p_report_id;
  DELETE FROM services        WHERE report_id = p_report_id;
  DELETE FROM actions         WHERE report_id = p_report_id;
  DELETE FROM uploads         WHERE id = p_report_id;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
