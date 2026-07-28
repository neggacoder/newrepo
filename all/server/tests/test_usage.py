"""
Тесты server/usage.py.
──────────────────────────────────────────────────────────────────────────
Тестового фреймворка в проекте нет, поэтому это самостоятельный скрипт на
обычных assert. Каждый тест получает свою пустую временную папку.

Запуск:  python server/tests/test_usage.py
"""

import os
import sys
import shutil
import tempfile
import datetime

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

import usage  # noqa: E402


def fresh(tmp, txt=None):
    """Свежая БД в tmp. Если передан txt — подкладываем token_usage.txt для бэкфилла."""
    if usage._conn is not None:
        usage._conn.close()
    usage._conn = None
    usage._initialized = False
    usage.DB_PATH = os.path.join(tmp, "usage.db")
    usage.TXT_PATH = os.path.join(tmp, "token_usage.txt")
    if txt is not None:
        with open(usage.TXT_PATH, "w", encoding="utf-8") as f:
            f.write(txt)
    return usage.init_db()


def test_schema_created(tmp):
    fresh(tmp)
    conn = usage._connect()
    names = {r["name"] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"llm_calls", "meta"} <= names, names


def test_record_openai_cost(tmp):
    fresh(tmp)
    cost = usage.record_usage(
        "openai", "gpt-4o",
        {"prompt_tokens": 1_000_000, "completion_tokens": 0, "total_tokens": 1_000_000},
        endpoint="command",
    )
    assert abs(cost - 2.50) < 1e-9, cost
    row = usage._connect().execute("SELECT * FROM llm_calls").fetchone()
    assert row["provider"] == "openai", row["provider"]
    assert row["priced"] == 1 and row["endpoint"] == "command"
    assert row["day"] == datetime.date.today().isoformat(), row["day"]


def test_deepseek_uses_its_own_prices(tmp):
    fresh(tmp)
    cost = usage.record_usage("deepseek", "deepseek-chat",
                              {"prompt_tokens": 1_000_000, "completion_tokens": 1_000_000})
    assert abs(cost - (0.27 + 1.10)) < 1e-9, cost


def test_unknown_model_is_unpriced(tmp):
    fresh(tmp)
    cost = usage.record_usage("openai", "gpt-9-secret", {"prompt_tokens": 10, "completion_tokens": 5})
    assert cost == 0.0, cost
    row = usage._connect().execute("SELECT priced, total_tokens FROM llm_calls").fetchone()
    assert row["priced"] == 0 and row["total_tokens"] == 15, dict(row)


def test_empty_usage_records_nothing(tmp):
    fresh(tmp)
    assert usage.record_usage("openai", "gpt-4o", None) == 0.0
    n = usage._connect().execute("SELECT COUNT(*) AS n FROM llm_calls").fetchone()["n"]
    assert n == 0, n


def test_no_txt_or_json_is_written(tmp):
    fresh(tmp)
    usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 1, "completion_tokens": 1})
    assert not os.path.exists(os.path.join(tmp, "token_usage.txt"))
    assert not os.path.exists(os.path.join(tmp, "token_usage.json"))


BACKFILL_TXT = """# Затраты токенов LLM (OpenAI/DeepSeek) — главный сервер Suerte
# Формат: дата время | провайдер:модель | prompt | completion | total | стоимость | итог

2026-07-01 10:00:00 | openai:gpt-4o | prompt=1000 | completion=500 | total=1500 | $0.007500 | ИТОГО: 1500 ток. / $0.0075 (вызовов: 1)
2026-07-01 11:00:00 | gpt-4o | prompt=200 | completion=100 | total=300 | $0.001500 | ИТОГО: 1800 ток. / $0.0090 (вызовов: 2)
2026-07-02 09:30:00 | deepseek:deepseek-chat | prompt=400 | completion=200 | total=600 | $0.000328 | ИТОГО: 2400 ток. / $0.0093 (вызовов: 3)
2026-07-02 09:31:00 | openai:gpt-9-secret | prompt=10 | completion=5 | total=15 | $?(нет цены) | ИТОГО: 2415 ток. / $0.0093 (вызовов: 4)
это не строка лога, а мусор
"""


def test_backfill_imports_all_line_shapes(tmp):
    stats = fresh(tmp, txt=BACKFILL_TXT)
    assert stats == {"imported": 4, "skipped": 1}, stats

    rows = usage._connect().execute("SELECT * FROM llm_calls ORDER BY ts").fetchall()
    assert [r["provider"] for r in rows] == ["openai", "openai", "deepseek", "openai"], [r["provider"] for r in rows]
    # строка без префикса провайдера — легаси, модель берём целиком
    assert rows[1]["model"] == "gpt-4o", rows[1]["model"]
    # двоеточие в имени модели не должно съедаться разбором провайдера
    assert rows[2]["model"] == "deepseek-chat", rows[2]["model"]
    # "$?(нет цены)" -> цены нет
    assert rows[3]["priced"] == 0 and rows[3]["cost_usd"] == 0.0, dict(rows[3])
    assert rows[0]["day"] == "2026-07-01" and rows[0]["prompt_tokens"] == 1000


def test_backfill_runs_only_once(tmp):
    fresh(tmp, txt=BACKFILL_TXT)
    usage._initialized = False           # имитируем перезапуск процесса на той же базе
    stats = usage.init_db()
    assert stats == {"imported": 0, "skipped": 0}, stats
    n = usage._connect().execute("SELECT COUNT(*) AS n FROM llm_calls").fetchone()["n"]
    assert n == 4, n


def test_summary_period_vs_totals(tmp):
    fresh(tmp)
    now = datetime.datetime.now()
    usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 1000, "completion_tokens": 0}, when=now)
    usage.record_usage("deepseek", "deepseek-chat", {"prompt_tokens": 1000, "completion_tokens": 0},
                       when=now - datetime.timedelta(days=10))

    today_only = usage.summary(days=1)
    assert today_only["period"]["calls"] == 1, today_only["period"]
    assert today_only["totals"]["calls"] == 2, today_only["totals"]

    month = usage.summary(days=30)
    assert month["period"]["calls"] == 2, month["period"]


def test_by_day_fills_gaps(tmp):
    fresh(tmp)
    usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 10, "completion_tokens": 0})
    s = usage.summary(days=30)
    assert len(s["by_day"]) == 30, len(s["by_day"])
    assert s["by_day"][-1]["day"] == datetime.date.today().isoformat()
    assert sum(d["calls"] for d in s["by_day"]) == 1
    assert s["by_day"][0]["calls"] == 0 and s["by_day"][0]["cost_usd"] == 0.0


def test_by_model_share_and_order(tmp):
    fresh(tmp)
    usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 1_000_000, "completion_tokens": 0})       # $2.50
    usage.record_usage("openai", "gpt-4o-mini", {"prompt_tokens": 1_000_000, "completion_tokens": 0})  # $0.15
    s = usage.summary(days=1)

    top = s["by_model"][0]
    assert top["model"] == "gpt-4o", top["model"]
    assert abs(top["share"] - 2.50 / 2.65) < 1e-6, top["share"]
    assert len(s["by_provider"]) == 1 and s["by_provider"][0]["provider"] == "openai"


def test_calls_filters_and_paging(tmp):
    fresh(tmp)
    for _ in range(5):
        usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 10, "completion_tokens": 1}, endpoint="command")
    usage.record_usage("deepseek", "deepseek-chat", {"prompt_tokens": 10, "completion_tokens": 1},
                       endpoint="ocr-template")

    everything = usage.calls(limit=50)
    assert everything["total"] == 6 and len(everything["rows"]) == 6
    assert everything["rows"][0]["provider"] == "deepseek", "новые записи должны быть сверху"

    assert usage.calls(provider="deepseek")["total"] == 1
    assert usage.calls(model="gpt-4o")["total"] == 5
    assert usage.calls(q="mini")["total"] == 0
    assert usage.calls(q="ocr")["total"] == 1, "поиск идёт и по endpoint"

    page = usage.calls(limit=2, offset=2)
    assert page["total"] == 6 and len(page["rows"]) == 2 and page["offset"] == 2

    unlimited = usage.calls(limit=0)
    assert len(unlimited["rows"]) == 6, "limit=0 — без LIMIT, для выгрузки CSV"


def test_db_info(tmp):
    fresh(tmp)
    usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 1, "completion_tokens": 1})
    info = usage.db_info()
    assert info["exists"] and info["rows"] == 1 and info["size"] > 0, info


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        tmp = tempfile.mkdtemp(prefix="usage-test-")
        try:
            t(tmp)
            print("  OK   " + t.__name__)
        except AssertionError as e:
            failed += 1
            print("  FAIL " + t.__name__ + ": " + str(e))
        except Exception as e:
            failed += 1
            print("  ERR  " + t.__name__ + ": " + type(e).__name__ + ": " + str(e))
        finally:
            if usage._conn is not None:
                usage._conn.close()
                usage._conn = None
            shutil.rmtree(tmp, ignore_errors=True)
    print("\n{}/{} тестов прошло".format(len(tests) - failed, len(tests)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
