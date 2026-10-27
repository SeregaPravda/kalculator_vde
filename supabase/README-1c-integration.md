# API для інтеграції 1С → Промавтоматика (калькулятор КП)

Напрямок один: **1С надсилає документи в наш сервіс**. Сервіс до 1С не звертається і нічого не запитує.

Один HTTP-запит — один документ цілком, разом із позиціями. Доступу до бази даних не потрібно: розробник працює тільки з обліковим записом і двома методами.

---

## 1. Доступи

| Параметр | Значення |
|---|---|
| Базова адреса | `https://ohnghdnixulnvrvcapgf.supabase.co` |
| Заголовок `apikey` | `sb_publishable_BbdzYMCW4CbQvAJ_FM1_fg_Su9xq7Tc` |
| Логін | `integration.1c@pa.ua` |
| Пароль | передається окремо |

Ключ `apikey` публічний, він потрібен у кожному запиті. Пароль зберігати лише в налаштуваннях обміну 1С.

---

## 2. Авторизація

```http
POST /auth/v1/token?grant_type=password
apikey: <apikey>
Content-Type: application/json

{ "email": "integration.1c@pa.ua", "password": "<пароль>" }
```

Відповідь містить `access_token` (діє 3600 секунд) і `refresh_token`.

Далі в кожному запиті: `Authorization: Bearer <access_token>`.

Оновлення токена, якщо обмін працює довше за годину:

```http
POST /auth/v1/token?grant_type=refresh_token
apikey: <apikey>
Content-Type: application/json

{ "refresh_token": "<refresh_token>" }
```

Якщо документи надсилаються рідко, простіше логінитись перед кожним надсиланням.

---

## 3. Метод: надіслати документ

```http
POST /rest/v1/rpc/ingest_1c_doc
apikey: <apikey>
Authorization: Bearer <access_token>
Content-Type: application/json

{ "p_payload": { ... документ ... } }
```

Тіло документа:

```json
{
  "doc_id": "505939",
  "doc_type": "spec",
  "doc_date": "2026-09-02",
  "counterparty": "ТОВ «Приклад»",
  "manager": "Вельгус",
  "total": 176973.30,
  "currency": "UAH",
  "note": "",
  "items": [
    {
      "line_no": 1,
      "item_code": "BAT-SE-F16",
      "item_name": "Акумуляторна батарея DEYE SE-F16-С LiFePO4 LV 51.2V 314Ah 16kWh",
      "unit": "шт",
      "qty": 1,
      "price": 94210.50,
      "amount": 94210.50
    }
  ]
}
```

### Поля шапки

| Поле | Тип | Обов'язкове | Опис |
|---|---|---|---|
| `doc_id` | рядок | **так** | номер документа в 1С, унікальний ключ |
| `doc_type` | рядок | ні | `spec`, `invoice`, `price`, `order`. За замовчуванням `spec` |
| `doc_date` | `YYYY-MM-DD` | ні | дата документа |
| `counterparty` | рядок | ні | контрагент |
| `manager` | рядок | ні | менеджер у 1С |
| `total` | число | ні | сума документа |
| `currency` | рядок | ні | за замовчуванням `UAH` |
| `note` | рядок | ні | примітка |
| `items` | масив | ні | позиції, див. нижче |

### Поля позиції

| Поле | Тип | Обов'язкове | Опис |
|---|---|---|---|
| `item_name` | рядок | **так** | найменування |
| `line_no` | ціле | ні | номер рядка, інакше проставиться за порядком |
| `item_code` | рядок | ні | артикул або код номенклатури |
| `unit` | рядок | ні | одиниця виміру |
| `qty` | число | ні | кількість, за замовчуванням 1 |
| `price` | число | ні | ціна за одиницю |
| `amount` | число | ні | сума рядка |

Будь-які додаткові поля можна передавати, вони збережуться повністю і не спричинять помилки.

### Успішна відповідь

```json
{ "ok": true, "doc_id": "505939", "action": "created", "items": 12, "received_at": "2026-10-27T10:00:00+00:00" }
```

`action`: `created` — документ новий, `updated` — документ із таким `doc_id` уже був і його оновлено.

### Повторне надсилання

Безпечне. Той самий `doc_id` оновлює шапку, а позиції перезаписуються повністю: скільки прийшло, стільки й буде. Дублікатів не виникає, спеціальних прапорців не потрібно.

---

## 4. Метод: перевірити документ

```http
POST /rest/v1/rpc/ingest_1c_status
apikey: <apikey>
Authorization: Bearer <access_token>
Content-Type: application/json

{ "p_doc_id": "505939" }
```

```json
{ "found": true, "doc_id": "505939", "doc_type": "spec", "items": 12,
  "received_at": "...", "updated_at": "..." }
```

Якщо документа немає: `{ "found": false, "doc_id": "505939" }`.

---

## 5. Помилки

| Код | Текст | Причина |
|---|---|---|
| 401 | `invalid JWT` або порожньо | токен відсутній чи протермінований, потрібен новий логін |
| 403 | `forbidden: only service account may ingest` | запит пішов не під тим обліковим записом |
| 400 | `doc_id is required` | у документі немає `doc_id` |
| 400 | `items must be an array` | `items` передано не масивом |
| 400 | `item_name is required in item N` | у позиції N немає найменування |
| 400 | `payload too large (max 2 MB)` | документ більший за 2 МБ, розбити на частини |

---

## 6. Обмеження і правила

- Максимальний розмір документа: 2 МБ.
- Заголовок `Prefer: return=representation` **не додавати**: обліковий запис не має права читати дані, запит впаде.
- Обліковий запис може лише надсилати документи і перевіряти їх статус. Він не бачить ні таблиць, ні цін, ні комерційних пропозицій, і не може зайти у вебінтерфейс калькулятора.
- Таблиці на боці сервісу можуть змінюватись. Формат цього API при цьому лишається незмінним.

---

## 7. Приклади curl

```bash
TOKEN=$(curl -s -X POST "https://ohnghdnixulnvrvcapgf.supabase.co/auth/v1/token?grant_type=password" \
  -H "apikey: sb_publishable_BbdzYMCW4CbQvAJ_FM1_fg_Su9xq7Tc" \
  -H "Content-Type: application/json" \
  -d '{"email":"integration.1c@pa.ua","password":"ПАРОЛЬ"}' | jq -r .access_token)
```

```bash
curl -X POST "https://ohnghdnixulnvrvcapgf.supabase.co/rest/v1/rpc/ingest_1c_doc" \
  -H "apikey: sb_publishable_BbdzYMCW4CbQvAJ_FM1_fg_Su9xq7Tc" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_payload":{"doc_id":"505939","doc_type":"spec","items":[{"item_name":"Тест","qty":1}]}}'
```

---

## 8. Як перевірити себе

У репозиторії є колекція Postman `postman-1c-integration.json` і файл оточення `postman-1c-environment.json`. Імпортувати обидва, у змінній `password` вписати пароль, запустити колекцію. Усі перевірки мають бути зеленими: логін, створення документа, оновлення тим самим номером, статус, відмова без токена.
