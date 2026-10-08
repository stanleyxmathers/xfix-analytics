-- ============================================================
-- XFIX Analytics — график работы сотрудников
-- Рабочие дни (сотрудник × дата): ставятся вручную в дашборде или
-- импортируются из Excel-выгрузки Shifton. Используется в «Днях просадки»:
-- дни вне графика не считаются рабочими (действия, закрытые за сотрудника
-- другими, не дают ложную «низкую эффективность»), а смены без действий видны.
-- Если за месяц у сотрудника нет ни одной отметки — график считается
-- неизвестным и все дни с действиями остаются рабочими.
-- Прогнать ПЕРЕД supabase_functions.sql (идемпотентно).
-- ============================================================

CREATE TABLE IF NOT EXISTS work_schedule (
  employee   TEXT        NOT NULL,
  work_date  DATE        NOT NULL,
  source     TEXT        NOT NULL DEFAULT 'manual',   -- manual | import
  shift_start TIME,                                    -- плановое время смены (из Shifton);
  shift_end   TIME,                                    -- NULL — время не задано
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (employee, work_date)
);
ALTER TABLE work_schedule ADD COLUMN IF NOT EXISTS shift_start TIME;
ALTER TABLE work_schedule ADD COLUMN IF NOT EXISTS shift_end   TIME;
CREATE INDEX IF NOT EXISTS idx_work_schedule_date ON work_schedule(work_date);

ALTER TABLE work_schedule ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_all ON work_schedule;
CREATE POLICY anon_all ON work_schedule FOR ALL TO anon USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON work_schedule TO anon;

-- График месяца (для отрисовки сетки)
DROP FUNCTION IF EXISTS get_work_schedule(DATE);
CREATE OR REPLACE FUNCTION get_work_schedule(p_month DATE)
RETURNS TABLE(employee TEXT, work_date DATE, source TEXT, shift_start TIME, shift_end TIME)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee, work_date, source, shift_start, shift_end
  FROM work_schedule
  WHERE date_trunc('month', work_date) = date_trunc('month', p_month)
  ORDER BY employee, work_date;
$$;

-- Отметить/снять рабочий день одним кликом
CREATE OR REPLACE FUNCTION set_work_day(p_employee TEXT, p_date DATE, p_active BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_active THEN
    INSERT INTO work_schedule(employee, work_date) VALUES (p_employee, p_date)
    ON CONFLICT (employee, work_date) DO NOTHING;
  ELSE
    DELETE FROM work_schedule WHERE employee = p_employee AND work_date = p_date;
  END IF;
END;
$$;

-- Импорт: для сотрудников из файла (p_employees — все, включая тех, у кого
-- за период нет смен: отпуск) график в диапазоне [p_from, p_to] заменяется
-- целиком — удалённые в Shifton смены тоже пропадают.
-- p_rows: jsonb-массив {employee, work_date, shift_start?, shift_end?}
DROP FUNCTION IF EXISTS import_work_schedule(JSONB, DATE, DATE);
CREATE OR REPLACE FUNCTION import_work_schedule(p_rows JSONB, p_from DATE, p_to DATE, p_employees TEXT[])
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_count INT;
BEGIN
  DELETE FROM work_schedule
  WHERE work_date BETWEEN p_from AND p_to
    AND employee = ANY(p_employees);

  INSERT INTO work_schedule(employee, work_date, source, shift_start, shift_end)
  SELECT DISTINCT ON (r->>'employee', (r->>'work_date')::date)
    r->>'employee', (r->>'work_date')::date, 'import',
    NULLIF(r->>'shift_start', '')::time, NULLIF(r->>'shift_end', '')::time
  FROM jsonb_array_elements(p_rows) r
  WHERE (r->>'work_date')::date BETWEEN p_from AND p_to
  ON CONFLICT (employee, work_date) DO UPDATE SET
    source = EXCLUDED.source, shift_start = EXCLUDED.shift_start, shift_end = EXCLUDED.shift_end;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
