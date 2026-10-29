-- ============================================================
-- XFIX Analytics — API графика смен для внешних сервисов
-- Внешний сервис вызывает RPC Supabase с anon key + своим токеном:
--
--   POST https://<project>.supabase.co/rest/v1/rpc/api_shifts
--   apikey: <anon key>
--   Content-Type: application/json
--   {"p_token": "<токен>", "p_from": "2026-11-01", "p_to": "2026-11-30"}
--
-- Ответ — массив смен: employee, work_date, shift_start, shift_end, hours.
-- Необязательно: "p_employee": "Иванов Иван" — только один сотрудник.
-- Период — не больше 93 дней за запрос.
--
-- Выдать токен (в SQL Editor Supabase):
--   INSERT INTO api_tokens(name) VALUES ('crm') RETURNING token;
-- Отозвать:
--   DELETE FROM api_tokens WHERE name = 'crm';
--
-- Прогнать ПОСЛЕ supabase_schedule.sql (идемпотентно).
-- ============================================================

CREATE TABLE IF NOT EXISTS api_tokens (
  token      TEXT PRIMARY KEY DEFAULT replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  name       TEXT NOT NULL UNIQUE,                 -- кому выдан
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- Токены anon не видит: RLS включён, политик нет
ALTER TABLE api_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON api_tokens FROM anon, authenticated;

DROP FUNCTION IF EXISTS api_shifts(TEXT, DATE, DATE, TEXT);
CREATE OR REPLACE FUNCTION api_shifts(p_token TEXT, p_from DATE, p_to DATE, p_employee TEXT DEFAULT NULL)
RETURNS TABLE(employee TEXT, work_date DATE, shift_start TIME, shift_end TIME, hours NUMERIC)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_token IS NULL OR NOT EXISTS (SELECT 1 FROM api_tokens t WHERE t.token = p_token) THEN
    RAISE EXCEPTION 'invalid token' USING ERRCODE = '28000';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 92 THEN
    RAISE EXCEPTION 'p_from/p_to: period of 1..93 days required' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT s.employee, s.work_date, s.shift_start, s.shift_end,
         -- смена через полночь (22:00–06:00) — тоже положительные часы
         round(extract(epoch FROM (s.shift_end - s.shift_start
               + CASE WHEN s.shift_end <= s.shift_start THEN interval '24 hours' ELSE interval '0' END)) / 3600, 2)
  FROM work_schedule s
  WHERE s.work_date BETWEEN p_from AND p_to
    AND (p_employee IS NULL OR s.employee = p_employee)
  ORDER BY s.work_date, s.employee;
END;
$$;

REVOKE ALL ON FUNCTION api_shifts(TEXT, DATE, DATE, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_shifts(TEXT, DATE, DATE, TEXT) TO anon;
