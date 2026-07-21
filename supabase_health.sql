-- ============================================================
-- XFIX Analytics — мониторинг состояния БД (слой 2)
-- Журнал ошибок фронта + снимок здоровья Postgres.
-- Прогнать целиком в Supabase SQL Editor после supabase_schema.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Журнал ошибок
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app_error_log (
  id       BIGSERIAL PRIMARY KEY,
  ts       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  source   TEXT        NOT NULL DEFAULT 'dashboard',  -- dashboard | edge | db
  op       TEXT,                                      -- имя RPC/таблицы, где упало
  code     TEXT,                                      -- SQLSTATE или код PostgREST
  message  TEXT        NOT NULL,
  ctx      JSONB       NOT NULL DEFAULT '{}'::jsonb   -- параметры вызова, страница, UA
);

CREATE INDEX IF NOT EXISTS idx_app_error_log_ts  ON app_error_log(ts DESC);
CREATE INDEX IF NOT EXISTS idx_app_error_log_op  ON app_error_log(op);

COMMENT ON TABLE app_error_log IS
  'Ошибки выполнения запросов дашборда. Пишется только через log_client_error(), читается через get_error_log().';

-- ------------------------------------------------------------
-- 2. Запись ошибки (единственный путь записи для anon)
--    SECURITY DEFINER: anon не получает прямых прав на таблицу,
--    поэтому не может ни читать чужие записи, ни чистить журнал.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION log_client_error(
  p_op      TEXT,
  p_code    TEXT DEFAULT NULL,
  p_message TEXT DEFAULT '',
  p_ctx     JSONB DEFAULT '{}'::jsonb,
  p_source  TEXT DEFAULT 'dashboard'
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  INSERT INTO app_error_log (source, op, code, message, ctx)
  VALUES (
    LEFT(COALESCE(p_source, 'dashboard'), 32),
    LEFT(p_op, 200),
    LEFT(p_code, 64),
    LEFT(COALESCE(p_message, ''), 4000),   -- обрезаем: журнал не должен раздуть БД
    COALESCE(p_ctx, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  -- Ретеншн 30 дней. Чистим вероятностно, чтобы не платить за это на каждом вызове.
  IF random() < 0.01 THEN
    DELETE FROM app_error_log WHERE ts < NOW() - INTERVAL '30 days';
  END IF;

  RETURN v_id;
END;
$$;

-- ------------------------------------------------------------
-- 3. Чтение журнала
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_error_log(
  p_limit  INTEGER DEFAULT 50,
  p_hours  INTEGER DEFAULT 168      -- 7 дней
) RETURNS TABLE (
  id BIGINT, ts TIMESTAMPTZ, source TEXT, op TEXT, code TEXT, message TEXT, ctx JSONB
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT e.id, e.ts, e.source, e.op, e.code, e.message, e.ctx
  FROM app_error_log e
  WHERE e.ts > NOW() - (p_hours || ' hours')::INTERVAL
  ORDER BY e.ts DESC
  LIMIT LEAST(COALESCE(p_limit, 50), 500);
$$;

-- Сводка «где болит»: топ операций по числу ошибок
CREATE OR REPLACE FUNCTION get_error_summary(p_hours INTEGER DEFAULT 24)
RETURNS TABLE (op TEXT, code TEXT, cnt BIGINT, last_ts TIMESTAMPTZ, last_message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT e.op,
         e.code,
         COUNT(*)                                        AS cnt,
         MAX(e.ts)                                       AS last_ts,
         (ARRAY_AGG(e.message ORDER BY e.ts DESC))[1]    AS last_message
  FROM app_error_log e
  WHERE e.ts > NOW() - (p_hours || ' hours')::INTERVAL
  GROUP BY e.op, e.code
  ORDER BY cnt DESC, last_ts DESC
  LIMIT 20;
$$;

-- ------------------------------------------------------------
-- 4. Снимок здоровья БД
--    Всё, что видно изнутри Postgres без Metrics API.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION db_health_snapshot()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_db      RECORD;
  v_maxconn INTEGER;
  v_result  JSONB;
BEGIN
  SELECT numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
         deadlocks, conflicts, temp_files, temp_bytes, stats_reset
    INTO v_db
  FROM pg_stat_database
  WHERE datname = current_database();

  v_maxconn := current_setting('max_connections')::INTEGER;

  v_result := jsonb_build_object(
    'ok',                TRUE,
    'captured_at',       NOW(),
    'database',          current_database(),
    'version',           current_setting('server_version'),
    'started_at',        pg_postmaster_start_time(),
    'uptime_seconds',    EXTRACT(EPOCH FROM (NOW() - pg_postmaster_start_time()))::BIGINT,
    'db_size_bytes',     pg_database_size(current_database()),

    'connections', jsonb_build_object(
      'active',   v_db.numbackends,
      'max',      v_maxconn,
      'used_pct', ROUND(v_db.numbackends::NUMERIC / NULLIF(v_maxconn, 0) * 100, 1)
    ),

    'transactions', jsonb_build_object(
      'commits',      v_db.xact_commit,
      'rollbacks',    v_db.xact_rollback,
      -- доля откатов: устойчивый рост = запросы валятся
      'rollback_pct', ROUND(v_db.xact_rollback::NUMERIC
                            / NULLIF(v_db.xact_commit + v_db.xact_rollback, 0) * 100, 2)
    ),

    'cache', jsonb_build_object(
      'blks_hit',  v_db.blks_hit,
      'blks_read', v_db.blks_read,
      -- < 95% на прогретой базе = не хватает памяти либо нет индекса
      'hit_pct',   ROUND(v_db.blks_hit::NUMERIC
                          / NULLIF(v_db.blks_hit + v_db.blks_read, 0) * 100, 2)
    ),

    'problems', jsonb_build_object(
      'deadlocks',  v_db.deadlocks,
      'conflicts',  v_db.conflicts,
      'temp_files', v_db.temp_files,
      'temp_bytes', v_db.temp_bytes
    ),

    'stats_reset', v_db.stats_reset,

    'errors', (
      SELECT jsonb_build_object(
        'last_1h',  COUNT(*) FILTER (WHERE ts > NOW() - INTERVAL '1 hour'),
        'last_24h', COUNT(*) FILTER (WHERE ts > NOW() - INTERVAL '24 hours'),
        'last_7d',  COUNT(*),
        'last_ts',  MAX(ts)
      )
      FROM app_error_log WHERE ts > NOW() - INTERVAL '7 days'
    ),

    'data', (
      SELECT jsonb_build_object(
        'uploads',        (SELECT COUNT(*) FROM uploads),
        'actions',        (SELECT COUNT(*) FROM actions),
        'services',       (SELECT COUNT(*) FROM services),
        'last_week',      (SELECT MAX(report_week)  FROM uploads),
        'last_upload_at', (SELECT MAX(upload_date)  FROM uploads)
      )
    ),

    'tables', (
      SELECT COALESCE(jsonb_agg(t ORDER BY t.total_bytes DESC), '[]'::jsonb)
      FROM (
        SELECT c.relname                                          AS name,
               pg_total_relation_size(c.oid)                      AS total_bytes,
               COALESCE(s.n_live_tup, 0)                          AS live_rows,
               COALESCE(s.n_dead_tup, 0)                          AS dead_rows,
               GREATEST(s.last_autovacuum, s.last_vacuum)         AS last_vacuum
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
        WHERE n.nspname = 'public' AND c.relkind = 'r'
      ) t
    )
  );

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  -- Снимок здоровья не должен сам стать источником падения дашборда
  RETURN jsonb_build_object('ok', FALSE, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$$;

-- ------------------------------------------------------------
-- 5. Топ медленных запросов (если включён pg_stat_statements)
--    Динамический SQL: функция создаётся даже когда расширения нет.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION db_slow_queries(p_limit INTEGER DEFAULT 10)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
-- extensions: в Supabase pg_stat_statements живёт именно в этой схеме
SET search_path = public, extensions, pg_catalog
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
    RETURN jsonb_build_object('available', FALSE,
                              'hint', 'CREATE EXTENSION pg_stat_statements; (Database → Extensions)');
  END IF;

  EXECUTE format($q$
    SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM (
      SELECT LEFT(query, 300)          AS query,
             calls,
             ROUND(total_exec_time)    AS total_ms,
             ROUND(mean_exec_time, 1)  AS mean_ms,
             ROUND(max_exec_time, 1)   AS max_ms,
             rows
      FROM pg_stat_statements
      WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
        AND query NOT LIKE '%%pg_stat_statements%%'
      ORDER BY mean_exec_time DESC
      LIMIT %s
    ) x
  $q$, GREATEST(LEAST(COALESCE(p_limit, 10), 50), 1))
  INTO v_result;

  RETURN jsonb_build_object('available', TRUE, 'queries', v_result);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('available', FALSE, 'error', SQLERRM);
END;
$$;

-- ------------------------------------------------------------
-- 6. Права
--    Таблица журнала анониму напрямую НЕ доступна — только через функции.
-- ------------------------------------------------------------
ALTER TABLE app_error_log ENABLE ROW LEVEL SECURITY;
-- Политик нет: RLS без политик = прямой доступ anon закрыт полностью.
-- SECURITY DEFINER-функции ниже работают от владельца и RLS обходят.

REVOKE ALL ON app_error_log FROM anon, authenticated;

GRANT EXECUTE ON FUNCTION log_client_error(TEXT, TEXT, TEXT, JSONB, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION get_error_log(INTEGER, INTEGER)                 TO anon;
GRANT EXECUTE ON FUNCTION get_error_summary(INTEGER)                      TO anon;
GRANT EXECUTE ON FUNCTION db_health_snapshot()                            TO anon;
GRANT EXECUTE ON FUNCTION db_slow_queries(INTEGER)                        TO anon;
