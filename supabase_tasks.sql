-- ============================================================
-- XFIX Analytics — типы задач объединённого отдела (диагностика + логистика + ОКК).
-- Этап 2 приоритизации (Приоритизация_спецификация.md): нормы времени и загрузка
-- по типам задач, а не только по ядру диагностики.
--
-- Тип задачи действия задаётся разметкой task_action_map (тип действия + отдел
-- → тип задачи, отдел '*' — любой). Неразмеченные действия отдела «Логистика»
-- попадают в общий тип logistics, остальные неразмеченные в расчёт не входят.
--
-- Время на действие — как в supabase_planning.sql: интервал от предыдущего
-- действия того же сотрудника в тот же день (по всем его действиям, не только
-- размеченным); интервал больше p_cap минут — перерыв или простой.
--
-- Прогнать ПОСЛЕ supabase_planning.sql (идемпотентно).
-- ============================================================

CREATE TABLE IF NOT EXISTS task_types (
  code       TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  sort_order INT  NOT NULL DEFAULT 100,
  lane       TEXT NOT NULL DEFAULT 'dept'    -- dept — общая ёмкость отдела; okk — отдельная полоса ОКК;
                                             -- none — исключить действие из задач (skip)
);

INSERT INTO task_types(code, name, sort_order, lane) VALUES
  ('diag',            'Диагностика',          10, 'dept'),
  ('accessory_order', 'Заказ аксессуара',     20, 'dept'),
  ('asc_prep',        'Подготовка к АСЦ',     30, 'dept'),
  ('post_asc',        'Проверка после ЗАСЦ',  40, 'dept'),
  ('okk',             'Проверка (ОКК)',       50, 'okk'),
  ('issue',           'Выдача',               60, 'dept'),
  ('logistics',       'Логистика, не размечено', 90, 'dept'),
  ('other',           'Прочее',               95, 'dept'),
  ('skip',            'Не задача отдела',     99, 'none')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS task_action_map (
  action_type TEXT NOT NULL,
  department  TEXT NOT NULL DEFAULT '*',
  task_type   TEXT NOT NULL REFERENCES task_types(code),
  updated_at  TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (action_type, department)
);

-- Начальная разметка: ядро диагностики — как plan_core_types(), проверки после АСЦ
-- и проверка перед выдачей — отдельными типами. Действия логистики размечаются в
-- дашборде (Планирование → Типы задач), пока они в общем типе logistics.
INSERT INTO task_action_map(action_type, department, task_type) VALUES
  ('Обработано',                   '*',         'diag'),
  ('Базовая диагностика',          '*',         'diag'),
  ('Базовая диагностика - Повтор', '*',         'diag'),
  ('Расширенная диагностика',      '*',         'diag'),
  ('Замена иностранных AirPods',   '*',         'diag'),
  ('Услуги',                       'Диагносты', 'diag'),
  ('Выходная диагностика',         '*',         'post_asc'),
  ('Проверка после НАСЦ',          '*',         'post_asc'),
  ('Диагностика с ЗАСЦ',           '*',         'post_asc'),
  ('Проверка перед выдачей',       '*',         'okk')
ON CONFLICT (action_type, department) DO NOTHING;

ALTER TABLE task_types      ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_action_map ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_select ON task_types;
CREATE POLICY anon_select ON task_types FOR SELECT TO anon USING (true);
-- разметка правится из дашборда напрямую, как action_settings (внутренний инструмент)
DROP POLICY IF EXISTS anon_all ON task_action_map;
CREATE POLICY anon_all ON task_action_map FOR ALL TO anon USING (true) WITH CHECK (true);
GRANT SELECT ON task_types TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON task_action_map TO anon;

-- ВНУТРЕННЕЕ: действия за диапазон с типом задачи и интервалом до предыдущего действия.
-- task_type NULL — действие не размечено и не из логистики либо размечено как skip
-- (в расчёт задач не входит, но участвует в интервалах). unit_id — единица задачи: обращение, а для действий
-- без id сервиса — само действие.
CREATE OR REPLACE FUNCTION task_actions(p_from DATE, p_to DATE)
RETURNS TABLE(id BIGINT, employee TEXT, department TEXT, action_date DATE, action_time TIME,
              action_type TEXT, group_name TEXT, vendor TEXT, service_id BIGINT, unit_id BIGINT,
              price NUMERIC, task_type TEXT, gap_min NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.id, a.employee::text, a.department::text, a.action_date, a.action_time, a.action_type::text,
         a.group_name::text, a.vendor::text, a.service_id, COALESCE(a.service_id, -a.id),
         a.price,
         NULLIF(COALESCE(md.task_type, ma.task_type, CASE WHEN a.department = 'Логистика' THEN 'logistics' END), 'skip'),
         EXTRACT(EPOCH FROM a.action_time - LAG(a.action_time) OVER (
           PARTITION BY a.employee, a.action_date ORDER BY a.action_time, a.id)) / 60
  FROM actions a
  LEFT JOIN task_action_map md ON md.action_type = a.action_type AND md.department = a.department
  LEFT JOIN task_action_map ma ON ma.action_type = a.action_type AND ma.department = '*'
  WHERE a.action_date BETWEEN p_from AND p_to
    AND a.employee IS NOT NULL AND a.action_time IS NOT NULL;
$$;

-- ------------------------------------------------------------
-- Типы действий за период с текущей разметкой — для правки разметки в дашборде.
-- mapped_dept — по какой строке разметки определён тип ('*' или отдел); NULL — не размечено
-- (у логистики тогда task_type = logistics по умолчанию).
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_task_action_types(DATE, DATE);
CREATE OR REPLACE FUNCTION get_task_action_types(p_from DATE, p_to DATE)
RETURNS TABLE(action_type TEXT, department TEXT, actions BIGINT, employees BIGINT, rub NUMERIC,
              task_type TEXT, mapped_dept TEXT)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT a.action_type::text, a.department::text, COUNT(*), COUNT(DISTINCT a.employee),
         SUM(a.price),
         COALESCE(md.task_type, ma.task_type, CASE WHEN a.department = 'Логистика' THEN 'logistics' END),
         COALESCE(md.department, ma.department)
  FROM actions a
  LEFT JOIN task_action_map md ON md.action_type = a.action_type AND md.department = a.department
  LEFT JOIN task_action_map ma ON ma.action_type = a.action_type AND ma.department = '*'
  WHERE a.action_date BETWEEN p_from AND p_to AND a.action_type IS NOT NULL
  GROUP BY 1, 2, 6, 7
  ORDER BY 3 DESC;
$$;

-- ------------------------------------------------------------
-- Нормы по типам задач: минуты на единицу задачи (обращение) по группе устройства.
-- Минуты единицы — сумма интервалов ≤ p_cap перед её действиями этого типа задачи.
-- employee = NULL — норма отдела, иначе личная. rub — средняя оплата единицы
-- (по всем её действиям этого типа), rub_per_hour — оплата ÷ измеренное время.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_task_norms(DATE, DATE, INT);
CREATE OR REPLACE FUNCTION get_task_norms(p_from DATE, p_to DATE, p_cap INT DEFAULT 40)
RETURNS TABLE(task_type TEXT, employee TEXT, group_name TEXT, vendor TEXT, units BIGINT,
              actions BIGINT, med_min NUMERIC, avg_min NUMERIC, rub NUMERIC, rub_per_hour NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH a AS (
    SELECT * FROM task_actions(p_from, p_to) WHERE task_type IS NOT NULL
  ),
  unit AS (
    SELECT a.task_type, a.unit_id,
           COALESCE(mode() WITHIN GROUP (ORDER BY a.group_name), '—') AS grp, MAX(a.vendor) AS vendor
    FROM a GROUP BY a.task_type, a.unit_id
  ),
  per AS (
    SELECT a.task_type, a.unit_id, a.employee, GROUPING(a.employee) AS is_dept,
           SUM(a.gap_min) FILTER (WHERE a.gap_min <= p_cap) AS mins,
           COUNT(*) AS n, SUM(a.price) AS rub
    FROM a
    GROUP BY GROUPING SETS ((a.task_type, a.unit_id), (a.task_type, a.unit_id, a.employee))
  )
  SELECT per.task_type,
         CASE WHEN per.is_dept = 1 THEN NULL ELSE per.employee END,
         unit.grp, unit.vendor, COUNT(*), SUM(per.n),
         ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY per.mins)::numeric, 1),
         ROUND(AVG(per.mins), 1),
         ROUND(AVG(per.rub), 0),
         ROUND(SUM(per.rub) / NULLIF(SUM(per.mins), 0) * 60, 0)
  FROM per JOIN unit USING (task_type, unit_id)
  WHERE per.mins IS NOT NULL
  GROUP BY per.task_type, per.is_dept, CASE WHEN per.is_dept = 1 THEN NULL ELSE per.employee END,
           unit.grp, unit.vendor
  ORDER BY 1, 2 NULLS FIRST, 5 DESC;
$$;

-- ------------------------------------------------------------
-- Сотрудник × день × тип задачи: сколько сделано и сколько это по нормам отдела.
-- norm_min — условные минуты: каждое действие оценивается средним интервалом
-- отдела на такое действие с устройством этой группы (если таких меньше 15 —
-- средним по типу действия), как в get_employee_productivity. Сумма по типам
-- задач — нагрузка отдела за день; сравнима между днями и людьми.
-- Поля дня (смена, first/last, idle_min) одинаковы во всех строках дня;
-- task_type = NULL — день по графику без размеченных действий.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS get_task_daily(DATE, DATE, INT);
CREATE OR REPLACE FUNCTION get_task_daily(p_from DATE, p_to DATE, p_cap INT DEFAULT 40)
RETURNS TABLE(employee TEXT, work_date DATE, task_type TEXT, units BIGINT, n_actions BIGINT,
              rub NUMERIC, norm_min NUMERIC, active_min NUMERIC,
              shift_start TIME, shift_end TIME, first_time TIME, last_time TIME, idle_min NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH a AS (
    SELECT * FROM task_actions(p_from, p_to)
  ),
  t AS (
    SELECT * FROM a WHERE a.task_type IS NOT NULL
  ),
  n_gt AS (
    SELECT t.group_name, t.action_type, COUNT(*) AS n, AVG(t.gap_min) AS m
    FROM t WHERE t.gap_min <= p_cap GROUP BY t.group_name, t.action_type
  ),
  n_t AS (
    SELECT t.action_type, AVG(t.gap_min) AS m
    FROM t WHERE t.gap_min <= p_cap GROUP BY t.action_type
  ),
  task AS (
    SELECT t.employee, t.action_date, t.task_type,
           COUNT(DISTINCT t.unit_id) AS units, COUNT(*) AS n_actions, SUM(t.price) AS rub,
           SUM(COALESCE(CASE WHEN g.n >= 15 THEN g.m END, nt.m, 0)) AS norm_min,
           SUM(t.gap_min) FILTER (WHERE t.gap_min <= p_cap) AS active_min
    FROM t
    LEFT JOIN n_gt g ON g.group_name IS NOT DISTINCT FROM t.group_name AND g.action_type = t.action_type
    LEFT JOIN n_t nt ON nt.action_type = t.action_type
    GROUP BY t.employee, t.action_date, t.task_type
  ),
  day AS (
    SELECT a.employee, a.action_date,
           MIN(a.action_time) AS first_time, MAX(a.action_time) AS last_time,
           SUM(a.gap_min) FILTER (WHERE a.gap_min > p_cap) AS idle_min
    FROM a WHERE a.employee IN (SELECT DISTINCT t.employee FROM t)
    GROUP BY a.employee, a.action_date
  ),
  sched AS (
    SELECT w.employee, w.work_date, w.shift_start, w.shift_end
    FROM work_schedule w
    WHERE w.work_date BETWEEN p_from AND p_to
      AND w.employee IN (SELECT DISTINCT t.employee FROM t)
  ),
  days AS (
    SELECT COALESCE(d.employee, s.employee) AS employee, COALESCE(d.action_date, s.work_date) AS work_date,
           s.shift_start, s.shift_end, d.first_time, d.last_time, d.idle_min
    FROM day d
    FULL JOIN sched s ON s.employee = d.employee AND s.work_date = d.action_date
  )
  SELECT ds.employee, ds.work_date, k.task_type,
         COALESCE(k.units, 0), COALESCE(k.n_actions, 0), COALESCE(k.rub, 0),
         ROUND(COALESCE(k.norm_min, 0), 1), ROUND(COALESCE(k.active_min, 0), 1),
         ds.shift_start, ds.shift_end, ds.first_time, ds.last_time, ROUND(COALESCE(ds.idle_min, 0), 1)
  FROM days ds
  LEFT JOIN task k ON k.employee = ds.employee AND k.action_date = ds.work_date
  ORDER BY 1, 2, 3;
$$;

GRANT EXECUTE ON FUNCTION task_actions(DATE, DATE) TO anon;
GRANT EXECUTE ON FUNCTION get_task_action_types(DATE, DATE) TO anon;
GRANT EXECUTE ON FUNCTION get_task_norms(DATE, DATE, INT) TO anon;
GRANT EXECUTE ON FUNCTION get_task_daily(DATE, DATE, INT) TO anon;
