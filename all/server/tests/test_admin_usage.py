"""
Тесты HTTP-слоя учёта токенов (server/admin.py).
──────────────────────────────────────────────────────────────────────────
Поднимаем приложение через fastapi.testclient и бьём по эндпоинтам. База и
config.json подменяются на временные, поэтому рабочие файлы не трогаются.

Запуск:  python server/tests/test_admin_usage.py
"""

import os
import sys
import shutil
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

# ВАЖНО: пути подменяем ДО импорта usage — DB_PATH читается на импорте.
TMP = tempfile.mkdtemp(prefix="admin-usage-test-")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

from fastapi.testclient import TestClient  # noqa: E402
import usage    # noqa: E402
import admin    # noqa: E402
import server   # noqa: E402

admin.CONFIG_PATH = os.path.join(TMP, "config.json")   # чтобы не переписать рабочий config.json
client = TestClient(server.app)


def test_requires_auth():
    for path in ("/admin/usage/summary", "/admin/usage/calls", "/admin/usage/calls.csv"):
        assert client.get(path).status_code == 401, path
    r = client.post("/admin/usage/budget", json={"monthly_budget_usd": 5})
    assert r.status_code == 401, r.status_code


def test_summary_shape():
    usage.record_usage("openai", "gpt-4o", {"prompt_tokens": 1000, "completion_tokens": 100},
                       endpoint="command")
    r = client.get("/admin/usage/summary?days=30")
    assert r.status_code == 200, r.text
    d = r.json()
    for k in ("days", "period", "totals", "month", "by_day", "by_model", "by_provider", "budget", "db"):
        assert k in d, k
    assert d["period"]["calls"] == 1, d["period"]
    assert len(d["by_day"]) == 30, len(d["by_day"])
    assert d["db"]["rows"] == 1, d["db"]


def test_summary_clamps_days():
    assert client.get("/admin/usage/summary?days=9999").json()["days"] == 365
    assert client.get("/admin/usage/summary?days=0").json()["days"] == 0     # 0 = всё время


def test_calls_filters():
    usage.record_usage("deepseek", "deepseek-chat", {"prompt_tokens": 5, "completion_tokens": 5},
                       endpoint="ocr-template")
    d = client.get("/admin/usage/calls?provider=deepseek&limit=10").json()
    assert d["total"] == 1 and d["rows"][0]["provider"] == "deepseek", d
    assert client.get("/admin/usage/calls?q=ocr").json()["total"] == 1


def test_csv_export():
    r = client.get("/admin/usage/calls.csv")
    assert r.status_code == 200, r.text
    assert "text/csv" in r.headers["content-type"], r.headers["content-type"]
    assert "attachment" in r.headers["content-disposition"]
    body = r.content.decode("utf-8")
    assert body.startswith("\ufeff"), "нужен BOM, иначе Excel ломает кириллицу"
    assert "gpt-4o" in body and "deepseek-chat" in body


def test_budget_roundtrip():
    r = client.post("/admin/usage/budget", json={"monthly_budget_usd": 50})
    assert r.status_code == 200, r.text
    assert server.CONFIG["monthly_budget_usd"] == 50.0
    assert os.path.exists(admin.CONFIG_PATH), "лимит должен сохраниться на диск"

    b = client.get("/admin/usage/summary?days=1").json()["budget"]
    assert b["limit_usd"] == 50.0 and b["pct"] is not None, b


def test_budget_rejects_garbage():
    assert client.post("/admin/usage/budget", json={"monthly_budget_usd": "много"}).status_code == 400
    assert client.post("/admin/usage/budget", json={"monthly_budget_usd": -1}).status_code == 400


def main():
    # Порядок важен: сначала проверяем 401, только потом отключаем авторизацию.
    failed = 0
    ordered = [test_requires_auth]
    rest = [test_summary_shape, test_summary_clamps_days, test_calls_filters,
            test_csv_export, test_budget_roundtrip, test_budget_rejects_garbage]
    try:
        for t in ordered + [None] + rest:
            if t is None:
                server.app.dependency_overrides[admin.require_auth] = lambda: True
                continue
            try:
                t()
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
        shutil.rmtree(TMP, ignore_errors=True)

    total = len(ordered) + len(rest)
    print("\n{}/{} тестов прошло".format(total - failed, total))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
