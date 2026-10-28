-- ============================================================
-- ИИ-выводы еженедельного отчёта (слайды «Проверка перед выдачей»
-- и «KPI руководителя»). Выводы запрашиваются вручную кнопкой на слайде:
-- дашборд собирает факты → Edge Function ai-insights → Claude → ответ
-- сохраняется здесь и показывается всем, пока его не обновят.
-- Ключ Claude живёт только в секретах Edge Function (ANTHROPIC_API_KEY).
-- Прогнать целиком в Supabase SQL Editor (идемпотентно).
-- ============================================================

CREATE TABLE IF NOT EXISTS ai_insights (
  kind        TEXT        NOT NULL,         -- issue_checks | manager_kpi
  scope       TEXT        NOT NULL,         -- ключ периода / месяц 'YYYY-MM-01'
  result      JSONB       NOT NULL,         -- {summary, items[], actions[], ...}
  model       TEXT,
  facts_hash  TEXT,                         -- md5 входных фактов: видно, устарел ли вывод
  usage       JSONB,                        -- токены запроса
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (kind, scope)
);

-- Пишет только Edge Function (service_role); браузер читает через RPC.
ALTER TABLE ai_insights ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ai_insights FROM anon;

CREATE OR REPLACE FUNCTION get_ai_insight(p_kind TEXT, p_scope TEXT)
RETURNS TABLE(result JSONB, model TEXT, facts_hash TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT result, model, facts_hash, created_at
  FROM ai_insights WHERE kind = p_kind AND scope = p_scope;
$$;
GRANT EXECUTE ON FUNCTION get_ai_insight(TEXT, TEXT) TO anon;

-- Строки месяца для KPI по неделям: как get_kpi_month_rows, плюс понедельник
-- недели. Нужны ИИ-прогнозу — видно, как показатель меняется внутри месяца.
CREATE OR REPLACE FUNCTION get_kpi_month_rows_weekly(p_month DATE)
RETURNS TABLE(week DATE, employee TEXT, action_type TEXT, subgroup TEXT, group_name TEXT,
              is_corp SMALLINT, is_overdue SMALLINT, n BIGINT, price NUMERIC, last_date DATE)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT date_trunc('week', action_date)::date, employee::text, action_type::text, subgroup::text,
         group_name::text, is_corp, is_overdue, COUNT(*), SUM(price), MAX(action_date)
  FROM actions
  WHERE action_date >= p_month AND action_date < (p_month + INTERVAL '1 month')::date
  GROUP BY 1, 2, 3, 4, 5, 6, 7
  ORDER BY 1, 2, 3, 4, 5, 6, 7;
$$;
GRANT EXECUTE ON FUNCTION get_kpi_month_rows_weekly(DATE) TO anon;

-- Проверки перед выдачей за произвольный диапазон дат — история для ИИ-анализа
-- повторяющихся ошибок (несколько недель до текущего периода). Участники
-- карточки — как в get_issue_checks_p (supabase_issue_checks.sql).
CREATE OR REPLACE FUNCTION get_issue_checks_range(p_from DATE, p_to DATE)
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
  FROM issue_checks c
  WHERE c.check_date BETWEEN p_from AND p_to
  ORDER BY c.check_date, c.check_time;
$$;
GRANT EXECUTE ON FUNCTION get_issue_checks_range(DATE, DATE) TO anon;
