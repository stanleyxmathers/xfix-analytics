-- ============================================================
-- XFIX Analytics — Supabase RPC functions
-- Прогнать ПОСЛЕ supabase_schema.sql.
-- Все функции SECURITY DEFINER — анон вызывает только через RPC.
-- ============================================================

-- ------------------------------------------------------------
-- ВНУТРЕННЕЕ: пересчёт services по report_id
-- (overrun/zone через action_settings.is_base — это боевая логика,
--  была введена как resync_services поверх старой pattern-mining схемы)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION recompute_services_for_report(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  WITH svc_agg AS (
    SELECT service_id, report_id,
      MAX(vendor) AS vendor,
      MAX(group_name) AS group_name,
      SUM(price) AS total_price,
      COUNT(*) AS actions_count,
      COUNT(DISTINCT employee) AS employee_count,
      ARRAY_AGG(DISTINCT employee) FILTER (WHERE employee IS NOT NULL) AS employees,
      ARRAY_AGG(DISTINCT action_type) FILTER (WHERE action_type IS NOT NULL) AS action_types
    FROM actions
    WHERE report_id = p_report_id
    GROUP BY service_id, report_id
  ),
  spd AS (
    SELECT DISTINCT ON (a.service_id)
      a.service_id,
      COALESCE(ed.department, a.department) AS department
    FROM actions a
    LEFT JOIN employee_departments ed ON ed.employee = a.employee
    WHERE a.report_id = p_report_id AND a.employee IS NOT NULL
    ORDER BY a.service_id, a.action_date DESC NULLS LAST
  ),
  sac AS (
    SELECT sal.service_id, sal.action_type,
      cfg.is_base, COALESCE(cfg.base_cost, 0) AS cfg_base_cost
    FROM (
      SELECT DISTINCT service_id, action_type FROM actions
      WHERE report_id = p_report_id AND action_type IS NOT NULL
    ) sal
    JOIN svc_agg sv ON sv.service_id = sal.service_id
    LEFT JOIN spd ON spd.service_id = sal.service_id
    LEFT JOIN LATERAL (
      SELECT is_base, base_cost FROM action_settings
      WHERE action_name = sal.action_type
        AND (department = '*' OR department = spd.department)
        AND (device_type = '*' OR device_type = sv.group_name)
      ORDER BY (department = spd.department)::int DESC, (device_type = sv.group_name)::int DESC
      LIMIT 1
    ) cfg ON true
  ),
  sap AS (
    SELECT service_id, action_type, SUM(price) AS actual_price
    FROM actions WHERE report_id = p_report_id AND action_type IS NOT NULL
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
  INSERT INTO services(service_id, report_id, vendor, group_name, total_price, actions_count, employee_count, employees, action_types, base_cost, overrun, overrun_pct, zone, overrun_reason, extra_actions)
  SELECT sa.service_id, sa.report_id, sa.vendor, sa.group_name, sa.total_price, sa.actions_count, sa.employee_count, sa.employees, sa.action_types,
    sc.base_cost,
    sc.extra_cost AS overrun,
    CASE WHEN sc.base_cost > 0 THEN ROUND(sc.extra_cost / sc.base_cost * 100, 2) ELSE 0 END AS overrun_pct,
    CASE
      WHEN sc.base_cost = 0 THEN 'normal'
      WHEN sc.extra_cost = 0 THEN 'normal'
      WHEN sc.extra_cost / sc.base_cost <= 0.30 THEN 'small'
      WHEN sc.extra_cost / sc.base_cost <= 1.00 THEN 'elevated'
      ELSE 'critical'
    END AS zone,
    NULLIF(ARRAY_TO_STRING(COALESCE(sc.extra_actions, ARRAY[]::text[]), ' + '), '') AS overrun_reason,
    COALESCE(sc.extra_actions, ARRAY[]::text[])
  FROM svc_agg sa JOIN svc_cost sc ON sc.service_id = sa.service_id
  ON CONFLICT (service_id, report_id) DO UPDATE SET
    vendor=EXCLUDED.vendor, group_name=EXCLUDED.group_name, total_price=EXCLUDED.total_price,
    actions_count=EXCLUDED.actions_count, employee_count=EXCLUDED.employee_count,
    employees=EXCLUDED.employees, action_types=EXCLUDED.action_types,
    base_cost=EXCLUDED.base_cost, overrun=EXCLUDED.overrun, overrun_pct=EXCLUDED.overrun_pct,
    zone=EXCLUDED.zone, overrun_reason=EXCLUDED.overrun_reason, extra_actions=EXCLUDED.extra_actions;
END;
$$;

-- ------------------------------------------------------------
-- ВНУТРЕННЕЕ: аномалии
-- Type1: сотрудник по стоимости/перерасходу выше среднего по отделу (20%/60%)
-- Type2: дублирующиеся действия на одном обращении (2=warning, 3+=critical)
-- Type3: завышенное число действий/обращение vs медиана отдела (1.4x/2x)
-- Type4: обращение растянуто во времени сверх норматива этапов (2 дн. / 7 дн.)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION detect_anomalies_for_report(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM anomalies WHERE report_id = p_report_id;

  -- Type 1: cost outlier
  INSERT INTO anomalies(report_id, anomaly_type, entity_id, message, severity, metric, value, avg_value, deviation_pct)
  SELECT p_report_id, 'employee', es.employee,
    es.employee || ': средняя стоимость обращения выше среднего по отделу',
    CASE WHEN es.avg_service_cost > da.avg_cost * 1.6 THEN 'critical' ELSE 'warning' END,
    'avg_service_cost', es.avg_service_cost, da.avg_cost,
    ROUND((es.avg_service_cost / NULLIF(da.avg_cost,0) - 1) * 100, 1)
  FROM employee_stats es
  JOIN (SELECT department, AVG(avg_service_cost) AS avg_cost FROM employee_stats WHERE report_id = p_report_id GROUP BY department) da
    ON da.department = es.department
  WHERE es.report_id = p_report_id AND da.avg_cost > 0 AND es.avg_service_cost > da.avg_cost * 1.2;

  -- Type 1b: overrun outlier
  INSERT INTO anomalies(report_id, anomaly_type, entity_id, message, severity, metric, value, avg_value, deviation_pct)
  SELECT p_report_id, 'employee', es.employee,
    es.employee || ': суммарный перерасход выше среднего по отделу',
    CASE WHEN es.total_overrun > da.avg_overrun * 1.6 THEN 'critical' ELSE 'warning' END,
    'total_overrun', es.total_overrun, da.avg_overrun,
    ROUND((es.total_overrun / NULLIF(da.avg_overrun,0) - 1) * 100, 1)
  FROM employee_stats es
  JOIN (SELECT department, AVG(total_overrun) AS avg_overrun FROM employee_stats WHERE report_id = p_report_id GROUP BY department) da
    ON da.department = es.department
  WHERE es.report_id = p_report_id AND da.avg_overrun > 0 AND es.total_overrun > da.avg_overrun * 1.2;

  -- Type 2: duplicate actions
  INSERT INTO anomalies(report_id, anomaly_type, entity_id, message, severity, metric, value, avg_value, deviation_pct)
  SELECT p_report_id, 'service', d.service_id::text,
    d.employee || ': действие "' || d.action_type || '" повторено ' || d.cnt || ' раз на обращении ' || d.service_id,
    CASE WHEN d.cnt >= 3 THEN 'critical' ELSE 'warning' END,
    'duplicate_action', d.cnt, 1, NULL
  FROM (
    SELECT employee, service_id, action_type, COUNT(*) AS cnt
    FROM actions WHERE report_id = p_report_id AND action_type IS NOT NULL AND employee IS NOT NULL
    GROUP BY employee, service_id, action_type HAVING COUNT(*) > 1
  ) d;

  -- Type 3: excess actions per service vs dept median
  INSERT INTO anomalies(report_id, anomaly_type, entity_id, message, severity, metric, value, avg_value, deviation_pct)
  SELECT p_report_id, 'employee', ac.employee,
    ac.employee || ': среднее число действий на обращение выше типичного по отделу',
    CASE WHEN ac.avg_per_service > dm.median_aps * 2 THEN 'critical' ELSE 'warning' END,
    'avg_actions_per_service', ac.avg_per_service, dm.median_aps,
    ROUND((ac.avg_per_service / NULLIF(dm.median_aps,0) - 1) * 100, 1)
  FROM (
    SELECT employee, MAX(department) AS department,
      COUNT(*)::numeric / NULLIF(COUNT(DISTINCT service_id),0) AS avg_per_service,
      COUNT(DISTINCT service_id) AS svc_count
    FROM actions WHERE report_id = p_report_id AND employee IS NOT NULL
    GROUP BY employee
  ) ac
  JOIN (
    SELECT department, (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_per_service))::numeric AS median_aps
    FROM (
      SELECT employee, MAX(department) AS department,
        COUNT(*)::numeric / NULLIF(COUNT(DISTINCT service_id),0) AS avg_per_service
      FROM actions WHERE report_id = p_report_id AND employee IS NOT NULL
      GROUP BY employee
    ) x GROUP BY department
  ) dm ON dm.department = ac.department
  WHERE ac.avg_per_service > dm.median_aps * 1.4 AND ac.avg_per_service > 3 AND ac.svc_count >= 3;

  -- Type 4: обращение растянуто во времени (по нормативам SLA на этапы)
  --   Этап 1 — Обработка + Базовая диагностика: норматив 2 дня (по 1 суткам на действие)
  --   Этап 2 — + Расширенное тестирование:      норматив 7 дней (1 + 1 + 5)
  INSERT INTO anomalies(report_id, anomaly_type, entity_id, message, severity, metric, value, avg_value, deviation_pct)
  SELECT p_report_id, 'service', g.service_id::text,
    'Обращение ' || g.service_id || ' растянуто на ' || g.days || ' дн. при нормативе ' || g.limit_days || ' дн. (' || g.stage || ')',
    CASE WHEN g.days > g.limit_days * 2 THEN 'critical' ELSE 'warning' END,
    'day_gap', g.days, g.limit_days, ROUND((g.days::numeric / g.limit_days - 1) * 100, 1)
  FROM (
    SELECT service_id, 'Обработка + базовая диагностика' AS stage, 2 AS limit_days,
      (MAX(action_date) - MIN(action_date) + 1) AS days
    FROM actions
    WHERE report_id = p_report_id AND action_date IS NOT NULL
      AND (action_type ILIKE 'Обработ%' OR action_type ILIKE 'Базовая диагностика%')
    GROUP BY service_id
    HAVING (MAX(action_date) - MIN(action_date) + 1) > 2

    UNION ALL

    SELECT service_id, 'Обработка + базовая диагностика + расширенное тестирование' AS stage, 7 AS limit_days,
      (MAX(action_date) - MIN(action_date) + 1) AS days
    FROM actions
    WHERE report_id = p_report_id AND action_date IS NOT NULL
      AND (action_type ILIKE 'Обработ%' OR action_type ILIKE 'Базовая диагностика%' OR action_type ILIKE 'Расширенн%')
    GROUP BY service_id
    HAVING (MAX(action_date) - MIN(action_date) + 1) > 7
  ) g;
END;
$$;

-- ------------------------------------------------------------
-- ВНУТРЕННЕЕ: week-over-week инсайты (порог 5%)
-- ------------------------------------------------------------
-- Сводка по одному отчёту: то же, что строка v_weekly_summary, но по индексу
-- services(report_id), без агрегации всей таблицы. NULL на входе → пустой набор.
CREATE OR REPLACE FUNCTION report_summary(p_report_id INT)
RETURNS TABLE(
  report_id INT, total_services BIGINT, total_payments NUMERIC,
  avg_service_cost NUMERIC, non_standard_count BIGINT, total_overrun NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT p_report_id,
    COUNT(DISTINCT s.service_id),
    COALESCE(SUM(s.total_price), 0),
    COALESCE(AVG(s.total_price), 0),
    COUNT(DISTINCT CASE WHEN s.zone <> 'normal' THEN s.id END),
    COALESCE(SUM(CASE WHEN s.overrun > 0 THEN s.overrun END), 0)
  FROM services s
  WHERE p_report_id IS NOT NULL AND s.report_id = p_report_id
  HAVING COUNT(*) > 0;
$$;

CREATE OR REPLACE FUNCTION build_weekly_insights_for_report(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM weekly_insights WHERE report_id = p_report_id;

  -- v_weekly_summary агрегирует services по ВСЕМ неделям сразу, поэтому при импорте
  -- (одна неделя = один вызов) он не используется: считаем два отчёта точечно.
  INSERT INTO weekly_insights(report_id, insight_type, message, change_pct, direction)
  WITH prev_id AS (
    SELECT u.id FROM uploads u
    WHERE u.id <> p_report_id
      AND u.report_week < (SELECT report_week FROM uploads WHERE id = p_report_id)
    ORDER BY u.report_week DESC LIMIT 1
  ),
  cur  AS (SELECT * FROM report_summary(p_report_id)),
  prev AS (SELECT * FROM report_summary((SELECT id FROM prev_id)))
  SELECT p_report_id, t.insight_type, t.message, t.change_pct, t.direction
  FROM (
    SELECT 'services_count' AS insight_type,
      'Кол-во обращений изменилось на ' || ROUND((cur.total_services - prev.total_services)::numeric * 100 / NULLIF(prev.total_services,0),1) || '%' AS message,
      ROUND((cur.total_services - prev.total_services)::numeric * 100 / NULLIF(prev.total_services,0),1) AS change_pct,
      CASE WHEN cur.total_services >= prev.total_services THEN 'up' ELSE 'down' END AS direction
    FROM cur, prev
    UNION ALL
    SELECT 'payments',
      'Выплаты изменились на ' || ROUND((cur.total_payments - prev.total_payments) * 100 / NULLIF(prev.total_payments,0),1) || '%',
      ROUND((cur.total_payments - prev.total_payments) * 100 / NULLIF(prev.total_payments,0),1),
      CASE WHEN cur.total_payments >= prev.total_payments THEN 'up' ELSE 'down' END
    FROM cur, prev
    UNION ALL
    SELECT 'overrun',
      'Перерасход изменился на ' || ROUND((cur.total_overrun - prev.total_overrun) * 100 / NULLIF(prev.total_overrun,0),1) || '%',
      ROUND((cur.total_overrun - prev.total_overrun) * 100 / NULLIF(prev.total_overrun,0),1),
      CASE WHEN cur.total_overrun >= prev.total_overrun THEN 'up' ELSE 'down' END
    FROM cur, prev
    UNION ALL
    SELECT 'avg_cost',
      'Средняя стоимость обращения изменилась на ' || ROUND((cur.avg_service_cost - prev.avg_service_cost) * 100 / NULLIF(prev.avg_service_cost,0),1) || '%',
      ROUND((cur.avg_service_cost - prev.avg_service_cost) * 100 / NULLIF(prev.avg_service_cost,0),1),
      CASE WHEN cur.avg_service_cost >= prev.avg_service_cost THEN 'up' ELSE 'down' END
    FROM cur, prev
  ) t
  WHERE t.change_pct IS NOT NULL AND ABS(t.change_pct) >= 5;
END;
$$;

-- ------------------------------------------------------------
-- ИМПОРТ: разбит на 3 RPC, т.к. платформа жёстко режет statement_timeout
-- (роль postgres capped на 3s, не переопределяется через ALTER ROLE).
-- Клиент вызывает их последовательно: rows -> recompute -> stats.
-- p_rows: jsonb-массив объектов {id, employee, action_date, office, department,
--   action_type, group_name, subgroup, comment, price, service_id, vendor}
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION import_report_rows(p_week DATE, p_filename TEXT, p_rows JSONB)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_report_id INT;
BEGIN
  INSERT INTO uploads(report_week, filename, row_count)
  VALUES (p_week, p_filename, jsonb_array_length(p_rows))
  -- upload_date обновляем и при перезаливке: по нему периоды понимают, что кэш протух
  ON CONFLICT (report_week) DO UPDATE SET filename = EXCLUDED.filename, upload_date = NOW()
  RETURNING id INTO v_report_id;

  DELETE FROM actions WHERE report_id = v_report_id;

  INSERT INTO actions(id, report_id, employee, action_date, office, department, action_type, group_name, subgroup, comment, price, service_id, vendor)
  SELECT
    (r->>'id')::bigint,
    v_report_id,
    NULLIF(r->>'employee',''),
    NULLIF(r->>'action_date','')::date,
    NULLIF(r->>'office',''),
    NULLIF(r->>'department',''),
    NULLIF(r->>'action_type',''),
    NULLIF(r->>'group_name',''),
    NULLIF(r->>'subgroup',''),
    NULLIF(r->>'comment',''),
    COALESCE((r->>'price')::numeric, 0),
    (r->>'service_id')::bigint,
    NULLIF(r->>'vendor','')
  FROM jsonb_array_elements(p_rows) AS r;

  UPDATE uploads SET row_count = (SELECT COUNT(*) FROM actions WHERE report_id = v_report_id) WHERE id = v_report_id;

  RETURN v_report_id;
END;
$$;

CREATE OR REPLACE FUNCTION import_report_recompute(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM services WHERE report_id = p_report_id;
  PERFORM recompute_services_for_report(p_report_id);
END;
$$;

-- ANALYZE вынесен из recompute: он идёт по всей таблице и при импорте пачки недель
-- его стоимость умножалась на число недель. Клиент зовёт один раз в конце загрузки.
CREATE OR REPLACE FUNCTION import_analyze()
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  ANALYZE actions;
  ANALYZE services;
END;
$$;

CREATE OR REPLACE FUNCTION import_report_stats(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM employee_stats WHERE report_id = p_report_id;
  INSERT INTO employee_stats(report_id, employee, department, services_count, total_earnings, avg_service_cost, non_standard_count, total_overrun, non_standard_pct, extra_action_count, overrun_index)
  SELECT a.report_id, a.employee,
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
  LEFT JOIN services s ON s.service_id = a.service_id AND s.report_id = a.report_id
  WHERE a.report_id = p_report_id AND a.employee IS NOT NULL
  GROUP BY a.report_id, a.employee;

  PERFORM detect_anomalies_for_report(p_report_id);
  PERFORM build_weekly_insights_for_report(p_report_id);
END;
$$;

-- ------------------------------------------------------------
-- Полное удаление отчёта: сам upload + все производные строки.
-- SECURITY DEFINER — обходит RLS (anon-роль напрямую удалять не может).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_report(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM weekly_insights WHERE report_id = p_report_id;
  DELETE FROM anomalies       WHERE report_id = p_report_id;
  DELETE FROM employee_stats  WHERE report_id = p_report_id;
  DELETE FROM services        WHERE report_id = p_report_id;
  DELETE FROM actions         WHERE report_id = p_report_id;
  DELETE FROM uploads         WHERE id = p_report_id;
END;
$$;

-- ------------------------------------------------------------
-- ЧТЕНИЕ: существующие страницы дашборда (1:1 с прежней n8n-логикой)
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION get_uploads()
RETURNS TABLE(id INT, report_week TEXT, filename TEXT, row_count INT, upload_date TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id, report_week::text, filename, row_count, upload_date::text FROM uploads ORDER BY report_week DESC;
$$;

CREATE OR REPLACE FUNCTION get_overview(p_report_id INT)
RETURNS TABLE(
  report_id INT, report_week TEXT, total_services BIGINT, total_payments NUMERIC,
  avg_service_cost NUMERIC, non_standard_count BIGINT, total_overrun NUMERIC,
  prev_services BIGINT, prev_payments NUMERIC, prev_avg NUMERIC, prev_nonstandard BIGINT, prev_overrun NUMERIC,
  zone_normal BIGINT, zone_small BIGINT, zone_elevated BIGINT, zone_critical BIGINT,
  zone_yellow BIGINT, zone_red BIGINT, potential_savings NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT ws.report_id, ws.report_week::text, ws.total_services, ws.total_payments,
    ws.avg_service_cost, ws.non_standard_count, ws.total_overrun,
    (SELECT total_services FROM v_weekly_summary WHERE report_id < p_report_id ORDER BY report_week DESC LIMIT 1),
    (SELECT total_payments FROM v_weekly_summary WHERE report_id < p_report_id ORDER BY report_week DESC LIMIT 1),
    (SELECT avg_service_cost FROM v_weekly_summary WHERE report_id < p_report_id ORDER BY report_week DESC LIMIT 1),
    (SELECT non_standard_count FROM v_weekly_summary WHERE report_id < p_report_id ORDER BY report_week DESC LIMIT 1),
    (SELECT total_overrun FROM v_weekly_summary WHERE report_id < p_report_id ORDER BY report_week DESC LIMIT 1),
    COUNT(CASE WHEN s.zone = 'normal' THEN 1 END),
    COUNT(CASE WHEN s.zone = 'small' THEN 1 END),
    COUNT(CASE WHEN s.zone = 'elevated' THEN 1 END),
    COUNT(CASE WHEN s.zone = 'critical' THEN 1 END),
    COUNT(CASE WHEN s.zone IN ('small','elevated') THEN 1 END),
    COUNT(CASE WHEN s.zone = 'critical' THEN 1 END),
    (SELECT base_total FROM v_savings WHERE report_id = p_report_id LIMIT 1)
  FROM v_weekly_summary ws
  LEFT JOIN services s ON s.report_id = ws.report_id
  WHERE ws.report_id = p_report_id
  GROUP BY ws.report_id, ws.report_week, ws.total_services, ws.total_payments, ws.avg_service_cost, ws.non_standard_count, ws.total_overrun;
$$;

CREATE OR REPLACE FUNCTION get_weekly()
RETURNS TABLE(report_id INT, report_week TEXT, total_services BIGINT, total_payments NUMERIC, avg_service_cost NUMERIC, non_standard_count BIGINT, total_overrun NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT report_id, report_week::text, total_services, total_payments, avg_service_cost, non_standard_count, total_overrun
  FROM v_weekly_summary ORDER BY report_week;
$$;

CREATE OR REPLACE FUNCTION get_overruns(p_report_id INT)
RETURNS TABLE(service_id BIGINT, vendor TEXT, group_name TEXT, total_price NUMERIC, base_cost NUMERIC, overrun NUMERIC, overrun_pct NUMERIC, zone TEXT, overrun_reason TEXT, employees TEXT[], extra_actions TEXT[])
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT service_id, vendor, group_name, total_price, base_cost, overrun, overrun_pct, zone, overrun_reason, employees, extra_actions
  FROM services WHERE report_id = p_report_id AND overrun > 0 ORDER BY overrun DESC;
$$;

CREATE OR REPLACE FUNCTION get_reasons(p_report_id INT)
RETURNS TABLE(reason TEXT, cases_count BIGINT, total_overrun NUMERIC, pct_of_total NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT reason, cases_count, total_overrun, pct_of_total FROM v_overrun_reasons
  WHERE report_id = p_report_id ORDER BY total_overrun DESC LIMIT 20;
$$;

CREATE OR REPLACE FUNCTION get_employees(p_report_id INT)
RETURNS TABLE(
  employee TEXT, department TEXT, services_count INT, total_earnings NUMERIC, extra_action_count INT,
  non_standard_pct NUMERIC, overrun_index NUMERIC, avg_actions_per_service NUMERIC,
  dept_median_actions NUMERIC, duplicate_action_count BIGINT, vs_median_pct NUMERIC
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH action_counts AS (
    SELECT report_id, employee, COUNT(*) AS total_actions
    FROM actions WHERE report_id = p_report_id AND employee IS NOT NULL
    GROUP BY report_id, employee
  ),
  dept_medians AS (
    SELECT es.report_id, COALESCE(es.department, 'All') AS dept,
      CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ac.total_actions::numeric / NULLIF(es.services_count, 0)) AS numeric) AS median_actions_per_svc
    FROM employee_stats es
    JOIN action_counts ac ON ac.employee = es.employee AND ac.report_id = es.report_id
    WHERE es.report_id = p_report_id
    GROUP BY es.report_id, COALESCE(es.department, 'All')
  ),
  dup_counts AS (
    SELECT report_id, employee, COUNT(*) AS duplicate_count
    FROM (
      SELECT report_id, employee, service_id, action_type
      FROM actions WHERE report_id = p_report_id AND action_type IS NOT NULL AND employee IS NOT NULL
      GROUP BY report_id, employee, service_id, action_type HAVING COUNT(*) > 1
    ) d GROUP BY report_id, employee
  ),
  overrun_idx AS (
    SELECT a.employee,
      ROUND(SUM(CASE WHEN s.overrun > 0 THEN s.overrun ELSE 0 END)::numeric / NULLIF(COUNT(DISTINCT s.service_id)::numeric, 0), 2) AS overrun_index
    FROM services s JOIN actions a ON a.service_id = s.service_id AND a.report_id = s.report_id
    WHERE s.report_id = p_report_id AND a.employee IS NOT NULL
    GROUP BY a.employee
  )
  SELECT
    es.employee, es.department, es.services_count, es.total_earnings, es.extra_action_count, es.non_standard_pct,
    COALESCE(oi.overrun_index, 0),
    ROUND(ac.total_actions::numeric / NULLIF(es.services_count, 0), 2),
    ROUND(dm.median_actions_per_svc, 2),
    COALESCE(dc.duplicate_count, 0) AS duplicate_action_count,
    ROUND((ac.total_actions::numeric / NULLIF(es.services_count, 0) / NULLIF(dm.median_actions_per_svc, 0) - 1) * 100, 1) AS vs_median_pct
  FROM employee_stats es
  JOIN action_counts ac ON ac.employee = es.employee AND ac.report_id = es.report_id
  JOIN dept_medians dm ON dm.report_id = es.report_id AND dm.dept = COALESCE(es.department, 'All')
  LEFT JOIN dup_counts dc ON dc.employee = es.employee AND dc.report_id = es.report_id
  LEFT JOIN overrun_idx oi ON oi.employee = es.employee
  WHERE es.report_id = p_report_id
  ORDER BY 10 DESC NULLS LAST, 11 DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION get_employee_duplicates(p_report_id INT, p_employee TEXT DEFAULT NULL)
RETURNS TABLE(employee TEXT, service_id BIGINT, action_type TEXT, repeat_count BIGINT, first_date TEXT, last_date TEXT, total_price NUMERIC, unit_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.employee, a.service_id, a.action_type, COUNT(*), MIN(a.action_date::text), MAX(a.action_date::text), SUM(a.price), MIN(a.price)
  FROM actions a
  WHERE a.report_id = p_report_id AND a.action_type IS NOT NULL AND a.employee IS NOT NULL
    AND (p_employee IS NULL OR a.employee = p_employee)
  GROUP BY a.employee, a.service_id, a.action_type
  HAVING COUNT(*) > 1
  ORDER BY COUNT(*) DESC, SUM(a.price) DESC
  LIMIT 100;
$$;

CREATE OR REPLACE FUNCTION get_vendors(p_report_id INT)
RETURNS TABLE(vendor TEXT, services BIGINT, payments NUMERIC, avg_cost NUMERIC, overrun NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT vendor, COUNT(DISTINCT service_id), SUM(total_price), AVG(total_price), SUM(overrun)
  FROM services WHERE report_id = p_report_id GROUP BY vendor ORDER BY 3 DESC;
$$;

CREATE OR REPLACE FUNCTION get_insights(p_report_id INT)
RETURNS TABLE(insight_type TEXT, message TEXT, change_pct NUMERIC, direction TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT insight_type, message, change_pct, direction FROM weekly_insights
  WHERE report_id = p_report_id ORDER BY ABS(change_pct) DESC;
$$;

CREATE OR REPLACE FUNCTION get_anomalies(p_report_id INT)
RETURNS TABLE(anomaly_type TEXT, entity_id TEXT, message TEXT, severity TEXT, metric TEXT, value NUMERIC, avg_value NUMERIC, deviation_pct NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT anomaly_type, entity_id, message, severity, metric, value, avg_value, deviation_pct
  FROM anomalies WHERE report_id = p_report_id ORDER BY severity DESC, deviation_pct DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION get_workload_daily(p_report_id INT)
RETURNS TABLE(date TEXT, dow INT, label TEXT, services BIGINT, employees_active BIGINT, total_actions BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT action_date::text, EXTRACT(DOW FROM action_date)::int, TO_CHAR(action_date, 'DD.MM'),
    COUNT(DISTINCT service_id), COUNT(DISTINCT employee), COUNT(*)
  FROM actions
  WHERE report_id = p_report_id AND action_date IS NOT NULL AND action_type = 'Обработано'
  GROUP BY action_date ORDER BY action_date;
$$;

CREATE OR REPLACE FUNCTION get_emp_throughput(p_report_id INT)
RETURNS TABLE(employee TEXT, days_worked BIGINT, total_services BIGINT, avg_per_day NUMERIC, max_per_day BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH daily AS (
    SELECT employee, action_date, COUNT(DISTINCT service_id) AS day_services
    FROM actions
    WHERE report_id = p_report_id AND employee IS NOT NULL AND action_date IS NOT NULL AND action_type = 'Обработано'
    GROUP BY employee, action_date
  )
  SELECT employee, COUNT(DISTINCT action_date), SUM(day_services),
    ROUND(SUM(day_services)::numeric / NULLIF(COUNT(DISTINCT action_date), 0), 1), MAX(day_services)
  FROM daily GROUP BY employee ORDER BY 4 DESC;
$$;

CREATE OR REPLACE FUNCTION get_action_names()
RETURNS TABLE(action_name TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT DISTINCT action_type FROM actions WHERE action_type IS NOT NULL ORDER BY action_type LIMIT 500;
$$;

CREATE OR REPLACE FUNCTION get_employee_list()
RETURNS TABLE(employee TEXT, department TEXT, is_manual BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT DISTINCT ON (a.employee) a.employee, COALESCE(ed.department, a.department, ''), (ed.department IS NOT NULL)
  FROM actions a LEFT JOIN employee_departments ed ON ed.employee = a.employee
  WHERE a.employee IS NOT NULL ORDER BY a.employee;
$$;

-- ------------------------------------------------------------
-- НОВЫЕ ОТЧЁТЫ ПО МЕТОДИКЕ (Отчёты №1–6 + KPI + структура обращения)
-- ------------------------------------------------------------

-- Отчёт 1: обработано по вендору
CREATE OR REPLACE FUNCTION report_vendor_processed(p_report_id INT)
RETURNS TABLE(vendor TEXT, devices BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT vendor, COUNT(DISTINCT service_id) AS devices
  FROM actions WHERE report_id = p_report_id AND action_type = 'Обработано'
  GROUP BY vendor ORDER BY 2 DESC;
$$;

-- Отчёт 2: обработанные устройства по сотруднику/подгруппе/вендору
CREATE OR REPLACE FUNCTION report_employee_devices(p_report_id INT)
RETURNS TABLE(employee TEXT, subgroup TEXT, vendor TEXT, devices BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee, subgroup, vendor, COUNT(DISTINCT service_id) AS devices
  FROM actions WHERE report_id = p_report_id AND action_type = 'Обработано' AND employee IS NOT NULL
  GROUP BY employee, subgroup, vendor ORDER BY employee, 4 DESC;
$$;

-- Отчёт 3: все действия сотрудников (по уникальным service_id на тип действия)
CREATE OR REPLACE FUNCTION report_employee_actions(p_report_id INT)
RETURNS TABLE(employee TEXT, action_type TEXT, cnt BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee, action_type, COUNT(DISTINCT service_id) AS cnt
  FROM actions WHERE report_id = p_report_id AND employee IS NOT NULL AND action_type IS NOT NULL
  GROUP BY employee, action_type ORDER BY employee, 3 DESC;
$$;

-- Отчёт 4: выплаты сотрудникам по типу действия
CREATE OR REPLACE FUNCTION report_employee_payouts(p_report_id INT)
RETURNS TABLE(employee TEXT, action_type TEXT, total_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee, action_type, SUM(price) AS total_price
  FROM actions WHERE report_id = p_report_id AND employee IS NOT NULL
  GROUP BY employee, action_type ORDER BY employee, 3 DESC;
$$;

-- Отчёт 5: распределение выплат по вендорам
CREATE OR REPLACE FUNCTION report_vendor_payouts(p_report_id INT)
RETURNS TABLE(vendor TEXT, employee TEXT, action_type TEXT, devices BIGINT, total_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT vendor, employee, action_type, COUNT(DISTINCT service_id) AS devices, SUM(price) AS total_price
  FROM actions WHERE report_id = p_report_id AND employee IS NOT NULL
  GROUP BY vendor, employee, action_type ORDER BY vendor, 5 DESC;
$$;

-- Отчёт 6: ненормированная работа
CREATE OR REPLACE FUNCTION report_unscheduled_work(p_report_id INT)
RETURNS TABLE(employee TEXT, devices BIGINT, total_price NUMERIC, avg_price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee, COUNT(DISTINCT service_id) AS devices, SUM(price) AS total_price, AVG(price) AS avg_price
  FROM actions WHERE report_id = p_report_id AND action_type = 'Ненормированная работа' AND employee IS NOT NULL
  GROUP BY employee ORDER BY 3 DESC;
$$;

-- KPI сотрудника
CREATE OR REPLACE FUNCTION get_employee_kpi(p_report_id INT, p_employee TEXT)
RETURNS TABLE(
  devices BIGINT, actions_count BIGINT, extra_actions INT, total_earnings NUMERIC,
  avg_action_cost NUMERIC, avg_service_cost NUMERIC, avg_earnings_per_service NUMERIC,
  non_standard_pct NUMERIC, apple_services BIGINT, yandex_services BIGINT
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
    COUNT(DISTINCT CASE WHEN a.vendor = 'Яндекс' THEN a.service_id END)
  FROM actions a
  LEFT JOIN employee_stats es ON es.employee = a.employee AND es.report_id = a.report_id
  WHERE a.report_id = p_report_id AND a.employee = p_employee;
$$;

-- Структура обращения
CREATE OR REPLACE FUNCTION get_service_structure(p_report_id INT, p_service_id BIGINT)
RETURNS TABLE(
  service_id BIGINT, vendor TEXT, device_type TEXT, actions_count INT, employee_count INT,
  total_price NUMERIC, base_cost NUMERIC, extra_cost NUMERIC, zone TEXT,
  action_list TEXT[], employee_list TEXT[], extra_actions TEXT[]
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT s.service_id, s.vendor, s.group_name, s.actions_count, s.employee_count,
    s.total_price, s.base_cost, s.overrun, s.zone, s.action_types, s.employees, s.extra_actions
  FROM services s WHERE s.report_id = p_report_id AND s.service_id = p_service_id;
$$;

-- KPI всех сотрудников разом (для сравнительной таблицы на странице KPI)
CREATE OR REPLACE FUNCTION get_employee_kpi_all(p_report_id INT)
RETURNS TABLE(
  employee TEXT, devices BIGINT, actions_count BIGINT, extra_actions INT, total_earnings NUMERIC,
  avg_action_cost NUMERIC, avg_service_cost NUMERIC, non_standard_pct NUMERIC,
  apple_services BIGINT, yandex_services BIGINT
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
    COUNT(DISTINCT CASE WHEN a.vendor = 'Яндекс' THEN a.service_id END)
  FROM actions a
  LEFT JOIN employee_stats es ON es.employee = a.employee AND es.report_id = a.report_id
  WHERE a.report_id = p_report_id AND a.employee IS NOT NULL
  GROUP BY a.employee
  ORDER BY SUM(a.price) DESC NULLS LAST;
$$;

-- Детализация KPI сотрудника по обращениям (для drill-down на странице KPI)
CREATE OR REPLACE FUNCTION get_employee_kpi_detail(p_report_id INT, p_employee TEXT)
RETURNS TABLE(
  service_id BIGINT, action_date DATE, vendor TEXT, group_name TEXT,
  action_type TEXT, price NUMERIC, zone TEXT, is_extra BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.service_id, a.action_date, a.vendor, a.group_name, a.action_type, a.price,
    COALESCE(s.zone, 'normal') AS zone,
    (a.action_type = ANY(COALESCE(s.extra_actions, ARRAY[]::text[]))) AS is_extra
  FROM actions a
  LEFT JOIN services s ON s.service_id = a.service_id AND s.report_id = a.report_id
  WHERE a.report_id = p_report_id AND a.employee = p_employee
  ORDER BY a.service_id, a.action_date;
$$;

-- Плоский список обращений отчёта — для drill-down плиток на главной
CREATE OR REPLACE FUNCTION get_services_list(p_report_id INT)
RETURNS TABLE(service_id BIGINT, vendor TEXT, group_name TEXT, total_price NUMERIC,
              base_cost NUMERIC, overrun NUMERIC, zone TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT service_id, vendor, group_name, total_price, base_cost, overrun, zone
  FROM services WHERE report_id = p_report_id ORDER BY service_id;
$$;

-- ------------------------------------------------------------
-- GRANTS
-- ------------------------------------------------------------
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
