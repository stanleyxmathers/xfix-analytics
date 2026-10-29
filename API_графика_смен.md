# API графика смен XFIX

Возвращает смены сотрудников за период: кто работает, в какой день и с какого по какое время.

## Доступ

Нужны три значения, их выдаёт администратор:

| Что | Пример |
|---|---|
| Адрес API | `https://<project>.supabase.co` |
| Ключ `apikey` | anon key проекта Supabase |
| Токен сервиса | строка из 64 символов, своя у каждого сервиса |

Храните токен и ключ на сервере. В браузерный код и в репозиторий их не кладите.

## Запрос

```
POST https://<project>.supabase.co/rest/v1/rpc/api_shifts
apikey: <anon key>
Content-Type: application/json
```

Тело запроса:

| Поле | Тип | Обязательно | Описание |
|---|---|---|---|
| `p_token` | string | да | токен сервиса |
| `p_from` | string `YYYY-MM-DD` | да | начало периода, включительно |
| `p_to` | string `YYYY-MM-DD` | да | конец периода, включительно |
| `p_employee` | string | нет | ФИО сотрудника в точности как в графике. Если поле не передать, придут все сотрудники |

Период может быть от 1 до 93 дней. Длинный период запрашивайте частями.

## Ответ

`200 OK`, массив смен, отсортированный по дате, а внутри даты по сотруднику:

```json
[
  {
    "employee": "Иванов Иван",
    "work_date": "2026-11-02",
    "shift_start": "09:00:00",
    "shift_end": "18:00:00",
    "hours": 9.00
  },
  {
    "employee": "Петров Пётр",
    "work_date": "2026-11-02",
    "shift_start": "22:00:00",
    "shift_end": "06:00:00",
    "hours": 8.00
  }
]
```

- **В ответ попадают только рабочие дни.** Если у сотрудника нет строки на дату, это выходной.
- **Время местное, без часового пояса.**
- **Ночная смена.** Если `shift_end` меньше `shift_start`, смена заканчивается на следующий день. Часы в `hours` для неё уже посчитаны правильно.
- **Время смены не задано.** Если день рабочий, но время не указано, `shift_start`, `shift_end` и `hours` приходят как `null`.
- **Пустой массив `[]`** означает, что смен за период нет.

## Ошибки

Ответ с ошибкой приходит в JSON вида `{"code": "...", "message": "..."}`.

| HTTP | `code` | `message` | Причина |
|---|---|---|---|
| 403 | `28000` | `invalid token` | неверный или отозванный токен |
| 400 | `22023` | `p_from/p_to: period of 1..93 days required` | нет дат, `p_to` раньше `p_from` или период длиннее 93 дней |
| 401 | — | — | нет заголовка `apikey` или неверный ключ |
| 404 | `PGRST202` | — | неверное имя функции или полей в теле запроса |

## Примеры

### curl

```bash
curl -X POST "https://<project>.supabase.co/rest/v1/rpc/api_shifts" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"p_token":"'"$XFIX_SHIFTS_TOKEN"'","p_from":"2026-11-01","p_to":"2026-11-30"}'
```

### JavaScript (Node 18+)

```js
const res = await fetch('https://<project>.supabase.co/rest/v1/rpc/api_shifts', {
  method: 'POST',
  headers: { apikey: process.env.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_token: process.env.XFIX_SHIFTS_TOKEN, p_from: '2026-11-01', p_to: '2026-11-30' }),
});
if (!res.ok) throw new Error(`${res.status}: ${(await res.json()).message}`);
const shifts = await res.json();
```

### Python

```python
import os, requests

r = requests.post(
    "https://<project>.supabase.co/rest/v1/rpc/api_shifts",
    headers={"apikey": os.environ["SUPABASE_ANON_KEY"]},
    json={"p_token": os.environ["XFIX_SHIFTS_TOKEN"], "p_from": "2026-11-01", "p_to": "2026-11-30"},
    timeout=15,
)
r.raise_for_status()
shifts = r.json()
```

## Рекомендации

- **Обновление.** График меняется, когда администратор загружает выгрузку из Shifton. Перезапрашивайте период целиком, например раз в час или раз в сутки, и заменяйте у себя смены за этот период: удалённые смены из ответа просто пропадают.
- **Привязка сотрудника.** Ключ сотрудника — поле `employee` (ФИО). Сопоставляйте его с вашей системой по этому полю.
