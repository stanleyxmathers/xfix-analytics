-- ============================================================
-- XFIX Analytics — командировки для планирования.
-- Инструмент командировок (Mini App, n8n → xfix-api) присылает командировки сюда:
--
--   POST https://<project>.supabase.co/rest/v1/rpc/api_push_trips
--   apikey: <anon key>
--   Content-Type: application/json
--   {"p_token": "<токен>", "p_trips": [ {trip}, ... ]}
--
-- trip — объект командировки как в /fm/create-trip и /miniapp/admin/trips:
--   fm_trip_id (или trip_id из FM), trip_number, title, status, date_from, date_to,
--   courier_name, courier_fm_login, escort_name, devices_count, equipment,
--   routes: [{seq, country, city, partner}]
-- Повторная отправка той же командировки (по fm_trip_id) заменяет её. Отменённую
-- присылать со status = 'cancelled' — в план она не попадает.
--
-- Токен (в SQL Editor Supabase):
--   INSERT INTO api_tokens(name) VALUES ('trips') RETURNING token;
--
-- Прогнать ПОСЛЕ supabase_api_shifts.sql (там api_tokens) — идемпотентно.
-- ============================================================

CREATE TABLE IF NOT EXISTS plan_trips (
  fm_trip_id       TEXT PRIMARY KEY,
  trip_number      TEXT,
  title            TEXT,
  status           TEXT NOT NULL DEFAULT 'active',
  date_from        DATE NOT NULL,
  date_to          DATE NOT NULL,
  courier_name     TEXT,
  courier_fm_login TEXT,
  escort_name      TEXT,
  devices_count    INT,
  equipment        TEXT,
  routes           JSONB NOT NULL DEFAULT '[]',   -- [{seq, country, city, partner}]
  updated_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_plan_trips_dates ON plan_trips(date_from, date_to);
ALTER TABLE plan_trips ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON plan_trips FROM anon, authenticated;

-- Приём командировок от инструмента командировок. Возвращает число сохранённых.
DROP FUNCTION IF EXISTS api_push_trips(TEXT, JSONB);
CREATE OR REPLACE FUNCTION api_push_trips(p_token TEXT, p_trips JSONB)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count INT;
BEGIN
  IF p_token IS NULL OR NOT EXISTS (SELECT 1 FROM api_tokens t WHERE t.token = p_token) THEN
    RAISE EXCEPTION 'invalid token' USING ERRCODE = '28000';
  END IF;
  IF jsonb_typeof(p_trips) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_trips: array required' USING ERRCODE = '22023';
  END IF;
  INSERT INTO plan_trips(fm_trip_id, trip_number, title, status, date_from, date_to, courier_name,
                         courier_fm_login, escort_name, devices_count, equipment, routes, updated_at)
  SELECT COALESCE(NULLIF(t->>'fm_trip_id', ''), t->>'trip_id'),
         NULLIF(t->>'trip_number', ''), NULLIF(t->>'title', ''),
         COALESCE(NULLIF(t->>'status', ''), 'active'),
         (t->>'date_from')::date, COALESCE(NULLIF(t->>'date_to', ''), t->>'date_from')::date,
         NULLIF(t->>'courier_name', ''), NULLIF(t->>'courier_fm_login', ''), NULLIF(t->>'escort_name', ''),
         NULLIF(t->>'devices_count', '')::numeric::int, NULLIF(t->>'equipment', ''),
         CASE WHEN jsonb_typeof(t->'routes') = 'array' THEN t->'routes' ELSE '[]'::jsonb END,
         NOW()
  FROM jsonb_array_elements(p_trips) t
  WHERE COALESCE(NULLIF(t->>'fm_trip_id', ''), t->>'trip_id') IS NOT NULL
    AND NULLIF(t->>'date_from', '') IS NOT NULL
  ON CONFLICT (fm_trip_id) DO UPDATE SET
    trip_number = EXCLUDED.trip_number, title = EXCLUDED.title, status = EXCLUDED.status,
    date_from = EXCLUDED.date_from, date_to = EXCLUDED.date_to, courier_name = EXCLUDED.courier_name,
    courier_fm_login = EXCLUDED.courier_fm_login, escort_name = EXCLUDED.escort_name,
    devices_count = EXCLUDED.devices_count, equipment = EXCLUDED.equipment,
    routes = EXCLUDED.routes, updated_at = NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION api_push_trips(TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_push_trips(TEXT, JSONB) TO anon;

-- Командировки, пересекающие диапазон, — для дашборда (без отменённых)
DROP FUNCTION IF EXISTS get_plan_trips(DATE, DATE);
CREATE OR REPLACE FUNCTION get_plan_trips(p_from DATE, p_to DATE)
RETURNS TABLE(fm_trip_id TEXT, trip_number TEXT, title TEXT, status TEXT, date_from DATE, date_to DATE,
              courier_name TEXT, courier_fm_login TEXT, escort_name TEXT, devices_count INT,
              equipment TEXT, routes JSONB, updated_at TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT fm_trip_id, trip_number, title, status, date_from, date_to, courier_name, courier_fm_login,
         escort_name, devices_count, equipment, routes, updated_at
  FROM plan_trips
  WHERE date_to >= p_from AND date_from <= p_to
    AND status NOT IN ('cancelled', 'canceled', 'отменена')
  ORDER BY date_from, fm_trip_id;
$$;
GRANT EXECUTE ON FUNCTION get_plan_trips(DATE, DATE) TO anon;
