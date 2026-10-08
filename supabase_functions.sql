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
  ssg AS (
    SELECT DISTINCT ON (a.service_id, a.action_type)
      a.service_id, a.action_type, a.subgroup, a.group_name
    FROM actions a
    WHERE a.report_id = p_report_id AND a.action_type IS NOT NULL
    ORDER BY a.service_id, a.action_type, a.action_date DESC NULLS LAST
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
  ) d
  LEFT JOIN duplicate_reviews dr
    ON dr.employee = d.employee AND dr.service_id = d.service_id AND dr.action_type = d.action_type
  WHERE dr.employee IS NULL OR dr.reviewed_repeat_count < d.cnt;

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
--   action_type, group_name, subgroup, comment, price, service_id, vendor,
--   action_time, accepted_at}
-- ------------------------------------------------------------
-- Для БД, созданных до появления колонок (в supabase_schema.sql они уже есть)
ALTER TABLE actions ADD COLUMN IF NOT EXISTS action_time TIME;
ALTER TABLE actions ADD COLUMN IF NOT EXISTS accepted_at TIMESTAMP;
-- поиск обращений, ожидавших работы в заданные дни (дни просадки)
CREATE INDEX IF NOT EXISTS idx_actions_action_date ON actions(action_date);

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

  INSERT INTO actions(id, report_id, employee, action_date, office, department, action_type, group_name, subgroup, comment, price, service_id, vendor, action_time, accepted_at)
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
    NULLIF(r->>'vendor',''),
    NULLIF(r->>'action_time','')::time,
    NULLIF(r->>'accepted_at','')::timestamp
  FROM jsonb_array_elements(p_rows) AS r;

  UPDATE uploads SET row_count = (SELECT COUNT(*) FROM actions WHERE report_id = v_report_id) WHERE id = v_report_id;

  RETURN v_report_id;
END;
$$;

-- SET LOCAL поднимает лимит только на эту транзакцию: anon-роль ограничена 3s
-- (достаточно для чтений дашборда), а пересчёт при импорте — тяжелее и не
-- укладывается в это окно на некоторых отчётах, из-за чего заливка откатывалась
-- целиком (клиент вызывает delete_report при ошибке recompute).
CREATE OR REPLACE FUNCTION import_report_recompute(p_report_id INT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SET LOCAL statement_timeout = '30s';
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
  SET LOCAL statement_timeout = '30s';
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
  dup_raw AS (
    SELECT report_id, employee, service_id, action_type, COUNT(*) AS cnt
    FROM actions WHERE report_id = p_report_id AND action_type IS NOT NULL AND employee IS NOT NULL
    GROUP BY report_id, employee, service_id, action_type HAVING COUNT(*) > 1
  ),
  dup_counts AS (
    /* разобранные вручную случаи (duplicate_reviews) из счётчика исключены,
       пока число повторов не выросло сверх зафиксированного при разборе */
    SELECT d.report_id, d.employee, COUNT(*) AS duplicate_count
    FROM dup_raw d
    LEFT JOIN duplicate_reviews dr
      ON dr.employee = d.employee AND dr.service_id = d.service_id AND dr.action_type = d.action_type
    WHERE dr.employee IS NULL OR dr.reviewed_repeat_count < d.cnt
    GROUP BY d.report_id, d.employee
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

-- p_include_reviewed = true возвращает и разобранные случаи (с review_status),
-- чтобы в UI можно было посмотреть/снять пометку.
DROP FUNCTION IF EXISTS get_employee_duplicates(INT, TEXT);
CREATE OR REPLACE FUNCTION get_employee_duplicates(
  p_report_id INT, p_employee TEXT DEFAULT NULL, p_include_reviewed BOOLEAN DEFAULT false
)
RETURNS TABLE(employee TEXT, service_id BIGINT, action_type TEXT, repeat_count BIGINT, first_date TEXT, last_date TEXT,
              total_price NUMERIC, unit_price NUMERIC, review_status TEXT, review_note TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH d AS (
    SELECT a.employee, a.service_id, a.action_type, COUNT(*) AS cnt,
           MIN(a.action_date::text) AS first_date, MAX(a.action_date::text) AS last_date,
           SUM(a.price) AS total_price, MIN(a.price) AS unit_price
    FROM actions a
    WHERE a.report_id = p_report_id AND a.action_type IS NOT NULL AND a.employee IS NOT NULL
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

CREATE OR REPLACE FUNCTION get_vendors(p_report_id INT)
RETURNS TABLE(vendor TEXT, services BIGINT, payments NUMERIC, avg_cost NUMERIC, overrun NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT vendor, COUNT(DISTINCT service_id), SUM(total_price), AVG(total_price), SUM(overrun)
  FROM services WHERE report_id = p_report_id GROUP BY vendor ORDER BY 3 DESC;
$$;

-- Динамика обращений по вендорам: одна строка на (день, вендор).
-- Обращение относим к его самой ранней дате действия внутри отчёта, чтобы
-- одно обращение не считалось в нескольких днях. Фронт сам бакетит по дням
-- (неделя) или по неделям (месяц/квартал).
CREATE OR REPLACE FUNCTION get_vendor_trend(p_report_ids INT[])
RETURNS TABLE(day DATE, vendor TEXT, services BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT t.day, t.vendor, COUNT(*)::BIGINT
  FROM (
    SELECT a.service_id, a.vendor, MIN(a.action_date) AS day
    FROM actions a
    WHERE a.report_id = ANY(p_report_ids)
      AND a.action_date IS NOT NULL
      AND NULLIF(a.vendor, '') IS NOT NULL
    GROUP BY a.report_id, a.service_id, a.vendor
  ) t
  GROUP BY t.day, t.vendor
  ORDER BY t.day;
$$;

-- Динамика трат на целевые действия по вендорам: сумма цены действий за день.
-- В отличие от обращений тут суммируем каждое действие по его собственной дате.
CREATE OR REPLACE FUNCTION get_vendor_money_trend(p_report_ids INT[])
RETURNS TABLE(day DATE, vendor TEXT, payments NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.action_date AS day, a.vendor, COALESCE(SUM(a.price), 0)::NUMERIC
  FROM actions a
  WHERE a.report_id = ANY(p_report_ids)
    AND a.action_date IS NOT NULL
    AND NULLIF(a.vendor, '') IS NOT NULL
  GROUP BY a.action_date, a.vendor
  ORDER BY a.action_date;
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
  SELECT an.anomaly_type, an.entity_id, an.message, an.severity, an.metric, an.value, an.avg_value, an.deviation_pct
  FROM anomalies an
  WHERE an.report_id = p_report_id
    /* дубли, разобранные вручную, из ленты аномалий убираем: сверяем обращение,
       название действия (оно есть в тексте сообщения) и число повторов */
    AND NOT (an.metric = 'duplicate_action' AND EXISTS (
      SELECT 1 FROM duplicate_reviews dr
      WHERE dr.service_id::text = an.entity_id
        AND dr.reviewed_repeat_count >= an.value
        AND an.message LIKE '%"' || dr.action_type || '"%'
    ))
  ORDER BY an.severity DESC, an.deviation_pct DESC NULLS LAST;
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

-- Список сотрудников: отдел (ручной или из отчёта), маркер актуальности,
-- дата последнего действия — чтобы в настройках видеть, кто давно не работал.
DROP FUNCTION IF EXISTS get_employee_list();
CREATE OR REPLACE FUNCTION get_employee_list()
RETURNS TABLE(employee TEXT, department TEXT, is_manual BOOLEAN,
              is_active BOOLEAN, inactive_since DATE,
              last_action_date DATE, actions_count BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    a.employee::text,
    COALESCE(ed.department, MAX(a.department), '')::text,
    (ed.department IS NOT NULL),
    COALESCE(ed.is_active, true),
    ed.inactive_since,
    MAX(a.action_date),
    COUNT(*)
  FROM actions a
  LEFT JOIN employee_departments ed ON ed.employee = a.employee
  WHERE a.employee IS NOT NULL
  GROUP BY a.employee, ed.department, ed.is_active, ed.inactive_since
  ORDER BY a.employee;
$$;

-- ------------------------------------------------------------
-- НОВЫЕ ОТЧЁТЫ ПО МЕТОДИКЕ (Отчёты №1–6 + KPI + структура обращения)
-- ------------------------------------------------------------

-- Состав еженедельного отчёта: поверх отдела по умолчанию (задаётся в дашборде)
-- include = true — добавить сотрудника другого отдела (подключался к работе),
-- include = false — убрать сотрудника своего отдела.
CREATE TABLE IF NOT EXISTS weekly_report_members (
  employee   TEXT PRIMARY KEY,
  include    BOOLEAN NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE weekly_report_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_all ON weekly_report_members;
CREATE POLICY anon_all ON weekly_report_members FOR ALL TO anon USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON weekly_report_members TO anon;

-- Отчёт 1: обработано по вендору (p_employees — состав отчёта, NULL = все)
DROP FUNCTION IF EXISTS report_vendor_processed(INT);
CREATE OR REPLACE FUNCTION report_vendor_processed(p_report_id INT, p_employees TEXT[] DEFAULT NULL)
RETURNS TABLE(vendor TEXT, devices BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT vendor, COUNT(DISTINCT service_id) AS devices
  FROM actions
  WHERE report_id = p_report_id AND action_type = 'Обработано'
    AND (p_employees IS NULL OR employee = ANY(p_employees))
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
DROP FUNCTION IF EXISTS get_employee_kpi(INT, TEXT);
CREATE OR REPLACE FUNCTION get_employee_kpi(p_report_id INT, p_employee TEXT)
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
DROP FUNCTION IF EXISTS get_employee_kpi_all(INT);
CREATE OR REPLACE FUNCTION get_employee_kpi_all(p_report_id INT)
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
  LEFT JOIN employee_stats es ON es.employee = a.employee AND es.report_id = a.report_id
  WHERE a.report_id = p_report_id AND a.employee IS NOT NULL
  GROUP BY a.employee
  ORDER BY SUM(a.price) DESC NULLS LAST;
$$;

-- Дни просадки. Для каждого сотрудника по дням:
--   efficiency   — его целевые действия к норме отдела в этот день
--                  (действия отдела / число работавших сотрудников отдела);
--   available_work — сколько устройств было готово для отдела в этот день:
--                  принято и отработано предыдущими отделами, но ещё не взято
--                  этим отделом (история обращений — по всем отчётам);
--   supply_ratio — доступная работа на сотрудника к среднему по отделу за период;
--   avg_day_actions — своя средняя дневная выработка (эталон, когда в отделе
--                  в этот день работал он один и сравнивать не с кем);
--   простои      — промежуток между единицами работы минус типичная длительность
--                  выполненной за него работы (75-й перцентиль по отделу и типу действия;
--                  нормативов длительности в выгрузке нет). Для каждого простоя —
--                  очередь: сколько устройств в его начале было готово для отдела
--                  и ещё не взято. Очередь > 0 — простой при наличии работы,
--                  0 — ждал работу; без данных о приёме очередь NULL;
--   scheduled    — день по графику (work_schedule, supabase_schedule.sql):
--                  true/false, NULL — графика на этот месяц у сотрудника нет.
--                  Дни вне графика (false) в нормы и средние не входят, смены по
--                  графику без единого действия возвращаются с нулями;
--   shift_start/shift_end, planned_minutes — плановая смена из графика;
--   expected_earnings — ожидаемый заработок за смену: средний заработок сотрудника
--                  за минуту плановых смен × длительность этой смены (короткая
--                  смена по графику — не просадка). NULL — время смен не задано.
-- Низкая supply_ratio = не обеспечили работой; низкая efficiency при нормальной
-- supply_ratio = низкая эффективность сотрудника. Без данных о приёме
-- (отчёты, залитые до появления accepted_at) available_work/supply_ratio = NULL,
-- вместо них — dept_output_ratio (выработка отдела на человека к своему среднему).
DROP FUNCTION IF EXISTS get_employee_downtime_days(INT);
DROP FUNCTION IF EXISTS employee_downtime_days_core(INT[]);
CREATE OR REPLACE FUNCTION employee_downtime_days_core(p_report_ids INT[])
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
  WITH bounds AS (
    SELECT MIN(action_date) AS d_from, MAX(action_date) AS d_to
    FROM actions WHERE report_id = ANY(p_report_ids)
  ),
  -- основной отдел: ручной из карточки, иначе самый частый в отчётах вокруг периода
  emp_dept AS (
    SELECT a.employee, COALESCE(MAX(ed.department), mode() WITHIN GROUP (ORDER BY a.department), '—') AS dept
    FROM actions a
    CROSS JOIN bounds b
    LEFT JOIN employee_departments ed ON ed.employee = a.employee
    WHERE a.employee IS NOT NULL AND a.action_date BETWEEN b.d_from - 60 AND b.d_to + 60
    GROUP BY a.employee
  ),
  emp_days_act AS (
    SELECT a.employee, a.action_date,
      SUM(a.price) AS day_earnings,
      COUNT(*) AS day_actions,
      bool_or(a.accepted_at IS NOT NULL) AS has_acc
    FROM actions a
    WHERE a.report_id = ANY(p_report_ids) AND a.action_date IS NOT NULL AND a.employee IS NOT NULL
    GROUP BY a.employee, a.action_date
  ),
  sched_days AS (
    SELECT ws.employee, ws.work_date AS action_date, ws.shift_start, ws.shift_end,
      -- смена через полночь (20:00-08:00) — плюс сутки
      ((EXTRACT(EPOCH FROM ws.shift_end) - EXTRACT(EPOCH FROM ws.shift_start)) / 60)::int
        + CASE WHEN ws.shift_end <= ws.shift_start THEN 1440 ELSE 0 END AS planned_minutes
    FROM work_schedule ws, bounds b
    WHERE ws.work_date BETWEEN b.d_from AND b.d_to
  ),
  -- график известен, если за месяц у сотрудника есть хоть одна отметка
  sched_known AS (
    SELECT DISTINCT ws.employee, date_trunc('month', ws.work_date)::date AS m
    FROM work_schedule ws, bounds b
    WHERE ws.work_date >= date_trunc('month', b.d_from)
      AND ws.work_date <  date_trunc('month', b.d_to) + INTERVAL '1 month'
  ),
  emp_days_all AS (
    SELECT x.employee, x.action_date,
      COALESCE(d.dept, ed.department, '—') AS dept,
      x.day_earnings, x.day_actions, x.has_acc,
      CASE WHEN k.employee IS NULL THEN NULL ELSE x.in_sched END AS scheduled,
      x.shift_start, x.shift_end, x.planned_minutes
    FROM (
      SELECT COALESCE(e.employee, s.employee) AS employee,
        COALESCE(e.action_date, s.action_date) AS action_date,
        COALESCE(e.day_earnings, 0) AS day_earnings,
        COALESCE(e.day_actions, 0) AS day_actions,
        COALESCE(e.has_acc, false) AS has_acc,
        s.employee IS NOT NULL AS in_sched,
        s.shift_start, s.shift_end, s.planned_minutes
      FROM emp_days_act e
      FULL JOIN sched_days s ON s.employee = e.employee AND s.action_date = e.action_date
    ) x
    LEFT JOIN emp_dept d ON d.employee = x.employee
    LEFT JOIN employee_departments ed ON ed.employee = x.employee
    LEFT JOIN sched_known k ON k.employee = x.employee AND k.m = date_trunc('month', x.action_date)::date
  ),
  -- рабочие дни: по графику или график неизвестен
  emp_days AS (
    SELECT * FROM emp_days_all WHERE scheduled IS DISTINCT FROM false
  ),
  dept_days AS (
    SELECT dept, action_date,
      SUM(day_actions) AS dept_actions,
      COUNT(*) FILTER (WHERE day_actions > 0) AS active_emps,
      bool_or(has_acc) AS has_acc
    FROM emp_days GROUP BY dept, action_date
  ),
  cand AS (
    SELECT DISTINCT a.service_id
    FROM actions a, bounds b
    WHERE a.action_date BETWEEN b.d_from AND b.d_to + 60
      AND a.accepted_at IS NOT NULL AND a.accepted_at::date <= b.d_to
  ),
  svc_acts AS (
    SELECT a.service_id, a.action_date, a.accepted_at, d.dept,
      -- 00:00 в выгрузке = время не заполнено (напр., все действия курьеров)
      a.action_date + NULLIF(a.action_time, TIME '00:00') AS ts
    FROM actions a
    JOIN cand c ON c.service_id = a.service_id
    JOIN emp_dept d ON d.employee = a.employee
    WHERE a.action_date IS NOT NULL
  ),
  svc_first AS (
    SELECT service_id, dept, MIN(action_date) AS first_d, MIN(ts) AS first_ts
    FROM svc_acts GROUP BY service_id, dept
  ),
  svc_acc AS (
    SELECT service_id, MIN(accepted_at) AS acc_ts FROM svc_acts GROUP BY service_id
  ),
  -- готово для отдела: принято и отработано предыдущими отделами (по дню и по времени)
  svc_ready AS (
    SELECT f.service_id, f.dept, f.first_d, f.first_ts,
      GREATEST(MAX(sa.acc_ts)::date, MAX(o.action_date) FILTER (WHERE o.action_date <= f.first_d)) AS ready_d,
      GREATEST(MAX(sa.acc_ts), MAX(o.ts) FILTER (WHERE o.ts <= f.first_ts)) AS ready_ts
    FROM svc_first f
    JOIN svc_acc sa ON sa.service_id = f.service_id
    LEFT JOIN svc_acts o ON o.service_id = f.service_id AND o.dept <> f.dept
    GROUP BY f.service_id, f.dept, f.first_d, f.first_ts
  ),
  dept_avail AS (
    SELECT dd.dept, dd.action_date, COUNT(r.service_id) AS available_work
    FROM dept_days dd
    LEFT JOIN svc_ready r
      ON r.dept = dd.dept AND r.ready_d <= dd.action_date AND r.first_d >= dd.action_date
    GROUP BY dd.dept, dd.action_date
  ),
  dept_stats AS (
    SELECT dd.dept, dd.action_date, dd.active_emps, dd.has_acc,
      dd.dept_actions::numeric / NULLIF(dd.active_emps, 0) AS norm_actions,
      da.available_work,
      CASE WHEN dd.has_acc THEN da.available_work::numeric / NULLIF(dd.active_emps, 0) END AS avail_per_emp
    FROM dept_days dd
    JOIN dept_avail da ON da.dept = dd.dept AND da.action_date = dd.action_date
  ),
  dept_stats2 AS (
    SELECT ds.*,
      ds.norm_actions  / NULLIF(AVG(ds.norm_actions)  OVER (PARTITION BY ds.dept), 0) AS output_ratio,
      ds.avail_per_emp / NULLIF(AVG(ds.avail_per_emp) OVER (PARTITION BY ds.dept), 0) AS supply_ratio
    FROM dept_stats ds
  ),
  emp_ts AS (
    SELECT a.employee, d.dept, a.action_date, a.action_type,
      a.action_date + a.action_time AS ts
    FROM actions a
    JOIN emp_dept d ON d.employee = a.employee
    WHERE a.report_id = ANY(p_report_ids) AND a.action_date IS NOT NULL
      AND a.action_time IS NOT NULL AND a.action_time <> TIME '00:00'
  ),
  emp_span AS (
    SELECT employee, action_date,
      MIN(ts)::time AS first_time, MAX(ts)::time AS last_time,
      (EXTRACT(EPOCH FROM MAX(ts) - MIN(ts)) / 60)::int AS work_minutes
    FROM emp_ts GROUP BY employee, action_date
  ),
  -- единица работы: действия с разрывом < 5 мин (диагностика + «Обработано» и т.п.)
  emp_ts_mark AS (
    SELECT t.*,
      CASE WHEN LAG(ts) OVER w IS NULL OR ts - LAG(ts) OVER w >= INTERVAL '5 minutes' THEN 1 ELSE 0 END AS new_unit
    FROM emp_ts t
    WINDOW w AS (PARTITION BY employee, action_date ORDER BY ts)
  ),
  emp_ts_unit AS (
    SELECT m.*, SUM(new_unit) OVER (PARTITION BY employee, action_date ORDER BY ts ROWS UNBOUNDED PRECEDING) AS unit
    FROM emp_ts_mark m
  ),
  work_units AS (
    SELECT employee, dept, action_date, unit,
      MIN(ts) AS unit_start, MAX(ts) AS unit_end, array_agg(DISTINCT action_type) AS types
    FROM emp_ts_unit GROUP BY employee, dept, action_date, unit
  ),
  -- промежуток перед единицей работы = время, за которое её сделали (+ возможный простой)
  unit_gaps AS (
    SELECT u.*,
      LAG(unit_end) OVER (PARTITION BY employee, action_date ORDER BY unit) AS prev_end
    FROM work_units u
  ),
  gap_types AS (
    SELECT g.employee, g.dept, g.action_date, g.prev_end, g.unit_start, t.action_type,
      EXTRACT(EPOCH FROM g.unit_start - g.prev_end) / 60 AS gap_min
    FROM unit_gaps g
    CROSS JOIN LATERAL unnest(g.types) AS t(action_type)
    WHERE g.prev_end IS NOT NULL
  ),
  -- норма длительности работы: 75-й перцентиль промежутка перед действием этого типа
  -- в отделе (с запасом: засчитываем работу выше средней сложности)
  type_norm AS (
    SELECT dept, action_type, COUNT(*) AS n,
      percentile_cont(0.75) WITHIN GROUP (ORDER BY gap_min) AS norm_min
    FROM gap_types GROUP BY dept, action_type
  ),
  dept_norm AS (
    SELECT dept, percentile_cont(0.75) WITHIN GROUP (ORDER BY gap_min) AS norm_min
    FROM gap_types GROUP BY dept
  ),
  unit_norm AS (
    SELECT gt.employee, gt.dept, gt.action_date, gt.prev_end AS gap_start, gt.unit_start AS gap_end,
      MAX(gt.gap_min) AS gap_min,
      COALESCE(MAX(tn.norm_min) FILTER (WHERE tn.n >= 5), MAX(dn.norm_min)) AS work_min
    FROM gap_types gt
    LEFT JOIN type_norm tn ON tn.dept = gt.dept AND tn.action_type = gt.action_type
    LEFT JOIN dept_norm dn ON dn.dept = gt.dept
    GROUP BY gt.employee, gt.dept, gt.action_date, gt.prev_end, gt.unit_start
  ),
  -- простой = промежуток сверх типичной длительности выполненной работы (от 20 мин)
  emp_gaps AS (
    SELECT employee, dept, action_date, gap_start, gap_end,
      ROUND(gap_min)::int AS gap_min,
      ROUND(work_min)::int AS work_min,
      ROUND(gap_min - work_min)::int AS idle_min
    FROM unit_norm
    WHERE gap_min - work_min >= 20
  ),
  gap_queue AS (
    SELECT g.employee, g.action_date, g.gap_start, g.gap_end, g.gap_min, g.work_min, g.idle_min,
      CASE WHEN MAX(dd.has_acc::int) = 1 THEN COUNT(r.service_id) END AS queue
    FROM emp_gaps g
    JOIN dept_days dd ON dd.dept = g.dept AND dd.action_date = g.action_date
    LEFT JOIN svc_ready r
      ON r.dept = g.dept AND r.ready_ts <= g.gap_start AND r.first_ts > g.gap_start
    GROUP BY g.employee, g.action_date, g.gap_start, g.gap_end, g.gap_min, g.work_min, g.idle_min
  ),
  emp_pause AS (
    SELECT employee, action_date,
      SUM(idle_min)::int AS idle_minutes,
      COALESCE(SUM(idle_min) FILTER (WHERE queue > 0), 0)::int AS idle_with_work_minutes,
      COALESCE(SUM(idle_min) FILTER (WHERE queue = 0), 0)::int AS idle_no_work_minutes,
      MAX(idle_min) AS longest_gap_minutes,
      jsonb_agg(jsonb_build_object(
        'from', to_char(gap_start, 'HH24:MI'), 'to', to_char(gap_end, 'HH24:MI'),
        'gap', gap_min, 'work', work_min, 'idle', idle_min, 'queue', queue) ORDER BY gap_start) AS gaps
    FROM gap_queue GROUP BY employee, action_date
  )
  SELECT e.employee, e.dept, e.action_date,
    e.day_earnings,
    ROUND(AVG(e.day_earnings) FILTER (WHERE e.scheduled IS DISTINCT FROM false) OVER (PARTITION BY e.employee), 2),
    e.day_actions,
    ROUND(s.norm_actions, 1),
    ROUND(e.day_actions / NULLIF(s.norm_actions, 0), 3),
    s.active_emps,
    CASE WHEN s.has_acc THEN s.available_work END,
    ROUND(s.supply_ratio, 3),
    ROUND(s.output_ratio, 3),
    ROUND(AVG(e.day_actions) FILTER (WHERE e.scheduled IS DISTINCT FROM false) OVER (PARTITION BY e.employee), 1),
    sp.first_time, sp.last_time, sp.work_minutes,
    ROUND(AVG(sp.work_minutes) FILTER (WHERE e.scheduled IS DISTINCT FROM false) OVER (PARTITION BY e.employee)),
    COALESCE(pz.idle_minutes, CASE WHEN sp.employee IS NOT NULL THEN 0 END),
    COALESCE(pz.idle_with_work_minutes, CASE WHEN sp.employee IS NOT NULL THEN 0 END),
    COALESCE(pz.idle_no_work_minutes, CASE WHEN sp.employee IS NOT NULL THEN 0 END),
    pz.longest_gap_minutes,
    COALESCE(pz.gaps, '[]'::jsonb),
    e.scheduled,
    e.shift_start, e.shift_end, e.planned_minutes,
    ROUND(e.planned_minutes
      * SUM(e.day_earnings) FILTER (WHERE e.planned_minutes > 0) OVER (PARTITION BY e.employee)
      / NULLIF(SUM(e.planned_minutes) FILTER (WHERE e.planned_minutes > 0) OVER (PARTITION BY e.employee), 0), 2)
  FROM emp_days_all e
  LEFT JOIN dept_stats2 s ON s.dept = e.dept AND s.action_date = e.action_date
  LEFT JOIN emp_span sp ON sp.employee = e.employee AND sp.action_date = e.action_date
  LEFT JOIN emp_pause pz ON pz.employee = e.employee AND pz.action_date = e.action_date
  ORDER BY e.employee, e.action_date;
$$;

CREATE OR REPLACE FUNCTION get_employee_downtime_days(p_report_id INT)
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
  SELECT * FROM employee_downtime_days_core(ARRAY[p_report_id]);
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
