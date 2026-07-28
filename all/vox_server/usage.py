"""
Suerte / Aqbobek — учёт затрат на LLM (главный сервер).
──────────────────────────────────────────────────────────────────────────
Каждый вызов chat-модели OpenAI или DeepSeek возвращает блок `usage`. Здесь мы
кладём одну строку в SQLite (server/usage.db) и считаем стоимость по прайсу
($ за 1 000 000 токенов), который можно переопределить в config.json.

Нарастающие итоги нигде не дублируются: это всегда SELECT SUM(...), поэтому
рассинхрону взяться неоткуда.

ПРИМЕЧАНИЕ: Whisper (речь→текст) идёт в OpenAI отдельным эндпоинтом
/audio/transcriptions. Он тарифицируется по минутам аудио и токенов в ответе
не возвращает, поэтому в учёт затрат сюда не попадает — счёт за него виден
только в личном кабинете OpenAI.

Модуль — единственный владелец хранилища затрат: про HTTP он ничего не знает.
"""

import os
import re
import sqlite3
import threading
import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_PATH = os.path.join(HERE, "schema.sql")

# Пути читаются в момент вызова, а не захватываются — так их подменяют тесты.
DB_PATH = os.environ.get("USAGE_DB") or os.path.join(HERE, "usage.db")
TXT_PATH = os.environ.get("USAGE_TXT") or os.path.join(HERE, "token_usage.txt")

_lock = threading.Lock()
_conn = None
_initialized = False

# Прайс OpenAI, $ за 1 000 000 токенов. Актуальные цены — на openai.com/pricing,
# переопределяются в config.json -> "openai_prices".
DEFAULT_PRICES = {
    "gpt-4o":       {"input": 2.50, "output": 10.00},
    "gpt-4o-mini":  {"input": 0.15, "output": 0.60},
    "gpt-4.1":      {"input": 2.00, "output": 8.00},
    "gpt-4-turbo":  {"input": 10.00, "output": 30.00},
}

# Прайс DeepSeek, $ за 1 000 000 токенов (cache miss).
# Переопределяется в config.json -> "deepseek_prices".
DEFAULT_DEEPSEEK_PRICES = {
    "deepseek-chat":     {"input": 0.27, "output": 1.10},
    "deepseek-reasoner": {"input": 0.55, "output": 2.19},
}

_INSERT_SQL = (
    "INSERT INTO llm_calls (ts, day, provider, model, prompt_tokens, completion_tokens,"
    " total_tokens, cost_usd, priced, endpoint) VALUES (?,?,?,?,?,?,?,?,?,?)"
)


# ───────────────────────────── СОЕДИНЕНИЕ ─────────────────────────────
def _raw_connect():
    """Соединение без инициализации схемы — только для init_db, иначе рекурсия."""
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
    return _conn


def _connect():
    """Рабочее соединение: при первом обращении применяет схему и делает бэкфилл."""
    if not _initialized:
        init_db()
    return _raw_connect()


def _get_meta(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def _set_meta(conn, key, value):
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, str(value)))


def init_db():
    """Применить схему и, при первом запуске, перелить token_usage.txt. Идемпотентна."""
    global _initialized
    if _initialized:
        return {"imported": 0, "skipped": 0}
    conn = _raw_connect()
    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        conn.executescript(f.read())
    _set_meta(conn, "schema_version", "1")
    conn.commit()
    _initialized = True
    return _backfill_from_txt(conn)


# ───────────────────────────── БЭКФИЛЛ ИЗ token_usage.txt ─────────────────────────────
# Старый формат строки:
#   2026-07-01 10:00:00 | openai:gpt-4o | prompt=1000 | completion=500 | total=1500 | $0.0075 | ИТОГО: ...
# Провайдера в самых первых строках могло не быть — тогда вторая колонка это просто модель.
_TXT_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| ([^|]+?) \| "
    r"prompt=(\d+) \| completion=(\d+) \| total=(\d+) \| ([^|]+?) \|"
)


def _parse_txt_line(line):
    """Строка token_usage.txt -> кортеж для _INSERT_SQL, либо None, если не разобралась."""
    m = _TXT_RE.match(line)
    if not m:
        return None
    ts, raw_model, prompt, completion, total, cost_raw = m.groups()

    # Имена моделей сами содержат двоеточие (qwen2.5-coder:14b), поэтому префикс
    # считаем провайдером только если это действительно известный провайдер.
    head, _, tail = raw_model.strip().partition(":")
    if head in ("openai", "deepseek") and tail:
        provider, model = head, tail
    else:
        provider, model = "openai", raw_model.strip()

    cost_raw = cost_raw.strip()
    if cost_raw.startswith("$?"):
        cost, priced = 0.0, 0
    else:
        try:
            cost, priced = float(cost_raw.lstrip("$")), 1
        except ValueError:
            return None

    return (ts, ts[:10], provider, model,
            int(prompt), int(completion), int(total), round(cost, 6), priced, None)


def _backfill_from_txt(conn):
    """Один раз перелить token_usage.txt в базу. Всё или ничего — одна транзакция."""
    if _get_meta(conn, "backfilled_txt"):
        return {"imported": 0, "skipped": 0}

    rows, skipped = [], 0
    if os.path.exists(TXT_PATH):
        with open(TXT_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parsed = _parse_txt_line(line)
                if parsed is None:
                    skipped += 1
                    continue
                rows.append(parsed)

    try:
        with conn:                        # commit при выходе, rollback при исключении
            conn.executemany(_INSERT_SQL, rows)
            _set_meta(conn, "backfilled_txt", datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    except Exception as e:
        print("[usage] бэкфилл не удался, повторим при следующем старте:", e)
        return {"imported": 0, "skipped": skipped}

    if rows or skipped:
        print("[usage] бэкфилл token_usage.txt: перенесено {}, пропущено {}".format(len(rows), skipped))
    return {"imported": len(rows), "skipped": skipped}


# ───────────────────────────── ЗАПИСЬ ВЫЗОВА ─────────────────────────────
def _price_for(model, prices):
    """Ищем цену по точному совпадению или по префиксу имени модели."""
    if model in prices:
        return prices[model]
    for key, val in prices.items():
        if model.startswith(key):
            return val
    return None


def record_usage(provider, model, usage, prices=None, when=None, endpoint=None):
    """Записать один вызов ЛЮБОГО провайдера (openai/deepseek/...).

    `usage` — dict вида {prompt_tokens, completion_tokens, total_tokens} (может быть None).
    `endpoint` — откуда пришёл вызов: 'router' | 'command' | 'ocr-template' |
    'template-enrich' (обогащение шаблона в навык, один раз за шаблон) |
    'skill-match' (арбитр при ничьей) | 'skill-slots' (заполнение полей).
    Возвращает стоимость вызова в долларах (0.0, если цены для модели нет).
    """
    if not usage:
        return 0.0
    if prices is None:
        prices = DEFAULT_DEEPSEEK_PRICES if provider == "deepseek" else DEFAULT_PRICES

    prompt = int(usage.get("prompt_tokens", 0) or 0)
    completion = int(usage.get("completion_tokens", 0) or 0)
    total = int(usage.get("total_tokens", prompt + completion) or (prompt + completion))

    p = _price_for(model, prices)
    cost = (prompt / 1_000_000 * p["input"] + completion / 1_000_000 * p["output"]) if p else 0.0
    dt = when or datetime.datetime.now()

    with _lock:
        conn = _connect()
        conn.execute(_INSERT_SQL, (
            dt.strftime("%Y-%m-%d %H:%M:%S"), dt.strftime("%Y-%m-%d"),
            provider, model, prompt, completion, total,
            round(cost, 6), 1 if p else 0, endpoint,
        ))
        conn.commit()
    return cost


# ───────────────────────────── ЧТЕНИЕ / АГРЕГАТЫ ─────────────────────────────
_SUM_COLS = (
    "COUNT(*) AS calls,"
    " COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,"
    " COALESCE(SUM(completion_tokens), 0) AS completion_tokens,"
    " COALESCE(SUM(total_tokens), 0) AS total_tokens,"
    " COALESCE(SUM(cost_usd), 0.0) AS cost_usd"
)
_SUM_KEYS = ("calls", "prompt_tokens", "completion_tokens", "total_tokens", "cost_usd")

MAX_CHART_DAYS = 365   # «всё время» на графике всё равно ограничиваем — иначе частокол


def _period_start(days):
    """Первый день периода (ISO) либо None для «всё время». days=1 — только сегодня."""
    if not days:
        return None
    return (datetime.date.today() - datetime.timedelta(days=int(days) - 1)).isoformat()


def _agg(conn, where="", params=()):
    row = conn.execute("SELECT {} FROM llm_calls {}".format(_SUM_COLS, where), params).fetchone()
    out = {k: row[k] for k in _SUM_KEYS}
    out["cost_usd"] = round(out["cost_usd"], 6)
    return out


def _period_clause(days):
    start = _period_start(days)
    return ("WHERE day >= ?", (start,)) if start else ("", ())


def _by_day(conn, days):
    start = _period_start(days)
    today = datetime.date.today()
    if start is None:
        first = conn.execute("SELECT MIN(day) AS d FROM llm_calls").fetchone()["d"]
        if not first:
            return []
        start_d = max(datetime.date.fromisoformat(first),
                      today - datetime.timedelta(days=MAX_CHART_DAYS - 1))
    else:
        start_d = datetime.date.fromisoformat(start)

    rows = conn.execute(
        "SELECT day, COUNT(*) AS calls, COALESCE(SUM(total_tokens), 0) AS total_tokens,"
        " COALESCE(SUM(cost_usd), 0.0) AS cost_usd"
        " FROM llm_calls WHERE day >= ? GROUP BY day",
        (start_d.isoformat(),)
    ).fetchall()
    have = {r["day"]: r for r in rows}

    out, cur = [], start_d
    while cur <= today:
        key = cur.isoformat()
        r = have.get(key)
        out.append({
            "day": key,
            "calls": r["calls"] if r else 0,
            "total_tokens": r["total_tokens"] if r else 0,
            "cost_usd": round(r["cost_usd"], 6) if r else 0.0,
        })
        cur += datetime.timedelta(days=1)
    return out


def _by_model(conn, days):
    where, params = _period_clause(days)
    rows = conn.execute(
        "SELECT provider, model, {}, MIN(priced) AS priced FROM llm_calls {}"
        " GROUP BY provider, model ORDER BY cost_usd DESC, calls DESC".format(_SUM_COLS, where),
        params
    ).fetchall()
    total_cost = sum(r["cost_usd"] for r in rows)
    out = []
    for r in rows:
        item = {k: r[k] for k in _SUM_KEYS}
        item["cost_usd"] = round(item["cost_usd"], 6)
        item["provider"] = r["provider"]
        item["model"] = r["model"]
        item["priced"] = r["priced"]
        item["share"] = round(r["cost_usd"] / total_cost, 6) if total_cost else 0.0
        out.append(item)
    return out


def _by_provider(conn, days):
    where, params = _period_clause(days)
    rows = conn.execute(
        "SELECT provider, {} FROM llm_calls {} GROUP BY provider ORDER BY cost_usd DESC".format(_SUM_COLS, where),
        params
    ).fetchall()
    out = []
    for r in rows:
        item = {k: r[k] for k in _SUM_KEYS}
        item["cost_usd"] = round(item["cost_usd"], 6)
        item["provider"] = r["provider"]
        out.append(item)
    return out


def summary(days=30):
    """Всё, что нужно вкладке «Токены» за один запрос. days=0 — за всё время."""
    conn = _connect()
    where, params = _period_clause(days)
    month_start = datetime.date.today().replace(day=1).isoformat()
    return {
        "days": days,
        "period": _agg(conn, where, params),
        "totals": _agg(conn),
        "month": _agg(conn, "WHERE day >= ?", (month_start,)),
        "by_day": _by_day(conn, days),
        "by_model": _by_model(conn, days),
        "by_provider": _by_provider(conn, days),
    }


def calls(limit=50, offset=0, provider=None, model=None, q=None, date_from=None, date_to=None):
    """Страница журнала вызовов. limit=0 — отдать всё (выгрузка CSV)."""
    conn = _connect()
    limit = 0 if int(limit) == 0 else max(1, min(500, int(limit)))
    offset = max(0, int(offset))

    where, params = [], []
    if provider:
        where.append("provider = ?")
        params.append(provider)
    if model:
        where.append("model = ?")
        params.append(model)
    if q:
        where.append("(model LIKE ? OR IFNULL(endpoint, '') LIKE ?)")
        params += ["%{}%".format(q), "%{}%".format(q)]
    if date_from:
        where.append("day >= ?")
        params.append(date_from)
    if date_to:
        where.append("day <= ?")
        params.append(date_to)
    clause = ("WHERE " + " AND ".join(where)) if where else ""

    total = conn.execute("SELECT COUNT(*) AS n FROM llm_calls {}".format(clause), params).fetchone()["n"]

    sql = ("SELECT id, ts, provider, model, prompt_tokens, completion_tokens, total_tokens,"
           " cost_usd, priced, endpoint FROM llm_calls {} ORDER BY id DESC".format(clause))
    if limit:
        sql += " LIMIT ? OFFSET ?"
        rows = conn.execute(sql, params + [limit, offset]).fetchall()
    else:
        rows = conn.execute(sql, params).fetchall()

    return {"rows": [dict(r) for r in rows], "total": total, "limit": limit, "offset": offset}


def db_info():
    """Метаданные файла базы — чтобы в панели было видно, что он реально пишется."""
    conn = _connect()
    rows = conn.execute("SELECT COUNT(*) AS n FROM llm_calls").fetchone()["n"]
    if not os.path.exists(DB_PATH):
        return {"exists": False, "path": DB_PATH, "rows": rows, "size": 0, "modified": None}
    st = os.stat(DB_PATH)
    return {
        "exists": True,
        "path": DB_PATH,
        "rows": rows,
        "size": st.st_size,
        "modified": datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
    }
