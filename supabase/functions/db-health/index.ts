/**
 * XFIX Analytics — прокси к Supabase Metrics API (слой 1).
 *
 * Metrics API требует HTTP Basic с service_role key и не отдаёт CORS,
 * поэтому вызвать его из браузера нельзя. Функция держит ключ в секретах
 * проекта, тянет Prometheus-текст, отбирает нужные метрики и отдаёт JSON.
 *
 * Деплой:
 *   supabase secrets set XFIX_METRICS_KEY=<service_role key>
 *   supabase functions deploy db-health
 *
 * Секреты SUPABASE_URL / SUPABASE_ANON_KEY проставляются платформой сами.
 */

const METRICS_KEY = Deno.env.get("XFIX_METRICS_KEY") ?? "";
const PROJECT_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

/** Отдаём наружу только эти семейства — не весь дамп (он на сотни килобайт). */
const ALLOW = new Set([
  "pg_up",
  "pg_stat_database_numbackends",
  "pg_stat_database_xact_commit",
  "pg_stat_database_xact_rollback",
  "pg_stat_database_blks_hit",
  "pg_stat_database_blks_read",
  "pg_stat_database_deadlocks",
  "pg_stat_database_conflicts",
  "pg_settings_max_connections",
  "pg_database_size_bytes",
  "node_cpu_seconds_total",
  "node_memory_MemTotal_bytes",
  "node_memory_MemAvailable_bytes",
  "node_filesystem_size_bytes",
  "node_filesystem_avail_bytes",
  "node_load1",
  "pgbouncer_pools_server_active_connections",
  "pgbouncer_pools_client_waiting_connections",
  "supabase_realtime_connected_clients",
]);

type Sample = { name: string; labels: Record<string, string>; value: number };

/** Разбор Prometheus text exposition format. */
function parsePrometheus(text: string): Sample[] {
  const out: Sample[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;

    const braceAt = line.indexOf("{");
    const spaceAt = line.lastIndexOf(" ");
    if (spaceAt < 0) continue;

    const name = (braceAt > 0 && braceAt < spaceAt ? line.slice(0, braceAt) : line.slice(0, spaceAt)).trim();
    if (!ALLOW.has(name)) continue;

    const value = Number(line.slice(spaceAt + 1));
    if (!Number.isFinite(value)) continue;

    const labels: Record<string, string> = {};
    if (braceAt > 0) {
      const closeAt = line.lastIndexOf("}", spaceAt);
      for (const [, k, v] of line.slice(braceAt + 1, closeAt).matchAll(/(\w+)="([^"]*)"/g)) {
        labels[k] = v;
      }
    }
    out.push({ name, labels, value });
  }
  return out;
}

const sum = (s: Sample[], name: string, f: (l: Record<string, string>) => boolean = () => true) =>
  s.filter((x) => x.name === name && f(x.labels)).reduce((a, x) => a + x.value, 0);

const first = (s: Sample[], name: string) => s.find((x) => x.name === name)?.value ?? null;

/** Сводка. Счётчики отдаём сырыми — скорости фронт считает как дельту между опросами. */
function summarize(s: Sample[]) {
  const rootFs = (l: Record<string, string>) => l.mountpoint === "/" || l.mountpoint === "/data";
  const diskTotal = sum(s, "node_filesystem_size_bytes", rootFs);
  const diskFree = sum(s, "node_filesystem_avail_bytes", rootFs);
  const memTotal = first(s, "node_memory_MemTotal_bytes");
  const memFree = first(s, "node_memory_MemAvailable_bytes");
  const hit = sum(s, "pg_stat_database_blks_hit");
  const read = sum(s, "pg_stat_database_blks_read");

  return {
    pg_up: first(s, "pg_up"),
    connections: {
      active: sum(s, "pg_stat_database_numbackends"),
      max: first(s, "pg_settings_max_connections"),
    },
    counters: {
      xact_commit: sum(s, "pg_stat_database_xact_commit"),
      xact_rollback: sum(s, "pg_stat_database_xact_rollback"),
      deadlocks: sum(s, "pg_stat_database_deadlocks"),
      conflicts: sum(s, "pg_stat_database_conflicts"),
      cpu_idle_seconds: sum(s, "node_cpu_seconds_total", (l) => l.mode === "idle"),
      cpu_total_seconds: sum(s, "node_cpu_seconds_total"),
    },
    cache_hit_pct: hit + read > 0 ? +((hit / (hit + read)) * 100).toFixed(2) : null,
    disk: diskTotal
      ? { total: diskTotal, free: diskFree, used_pct: +(((diskTotal - diskFree) / diskTotal) * 100).toFixed(1) }
      : null,
    memory: memTotal
      ? { total: memTotal, free: memFree, used_pct: +(((memTotal - (memFree ?? 0)) / memTotal) * 100).toFixed(1) }
      : null,
    pgbouncer: {
      server_active: sum(s, "pgbouncer_pools_server_active_connections"),
      client_waiting: sum(s, "pgbouncer_pools_client_waiting_connections"),
    },
    realtime_clients: first(s, "supabase_realtime_connected_clients"),
  };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  if (!METRICS_KEY) {
    return json({ ok: false, error: "Не задан секрет XFIX_METRICS_KEY" }, 500);
  }

  const url = `${PROJECT_URL}/customer/v1/privileged/metrics`;
  const started = Date.now();

  try {
    const res = await fetch(url, {
      headers: { Authorization: "Basic " + btoa(`service_role:${METRICS_KEY}`) },
      signal: AbortSignal.timeout(10_000),
    });

    if (!res.ok) {
      return json({ ok: false, error: `Metrics API вернул ${res.status}`, detail: await res.text() }, 502);
    }

    const samples = parsePrometheus(await res.text());
    return json({
      ok: true,
      captured_at: new Date().toISOString(),
      fetch_ms: Date.now() - started,
      metrics: summarize(samples),
    });
  } catch (e) {
    return json({ ok: false, error: String(e instanceof Error ? e.message : e) }, 502);
  }
});
