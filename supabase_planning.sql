-- ============================================================
-- XFIX Analytics — Планирование: нормы по устройствам, поступление,
-- продуктивность сотрудников, план графика на месяц.
-- Считается по «моему отделу» (dept_actions) за произвольный диапазон дат,
-- не по выбранному отчёту-неделе.
--
-- Время на действие — интервал от предыдущего действия того же сотрудника
-- в тот же день. Интервал больше p_cap минут (по умолчанию 40) — перерыв
-- или простой, во время работы не входит.
--
-- Прогнать ПОСЛЕ supabase_functions.sql и supabase_schedule.sql (идемпотентно).
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_actions_action_date ON actions(action_date);

-- Действия отдела диагностики (ядро). Корректировку даты продажи делает и
-- сопровождение, проверку перед выдачей — ОКК: в ядро не входят.
CREATE OR REPLACE FUNCTION plan_core_types()
RETURNS TEXT[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['Обработано', 'Базовая диагностика', 'Базовая диагностика - Повтор',
               'Расширенная диагностика', 'Выходная диагностика', 'Проверка после НАСЦ',
               'Диагностика с ЗАСЦ', 'Замена иностранных AirPods', 'Услуги'];
$$;

-- ВНУТРЕННЕЕ: действия отдела за диапазон с интервалом до предыдущего действия.
-- gap_min — интервал в минутах (NULL у первого действия дня);
-- is_core — действие ядра (услуги — только записанные на отдел диагностики).
CREATE OR REPLACE FUNCTION plan_actions(p_from DATE, p_to DATE)
RETURNS TABLE(employee TEXT, action_date DATE, action_time TIME, action_type TEXT,
              group_name TEXT, vendor TEXT, subgroup TEXT, service_id BIGINT,
              price NUMERIC, accepted_at TIMESTAMP, is_core BOOLEAN, gap_min NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.employee::text, a.action_date, a.action_time, a.action_type::text,
         a.group_name::text, a.vendor::text, a.subgroup::text, a.service_id,
         a.price, a.accepted_at,
         a.action_type = ANY(plan_core_types())
           AND NOT (a.action_type = 'Услуги' AND a.department IS DISTINCT FROM 'Диагносты'),
         EXTRACT(EPOCH FROM a.action_time - LAG(a.action_time) OVER (
           PARTITION BY a.employee, a.action_date ORDER BY a.action_time, a.id)) / 60
  FROM dept_actions a
  WHERE a.action_date BETWEEN p_from AND p_to
    AND a.employee IS NOT NULL AND a.action_time IS NOT NULL;
$$;

-- ------------------------------------------------------------
-- 1. Нормы времени по устройствам
-- Минуты на обращение = сумма интервалов перед действиями ядра по обращению.
-- Группа обращения — самая частая группа его действий. Обращения без
-- измеренного интервала (единственное действие — первое за день) не входят.
-- employee = NULL — норма отдела, иначе личная норма сотрудника
-- (по его действиям на обращении).
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_device_norms(DATE, DATE, INT);
CREATE OR REPLACE FUNCTION get_device_norms(p_from DATE, p_to DATE, p_cap INT DEFAULT 40)
RETURNS TABLE(employee TEXT, group_name TEXT, vendor TEXT, services BIGINT,
              med_min NUMERIC, avg_min NUMERIC, rt_share NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH g AS (
    SELECT * FROM plan_actions(p_from, p_to) WHERE is_core
  ),
  svc AS (
    SELECT g.service_id, mode() WITHIN GROUP (ORDER BY g.group_name) AS grp, MAX(g.vendor) AS vendor
    FROM g WHERE g.group_name IS NOT NULL AND g.service_id IS NOT NULL
    GROUP BY g.service_id
  ),
  per AS (
    SELECT g.service_id, g.employee, GROUPING(g.employee) AS is_dept,
           SUM(g.gap_min) FILTER (WHERE g.gap_min <= p_cap) AS mins,
           bool_or(g.action_type = 'Расширенная диагностика') AS rt
    FROM g WHERE g.service_id IS NOT NULL
    GROUP BY GROUPING SETS ((g.service_id), (g.service_id, g.employee))
  )
  SELECT CASE WHEN per.is_dept = 1 THEN NULL ELSE per.employee END,
         svc.grp, svc.vendor, COUNT(*),
         ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY per.mins)::numeric, 1),
         ROUND(AVG(per.mins), 1),
         ROUND(AVG(per.rt::int), 3)
  FROM per JOIN svc USING (service_id)
  WHERE per.mins IS NOT NULL
  GROUP BY per.is_dept, CASE WHEN per.is_dept = 1 THEN NULL ELSE per.employee END, svc.grp, svc.vendor
  ORDER BY 1 NULLS FIRST, 4 DESC;
$$;

-- ------------------------------------------------------------
-- 2. Поступление: принятые устройства по дате и часу приёма
-- Устройство считается, если по нему было действие ядра отдела в диапазоне
-- (принятые в последние дни диапазона могут быть ещё не обработаны —
-- клиент помечает хвост как неполный).
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_intake(DATE, DATE);
CREATE OR REPLACE FUNCTION get_intake(p_from DATE, p_to DATE)
RETURNS TABLE(acc_date DATE, acc_hour INT, group_name TEXT, vendor TEXT, devices BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH svc AS (
    SELECT a.service_id, MIN(a.accepted_at) AS acc,
           mode() WITHIN GROUP (ORDER BY a.group_name) AS grp, MAX(a.vendor) AS vendor
    FROM dept_actions a
    WHERE a.action_date BETWEEN p_from AND p_to + 14
      AND a.action_type = ANY(plan_core_types())
      AND a.service_id IS NOT NULL AND a.accepted_at IS NOT NULL
    GROUP BY a.service_id
  )
  SELECT acc::date, EXTRACT(HOUR FROM acc)::int, grp::text, vendor::text, COUNT(*)
  FROM svc
  WHERE acc::date BETWEEN p_from AND p_to
  GROUP BY 1, 2, 3, 4
  ORDER BY 1, 2;
$$;

-- Лаг от приёма до первого действия ядра и до базовой диагностики (дней, 7 = 7+)
DROP FUNCTION IF EXISTS get_intake_lag(DATE, DATE);
CREATE OR REPLACE FUNCTION get_intake_lag(p_from DATE, p_to DATE)
RETURNS TABLE(stage TEXT, lag_days INT, services BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH svc AS (
    SELECT a.service_id, MIN(a.accepted_at)::date AS acc,
           MIN(a.action_date) AS first_core,
           MIN(a.action_date) FILTER (WHERE a.action_type = 'Базовая диагностика') AS first_base
    FROM dept_actions a
    WHERE a.action_date BETWEEN p_from AND p_to
      AND a.action_type = ANY(plan_core_types())
      AND a.service_id IS NOT NULL AND a.accepted_at IS NOT NULL
    GROUP BY a.service_id
  )
  SELECT 'first', LEAST(first_core - acc, 7), COUNT(*) FROM svc
  WHERE acc >= p_from AND first_core >= acc GROUP BY 2
  UNION ALL
  SELECT 'base', LEAST(first_base - acc, 7), COUNT(*) FROM svc
  WHERE acc >= p_from AND first_base >= acc GROUP BY 2
  ORDER BY 1, 2;
$$;

-- ------------------------------------------------------------
-- 3. Продуктивность: сотрудник × день
-- norm_min — условные минуты: каждое действие ядра оценивается средним
-- временем отдела на такое действие с устройством этой группы (если таких
-- действий меньше 15 — средним по типу действия). Сумма условных минут
-- сравнима между сотрудниками независимо от состава устройств.
-- active_min — измеренное время работы (интервалы ≤ p_cap), idle_min — сумма
-- интервалов > p_cap между действиями. Смена — из work_schedule (Shifton);
-- дни по графику без действий тоже попадают (n_actions = 0).
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_employee_productivity(DATE, DATE, INT);
CREATE OR REPLACE FUNCTION get_employee_productivity(p_from DATE, p_to DATE, p_cap INT DEFAULT 40)
RETURNS TABLE(employee TEXT, work_date DATE, shift_start TIME, shift_end TIME,
              first_time TIME, last_time TIME, n_actions BIGINT, n_core BIGINT,
              devices BIGINT, rub NUMERIC, norm_min NUMERIC, active_min NUMERIC, idle_min NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH a AS (
    SELECT * FROM plan_actions(p_from, p_to)
  ),
  n_gt AS (
    SELECT a.group_name, a.action_type, COUNT(*) AS n, AVG(a.gap_min) AS m
    FROM a WHERE a.is_core AND a.gap_min <= p_cap
    GROUP BY a.group_name, a.action_type
  ),
  n_t AS (
    SELECT a.action_type, AVG(a.gap_min) AS m
    FROM a WHERE a.is_core AND a.gap_min <= p_cap
    GROUP BY a.action_type
  ),
  day AS (
    SELECT a.employee, a.action_date,
           MIN(a.action_time) AS first_time, MAX(a.action_time) AS last_time,
           COUNT(*) AS n_actions, COUNT(*) FILTER (WHERE a.is_core) AS n_core,
           COUNT(DISTINCT a.service_id) FILTER (WHERE a.is_core) AS devices,
           SUM(a.price) AS rub,
           SUM(CASE WHEN a.is_core THEN COALESCE(CASE WHEN g.n >= 15 THEN g.m END, t.m, 0) ELSE 0 END) AS norm_min,
           SUM(a.gap_min) FILTER (WHERE a.gap_min <= p_cap) AS active_min,
           SUM(a.gap_min) FILTER (WHERE a.gap_min > p_cap) AS idle_min
    FROM a
    LEFT JOIN n_gt g ON g.group_name IS NOT DISTINCT FROM a.group_name AND g.action_type = a.action_type
    LEFT JOIN n_t t ON t.action_type = a.action_type
    GROUP BY a.employee, a.action_date
  ),
  sched AS (
    SELECT w.employee, w.work_date, w.shift_start, w.shift_end
    FROM work_schedule w
    WHERE w.work_date BETWEEN p_from AND p_to
      AND w.employee IN (SELECT DISTINCT day.employee FROM day)
  )
  SELECT COALESCE(d.employee, s.employee), COALESCE(d.action_date, s.work_date),
         s.shift_start, s.shift_end, d.first_time, d.last_time,
         COALESCE(d.n_actions, 0), COALESCE(d.n_core, 0), COALESCE(d.devices, 0),
         COALESCE(d.rub, 0), ROUND(COALESCE(d.norm_min, 0), 1),
         ROUND(COALESCE(d.active_min, 0), 1), ROUND(COALESCE(d.idle_min, 0), 1)
  FROM day d
  FULL JOIN sched s ON s.employee = d.employee AND s.work_date = d.action_date
  ORDER BY 1, 2;
$$;

-- ------------------------------------------------------------
-- 4. Качество и сроки по сотрудникам
-- base_lag_med — от приёма устройства до базовой диагностики этого сотрудника
-- (календарных дней); rt_found — РТ, где неисправность найдена.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_employee_quality(DATE, DATE);
CREATE OR REPLACE FUNCTION get_employee_quality(p_from DATE, p_to DATE)
RETURNS TABLE(employee TEXT, base BIGINT, base_repeat BIGINT, rt BIGINT, rt_found BIGINT,
              base_lag_med NUMERIC, base_in_1d BIGINT, base_with_acc BIGINT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH a AS (
    SELECT * FROM plan_actions(p_from, p_to) WHERE is_core
  ),
  lag AS (
    SELECT a.employee, a.service_id,
           MIN(a.action_date) - MIN(a.accepted_at)::date AS d
    FROM a
    WHERE a.action_type = 'Базовая диагностика' AND a.accepted_at IS NOT NULL
    GROUP BY a.employee, a.service_id
  ),
  l AS (
    SELECT lag.employee,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY lag.d) AS med,
           COUNT(*) FILTER (WHERE lag.d <= 1) AS in1, COUNT(*) AS n
    FROM lag WHERE lag.d >= 0 GROUP BY lag.employee
  ),
  c AS (
    SELECT a.employee,
           COUNT(*) FILTER (WHERE a.action_type = 'Базовая диагностика') AS base,
           COUNT(*) FILTER (WHERE a.action_type = 'Базовая диагностика - Повтор') AS base_repeat,
           COUNT(*) FILTER (WHERE a.action_type = 'Расширенная диагностика') AS rt,
           COUNT(*) FILTER (WHERE a.action_type = 'Расширенная диагностика'
                              AND a.subgroup IS DISTINCT FROM 'Неисправности не обнаружены') AS rt_found
    FROM a GROUP BY a.employee
  )
  SELECT c.employee, c.base, c.base_repeat, c.rt, c.rt_found,
         ROUND(l.med::numeric, 1), COALESCE(l.in1, 0), COALESCE(l.n, 0)
  FROM c LEFT JOIN l USING (employee)
  ORDER BY c.base DESC;
$$;

-- ------------------------------------------------------------
-- 5. Ожидаемые поставки: список устройств, которые ждём, с примерной датой.
-- Грузится из Excel в дашборде; для дней из списка нагрузка считается по нему,
-- остальные дни — по статистике поступления.
-- group_name — группа устройства (как в actions), raw_name — как в файле.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS expected_supply (
  id            BIGSERIAL PRIMARY KEY,
  expected_date DATE NOT NULL,
  group_name    TEXT,
  raw_name      TEXT,
  qty           INT  NOT NULL DEFAULT 1,
  waybill       TEXT,                 -- номер накладной ТК (СДЭК) — для статуса доставки
  note          TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE expected_supply ADD COLUMN IF NOT EXISTS waybill TEXT;
CREATE INDEX IF NOT EXISTS idx_expected_supply_date ON expected_supply(expected_date);
ALTER TABLE expected_supply ENABLE ROW LEVEL SECURITY;

DROP FUNCTION IF EXISTS get_expected_supply(DATE, DATE);
CREATE OR REPLACE FUNCTION get_expected_supply(p_from DATE, p_to DATE)
RETURNS TABLE(id BIGINT, expected_date DATE, group_name TEXT, raw_name TEXT, qty INT, waybill TEXT, note TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id, expected_date, group_name, raw_name, qty, waybill, note
  FROM expected_supply
  WHERE expected_date BETWEEN p_from AND p_to
  ORDER BY expected_date, group_name;
$$;

-- Заменить ожидаемые поставки в диапазоне [p_from, p_to] строками из файла.
-- p_rows: [{expected_date, group_name, raw_name, qty, waybill, note}]
DROP FUNCTION IF EXISTS import_expected_supply(JSONB, DATE, DATE);
CREATE OR REPLACE FUNCTION import_expected_supply(p_rows JSONB, p_from DATE, p_to DATE)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_count INT;
BEGIN
  DELETE FROM expected_supply WHERE expected_date BETWEEN p_from AND p_to;
  INSERT INTO expected_supply(expected_date, group_name, raw_name, qty, waybill, note)
  SELECT (r->>'expected_date')::date, NULLIF(r->>'group_name', ''), NULLIF(r->>'raw_name', ''),
         GREATEST(COALESCE(NULLIF(r->>'qty', '')::int, 1), 0), NULLIF(r->>'waybill', ''), NULLIF(r->>'note', '')
  FROM jsonb_array_elements(p_rows) r
  WHERE (r->>'expected_date')::date BETWEEN p_from AND p_to;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ------------------------------------------------------------
-- 6. План графика на месяц
-- Отдельно от work_schedule (факт из Shifton): каждое сохранение — новая
-- версия, последняя считается действующей. params — настройки расчёта
-- (срок, загрузка, прогноз), чтобы потом сверить план с фактом.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_plan_versions (
  month      DATE        NOT NULL,
  version    INT         NOT NULL,
  params     JSONB,
  note       TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (month, version)
);
CREATE TABLE IF NOT EXISTS work_plan (
  month       DATE NOT NULL,
  version     INT  NOT NULL,
  employee    TEXT NOT NULL,
  work_date   DATE NOT NULL,
  shift_start TIME,
  shift_end   TIME,
  PRIMARY KEY (month, version, employee, work_date),
  FOREIGN KEY (month, version) REFERENCES work_plan_versions(month, version) ON DELETE CASCADE
);

ALTER TABLE work_plan_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_plan ENABLE ROW LEVEL SECURITY;

-- Последняя версия плана месяца
DROP FUNCTION IF EXISTS get_work_plan(DATE);
CREATE OR REPLACE FUNCTION get_work_plan(p_month DATE)
RETURNS TABLE(version INT, created_at TIMESTAMPTZ, params JSONB, note TEXT,
              employee TEXT, work_date DATE, shift_start TIME, shift_end TIME)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH v AS (
    SELECT * FROM work_plan_versions
    WHERE month = date_trunc('month', p_month)::date
    ORDER BY version DESC LIMIT 1
  )
  SELECT v.version, v.created_at, v.params, v.note, p.employee, p.work_date, p.shift_start, p.shift_end
  FROM v LEFT JOIN work_plan p ON p.month = v.month AND p.version = v.version
  ORDER BY p.employee, p.work_date;
$$;

-- Сохранить план как новую версию. p_rows: [{employee, work_date, shift_start?, shift_end?}]
DROP FUNCTION IF EXISTS save_work_plan(DATE, JSONB, JSONB, TEXT);
CREATE OR REPLACE FUNCTION save_work_plan(p_month DATE, p_rows JSONB, p_params JSONB, p_note TEXT DEFAULT NULL)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_month   DATE := date_trunc('month', p_month)::date;
  v_version INT;
BEGIN
  SELECT COALESCE(MAX(version), 0) + 1 INTO v_version FROM work_plan_versions WHERE month = v_month;
  INSERT INTO work_plan_versions(month, version, params, note) VALUES (v_month, v_version, p_params, p_note);
  INSERT INTO work_plan(month, version, employee, work_date, shift_start, shift_end)
  SELECT DISTINCT ON (r->>'employee', (r->>'work_date')::date)
    v_month, v_version, r->>'employee', (r->>'work_date')::date,
    NULLIF(r->>'shift_start', '')::time, NULLIF(r->>'shift_end', '')::time
  FROM jsonb_array_elements(p_rows) r
  WHERE date_trunc('month', (r->>'work_date')::date) = v_month;
  RETURN v_version;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
