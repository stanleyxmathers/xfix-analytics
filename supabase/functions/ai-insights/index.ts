/**
 * XFIX Analytics — ИИ-выводы для еженедельного отчёта.
 *
 * Дашборд — статичная страница, держать в ней ключ Claude нельзя. Поэтому
 * факты (уже посчитанные на клиенте метрики) приходят сюда, функция зовёт
 * Claude, кладёт ответ в ai_insights и отдаёт его обратно. Запуск — только
 * по кнопке на слайде, без автоматического обновления.
 *
 * Деплой:
 *   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
 *   supabase functions deploy ai-insights
 *   + один раз прогнать supabase_ai_insights.sql
 *
 * SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY проставляются платформой сами.
 */
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient } from "npm:@supabase/supabase-js@2";

const MODEL = "claude-sonnet-5-5";
const MAX_FACTS_BYTES = 200_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const COMMON = `Ты — аналитик сервисного центра XFIX (ремонт техники Apple и Яндекс), помогаешь руководителю отдела диагностики.
Пиши по-русски, коротко и конкретно, без воды и общих советов. Опирайся только на переданные факты; цифры бери из них, не выдумывай.
Если данных мало для вывода — так и скажи в summary.`;

type Kind = {
  system: string;
  task: string;
  schema: Record<string, unknown>;
};

const str = { type: "string" };
const strList = { type: "array", items: str };
const obj = (properties: Record<string, unknown>) => ({
  type: "object",
  properties,
  required: Object.keys(properties),
  additionalProperties: false,
});

const KINDS: Record<string, Kind> = {
  issue_checks: {
    system: `${COMMON}
Тебе дают результаты «Проверки перед выдачей» (контроль качества перед выдачей устройства клиенту): по каждому сотруднику —
сколько его карточек проверили, сколько с ошибками и тексты ошибок с датами, за текущий период и за предыдущие недели.
Ищи повторяющиеся паттерны: одинаковые по смыслу ошибки (разные формулировки одной проблемы — один паттерн),
ошибки, которые повторяются из недели в неделю, и что у кого проседает. Отделяй разовые случаи от системных.`,
    task: "Найди повторяющиеся ошибки по каждому сотруднику и по отделу и дай выводы руководителю.",
    schema: obj({
      summary: { ...str, description: "2–3 предложения: главное по качеству за период" },
      employees: {
        type: "array",
        items: obj({
          employee: str,
          status: { type: "string", enum: ["ok", "watch", "problem"], description: "ok — ошибок нет или разовые; watch — есть повторы; problem — системная проблема" },
          weak_spot: { ...str, description: "Что проседает, одной фразой" },
          patterns: {
            type: "array",
            items: obj({
              pattern: { ...str, description: "Суть повторяющейся ошибки" },
              count: { type: "integer", description: "Сколько раз встречается в переданных данных" },
              recurring: { type: "boolean", description: "Повторяется в разные недели" },
            }),
          },
          recommendation: { ...str, description: "Что сделать с этим сотрудником" },
        }),
      },
      team_patterns: { ...strList, description: "Ошибки, которые повторяются у нескольких сотрудников" },
      actions: { ...strList, description: "3–5 конкретных шагов для руководителя" },
    }),
  },
  manager_kpi: {
    system: `${COMMON}
Тебе дают KPI руководителя отдела диагностики за месяц: схему (показатели, веса, шкалы «порог % → баллы», порог премии,
стоимость балла), текущие значения на дату последних данных, динамику показателей по неделям месяца, результаты прошлых
месяцев и выполнение личного плана заработка сотрудниками. Для показателей просрочки и ошибок меньше — лучше: шкала даёт баллы,
пока доля не выше порога ступени. План: доля сотрудников, не выполнивших личный план (с прогнозом по текущему темпу).
Оцени, сколько баллов реально набрать к концу месяца, пройдёт ли порог премии, и на каких показателях сделать упор:
где ближе всего следующая ступень шкалы и где риск потерять баллы. Считай, сколько действий нужно сделать без просрочки,
чтобы удержаться или подняться на ступень, исходя из оставшихся дней.`,
    task: "Дай прогноз KPI к концу месяца и скажи, на какие показатели сделать упор.",
    schema: obj({
      summary: { ...str, description: "2–3 предложения: где мы сейчас и чем закончится месяц" },
      forecast: obj({
        current_score: { type: "number" },
        expected_score: { type: "number", description: "Ожидаемый итог к концу месяца при текущем темпе" },
        best_case_score: { type: "number", description: "Итог, если сделать упор на рекомендованных показателях" },
        threshold_reachable: { type: "boolean" },
        confidence: { type: "string", enum: ["низкая", "средняя", "высокая"] },
        comment: str,
      }),
      focus: {
        type: "array",
        description: "Показатели по убыванию важности упора",
        items: obj({
          metric: str,
          priority: { type: "string", enum: ["высокий", "средний", "низкий"] },
          now: { ...str, description: "Текущее значение и баллы" },
          target: { ...str, description: "К какой ступени стремиться и сколько баллов это даёт" },
          reachable: { type: "boolean" },
          how: { ...str, description: "Что конкретно сделать, с цифрами" },
        }),
      },
      risks: strList,
      actions: { ...strList, description: "3–5 шагов на оставшиеся дни месяца" },
    }),
  },
};

async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ ok: false, error: "ANTHROPIC_API_KEY не задан в секретах Edge Functions" }, 500);

  let body: { kind?: string; scope?: string; facts?: unknown };
  try { body = await req.json(); } catch { return json({ ok: false, error: "Ожидался JSON" }, 400); }
  const kind = KINDS[body.kind ?? ""];
  const scope = String(body.scope ?? "").slice(0, 200);
  if (!kind || !scope || body.facts == null) return json({ ok: false, error: "Нужны kind, scope и facts" }, 400);
  const factsText = JSON.stringify(body.facts);
  if (factsText.length > MAX_FACTS_BYTES) return json({ ok: false, error: "Слишком много данных для анализа" }, 413);

  const client = new Anthropic({ apiKey });
  let msg;
  try {
    msg = await client.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system: kind.system,
      messages: [{ role: "user", content: `${kind.task}\n\nФакты (JSON):\n${factsText}` }],
      output_config: { format: { type: "json_schema", schema: kind.schema } },
    });
  } catch (e) {
    if (e instanceof Anthropic.AuthenticationError) return json({ ok: false, error: "Неверный ANTHROPIC_API_KEY" }, 502);
    if (e instanceof Anthropic.RateLimitError) return json({ ok: false, error: "Лимит запросов Claude — попробуйте через минуту" }, 429);
    if (e instanceof Anthropic.APIError) return json({ ok: false, error: `Claude: ${e.message}` }, 502);
    throw e;
  }

  if (msg.stop_reason === "refusal") return json({ ok: false, error: "Claude отказался отвечать на этот запрос" }, 502);
  if (msg.stop_reason === "max_tokens") return json({ ok: false, error: "Ответ Claude обрезан — слишком много данных" }, 502);
  const text = msg.content.map((b) => (b.type === "text" ? b.text : "")).join("");
  let result: unknown;
  try { result = JSON.parse(text); } catch { return json({ ok: false, error: "Claude вернул не JSON" }, 502); }

  const row = {
    kind: body.kind,
    scope,
    result,
    model: msg.model,
    facts_hash: await sha256(factsText),
    usage: msg.usage,
    created_at: new Date().toISOString(),
  };
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await sb.from("ai_insights").upsert(row, { onConflict: "kind,scope" });
  // не сохранили (не прогнан SQL) — вывод всё равно показываем
  return json({ ok: true, ...row, saved: !error, save_error: error?.message ?? null });
});
