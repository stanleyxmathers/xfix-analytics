-- ============================================================
-- Проверка перед выдачей (ОКК) — слайд 9 еженедельного отчёта.
-- Выгрузка «Тип = Проверка перед выдачей» грузится отдельным файлом в
-- issue_checks; карточки сопоставляются с действиями из ранее загруженных
-- отчётов (actions.service_id), чтобы найти, чья это была работа.
-- Прогнать целиком в Supabase SQL Editor (идемпотентно).
-- ============================================================

CREATE TABLE IF NOT EXISTS issue_checks (
  check_id     BIGINT PRIMARY KEY,          -- "id" строки выгрузки
  check_date   DATE        NOT NULL,
  check_time   TIME,
  checker      TEXT,                        -- кто проверял (ФИО)
  service_id   BIGINT      NOT NULL,        -- "id сервис" — карточка
  passed       BOOLEAN     NOT NULL,        -- Группа: Пройдена / Ошибки
  comment      TEXT,
  vendor       TEXT,
  uploaded_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_issue_checks_date    ON issue_checks(check_date);
CREATE INDEX IF NOT EXISTS idx_issue_checks_service ON issue_checks(service_id);

ALTER TABLE issue_checks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS anon_all ON issue_checks;
CREATE POLICY anon_all ON issue_checks FOR ALL TO anon USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON issue_checks TO anon;

-- Проверки за даты периода + участники карточки из загруженных отчётов.
-- Участник = сотрудник с действиями по той же карточке не позже даты проверки,
-- кроме самого проверяющего и других проверок перед выдачей. Отсортированы по
-- заработку на карточке (больше — основной исполнитель), затем по последнему действию.
-- Выбор ответственного (с учётом состава отчёта) — на клиенте.
DROP FUNCTION IF EXISTS get_issue_checks_p(TEXT);
CREATE OR REPLACE FUNCTION get_issue_checks_p(p_period TEXT)
RETURNS TABLE(
  check_id BIGINT, check_date DATE, check_time TIME, checker TEXT,
  service_id BIGINT, passed BOOLEAN, comment TEXT, vendor TEXT,
  participants JSONB
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT c.check_id, c.check_date, c.check_time, c.checker,
         c.service_id, c.passed, c.comment, c.vendor,
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'employee', x.employee, 'department', x.department,
                    'price', x.price, 'actions', x.n, 'last_date', x.last_date)
                  ORDER BY x.price DESC, x.last_date DESC, x.employee)
           FROM (
             SELECT a.employee,
                    (array_agg(a.department ORDER BY a.action_date DESC))[1] AS department,
                    SUM(a.price) AS price, COUNT(*) AS n, MAX(a.action_date) AS last_date
             FROM actions a
             WHERE a.service_id = c.service_id
               AND a.action_date <= c.check_date
               AND a.employee IS DISTINCT FROM c.checker
               AND a.action_type IS DISTINCT FROM 'Проверка перед выдачей'
             GROUP BY a.employee
           ) x
         ), '[]'::jsonb) AS participants
  FROM periods p
  JOIN issue_checks c ON c.check_date BETWEEN p.date_from AND p.date_to
  WHERE p.period_key = p_period
  ORDER BY c.check_date, c.check_time;
$$;
GRANT EXECUTE ON FUNCTION get_issue_checks_p(TEXT) TO anon;
