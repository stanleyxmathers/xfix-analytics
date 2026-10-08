-- ============================================================
-- XFIX Analytics — Дежурства отдела диагностики
-- Дежурство = день, когда диагност занят поручениями (перемещение техники
-- и т.п.) вместо целевых действий. Оплата — 10% от суммы, заработанной
-- (actions.price) сотрудником в этот календарный день, по всем отчётам.
-- Прогнать целиком в Supabase SQL Editor (идемпотентно).
-- ============================================================

-- 1. Дни дежурств: сотрудник × дата. Проставляются вручную в дашборде.
CREATE TABLE IF NOT EXISTS duty_shifts (
  employee   TEXT        NOT NULL,
  duty_date  DATE        NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (employee, duty_date)
);
CREATE INDEX IF NOT EXISTS idx_duty_shifts_date ON duty_shifts(duty_date);

ALTER TABLE duty_shifts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_all ON duty_shifts;
CREATE POLICY anon_all ON duty_shifts FOR ALL TO anon USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON duty_shifts TO anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon;

-- ============================================================
-- RPC
-- ============================================================

-- Дежурства месяца (для отрисовки календаря отметок)
CREATE OR REPLACE FUNCTION get_duty_shifts(p_month DATE)
RETURNS TABLE(employee TEXT, duty_date DATE)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT employee, duty_date
  FROM duty_shifts
  WHERE date_trunc('month', duty_date) = date_trunc('month', p_month)
  ORDER BY employee, duty_date;
$$;

-- Проставить/снять отметку дежурства одним кликом
CREATE OR REPLACE FUNCTION set_duty_shift(p_employee TEXT, p_date DATE, p_active BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_active THEN
    INSERT INTO duty_shifts(employee, duty_date) VALUES (p_employee, p_date)
    ON CONFLICT (employee, duty_date) DO NOTHING;
  ELSE
    DELETE FROM duty_shifts WHERE employee = p_employee AND duty_date = p_date;
  END IF;
END;
$$;

-- Расчёт оплаты дежурств за месяц: 10% от заработанного (SUM actions.price)
-- сотрудником в день дежурства, по всем загруженным отчётам, покрывающим эту дату.
CREATE OR REPLACE FUNCTION report_duty_payouts(p_month DATE)
RETURNS TABLE(employee TEXT, duty_date DATE, day_earnings NUMERIC, payout NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    ds.employee,
    ds.duty_date,
    COALESCE(SUM(a.price), 0)              AS day_earnings,
    ROUND(COALESCE(SUM(a.price), 0) * 0.1, 2) AS payout
  FROM duty_shifts ds
  LEFT JOIN actions a ON a.employee = ds.employee AND a.action_date = ds.duty_date
  WHERE date_trunc('month', ds.duty_date) = date_trunc('month', p_month)
  GROUP BY ds.employee, ds.duty_date
  ORDER BY ds.employee, ds.duty_date;
$$;
