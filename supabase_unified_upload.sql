-- ============================================================
-- XFIX Analytics — один отчёт на всё
-- Общий отчёт (все сотрудники, все типы, все колонки) кормит:
--   • недели / перерасход / еженедельный отчёт (actions, как раньше);
--   • KPI руководителя с октября 2026 (actions по датам месяца);
--   • проверки перед выдачей (issue_checks — строки этого типа при импорте).
-- Показатели дашборда считаются только по «моему отделу» — см. dept_actions
-- в supabase_functions.sql; KPI и проверки — по всем действиям.
-- Прогнать целиком в Supabase SQL Editor ПОСЛЕ supabase_functions.sql,
-- supabase_periods.sql, supabase_issue_checks.sql, supabase_kpi.sql (идемпотентно).
-- ============================================================

-- 1. Признаки для KPI. NULL = колонки не было в файле (старые загрузки).
ALTER TABLE actions ADD COLUMN IF NOT EXISTS is_corp    SMALLINT;
ALTER TABLE actions ADD COLUMN IF NOT EXISTS is_overdue SMALLINT;

-- 2. Импорт недели. Отличия от прежней версии:
--    • заменяются только даты, которые есть в файле: месячный файл не затирает
--      соседние дни пограничной недели (29–30 сентября в неделе 29.09–05.10);
--    • сохраняются is_corp / is_overdue;
--    • строки «Проверка перед выдачей» upsert-ятся в issue_checks.
--    row_id — "id" строки выгрузки (если колонка есть), для check_id проверки.
CREATE OR REPLACE FUNCTION import_report_rows(p_week DATE, p_filename TEXT, p_rows JSONB)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_report_id INT;
  v_from      DATE;
  v_to        DATE;
  v_nodate    BOOLEAN;
  v_offset    BIGINT;
BEGIN
  INSERT INTO uploads(report_week, filename, row_count)
  VALUES (p_week, p_filename, jsonb_array_length(p_rows))
  -- upload_date обновляем и при перезаливке: по нему периоды понимают, что кэш протух
  ON CONFLICT (report_week) DO UPDATE SET filename = EXCLUDED.filename, upload_date = NOW()
  RETURNING id INTO v_report_id;

  SELECT MIN(NULLIF(r->>'action_date','')::date), MAX(NULLIF(r->>'action_date','')::date),
         bool_or(NULLIF(r->>'action_date','') IS NULL)
    INTO v_from, v_to, v_nodate
  FROM jsonb_array_elements(p_rows) AS r;

  DELETE FROM actions
  WHERE report_id = v_report_id
    AND ((action_date BETWEEN v_from AND v_to) OR (v_nodate AND action_date IS NULL));

  -- id уникален в пределах отчёта: новые строки — после оставшихся
  SELECT COALESCE(MAX(id), 0) INTO v_offset FROM actions WHERE report_id = v_report_id;

  INSERT INTO actions(id, report_id, employee, action_date, office, department, action_type, group_name, subgroup, comment, price, service_id, vendor, action_time, accepted_at, is_corp, is_overdue)
  SELECT
    (r->>'id')::bigint + v_offset,
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
    NULLIF(r->>'accepted_at','')::timestamp,
    NULLIF(r->>'is_corp','')::smallint,
    NULLIF(r->>'is_overdue','')::smallint
  FROM jsonb_array_elements(p_rows) AS r;

  -- Проверки перед выдачей → issue_checks (вместо отдельного файла).
  -- check_id: "id" строки выгрузки; без него — стабильный хэш строки.
  INSERT INTO issue_checks(check_id, check_date, check_time, checker, service_id, passed, comment, vendor, uploaded_at)
  SELECT DISTINCT ON (x.check_id) x.check_id, x.check_date, x.check_time, x.checker, x.service_id,
         x.passed, x.comment, x.vendor, NOW()
  FROM (
    SELECT
      COALESCE(NULLIF(r->>'row_id','')::bigint,
               abs(hashtextextended(concat_ws('|', r->>'service_id', r->>'action_date', r->>'action_time', r->>'employee'), 0))) AS check_id,
      NULLIF(r->>'action_date','')::date AS check_date,
      NULLIF(r->>'action_time','')::time AS check_time,
      NULLIF(r->>'employee','')          AS checker,
      (r->>'service_id')::bigint         AS service_id,
      NOT (lower(COALESCE(r->>'group_name','')) LIKE 'ошиб%') AS passed,
      NULLIF(r->>'comment','')           AS comment,
      NULLIF(r->>'vendor','')            AS vendor
    FROM jsonb_array_elements(p_rows) AS r
    WHERE r->>'action_type' = 'Проверка перед выдачей'
      AND NULLIF(r->>'action_date','') IS NOT NULL
      AND NULLIF(r->>'service_id','') IS NOT NULL
  ) x
  ORDER BY x.check_id
  ON CONFLICT (check_id) DO UPDATE SET
    check_date = EXCLUDED.check_date, check_time = EXCLUDED.check_time, checker = EXCLUDED.checker,
    service_id = EXCLUDED.service_id, passed = EXCLUDED.passed, comment = EXCLUDED.comment,
    vendor = EXCLUDED.vendor, uploaded_at = EXCLUDED.uploaded_at;

  UPDATE uploads SET row_count = (SELECT COUNT(*) FROM actions WHERE report_id = v_report_id) WHERE id = v_report_id;

  RETURN v_report_id;
END;
$$;

-- 3. KPI руководителя из общего отчёта.
-- Месяцы, за которые есть действия (с начала новой схемы KPI).
-- with_flags — строк с заполненным «Ключ просрочен» (0 = отчёт без колонки).
CREATE OR REPLACE FUNCTION get_kpi_months()
RETURNS TABLE(month DATE, row_count BIGINT, with_flags BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT date_trunc('month', action_date)::date, COUNT(*), COUNT(is_overdue)
  FROM actions
  WHERE action_date >= DATE '2026-10-01'
  GROUP BY 1 ORDER BY 1 DESC;
$$;

-- Строки месяца, свёрнутые по полям, которые нужны показателям: n — число
-- действий, price — сумма. Клиент фильтрует их по правилам схемы KPI.
CREATE OR REPLACE FUNCTION get_kpi_month_rows(p_month DATE)
RETURNS TABLE(employee TEXT, action_type TEXT, subgroup TEXT, group_name TEXT,
              is_corp SMALLINT, is_overdue SMALLINT, n BIGINT, price NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee::text, action_type::text, subgroup::text, group_name::text, is_corp, is_overdue, COUNT(*), SUM(price)
  FROM actions
  WHERE action_date >= p_month AND action_date < (p_month + INTERVAL '1 month')::date
  GROUP BY 1, 2, 3, 4, 5, 6
  ORDER BY 1, 2, 3, 4, 5, 6;   -- стабильный порядок: клиент читает постранично
$$;

-- 4. Переключатель «Мой отдел / Все» в перерасходе больше не нужен: область
--    задаётся на уровне агрегатов (dept_actions в supabase_functions.sql).
DROP FUNCTION IF EXISTS get_overruns_by_employees_p(TEXT, TEXT[]);

GRANT EXECUTE ON FUNCTION import_report_rows(DATE, TEXT, JSONB) TO anon;
GRANT EXECUTE ON FUNCTION get_kpi_months() TO anon;
GRANT EXECUTE ON FUNCTION get_kpi_month_rows(DATE) TO anon;
