"""
/command в две ступени: роутер выбирает страницу, исполнитель строит план,
шаги навигации приклеивает код.

Запуск:  python vox_server/tests/test_command_router.py
"""

import os
import sys
import json
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="command-router-test-")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import vox_server as server  # noqa: E402

HOSPITAL = "https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186386"
FOREIGN = "https://example.com/whatever"

checks = []
calls = []


def check(name, cond):
    checks.append((name, bool(cond)))


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


def scripted_llm(by_endpoint):
    """Отвечает по-разному роутеру и исполнителю; пишет журнал вызовов."""
    async def _call(system, user, provider, endpoint=None):
        calls.append({"endpoint": endpoint, "user": user})
        return by_endpoint.get(endpoint, "{}")
    return _call


def command(body):
    return asyncio.run(server.command(FakeRequest(body)))


EXECUTOR_PLAN = json.dumps({"steps": [
    {"selector": "#btnAdd", "method": "click", "type_write": "write", "value": None}
]}, ensure_ascii=False)


def main():
    original = server.call_llm
    try:
        # 1. Карта есть, врач на другой вкладке: роутер зовётся, навигация впереди плана.
        calls.clear()
        server.call_llm = scripted_llm({
            "router": '{"page": "diaries"}',
            "command": EXECUTOR_PLAN,
        })
        res = command({"text": "добавь дневник", "url": HOSPITAL, "active_tab": "mh-medicalrecords"})
        endpoints = [c["endpoint"] for c in calls]
        check("роутер вызван", "router" in endpoints)
        check("исполнитель вызван", "command" in endpoints)
        check("роутер вызван первым", endpoints[0] == "router")
        check("в плане есть шаги", "steps" in res)
        check("первый шаг — навигация на вкладку дневников",
              res["steps"][0]["selector"] == "ul.mh-navigation.big-screen .mh-diaries a")
        check("следом идёт шаг исполнителя", res["steps"][1]["selector"] == "#btnAdd")
        check("у навигации проставлен адрес", res["steps"][0]["address"] == HOSPITAL)

        # 2. Врач уже на целевой вкладке: навигации нет.
        calls.clear()
        res = command({"text": "добавь дневник", "url": HOSPITAL, "active_tab": "mh-diaries"})
        check("на целевой вкладке навигации нет", len(res["steps"]) == 1)
        check("остался только шаг исполнителя", res["steps"][0]["selector"] == "#btnAdd")

        # 3. Роутер сказал null: навигации нет, исполнитель всё равно работает.
        calls.clear()
        server.call_llm = scripted_llm({"router": '{"page": null}', "command": EXECUTOR_PLAN})
        res = command({"text": "нажми кнопку", "url": HOSPITAL, "active_tab": "mh-diaries"})
        check("page=null -> только шаг исполнителя", len(res["steps"]) == 1)

        # 4. Роутер вернул мусор: не падаем, идём дальше без навигации.
        calls.clear()
        server.call_llm = scripted_llm({"router": "я не робот", "command": EXECUTOR_PLAN})
        res = command({"text": "нажми кнопку", "url": HOSPITAL, "active_tab": "mh-diaries"})
        check("мусор от роутера -> план всё равно есть", "steps" in res and len(res["steps"]) == 1)

        # 5. Роутер вернул несуществующий ключ.
        calls.clear()
        server.call_llm = scripted_llm({"router": '{"page": "нет_такой"}', "command": EXECUTOR_PLAN})
        res = command({"text": "нажми кнопку", "url": HOSPITAL, "active_tab": "mh-diaries"})
        check("неизвестный ключ -> навигации нет", len(res["steps"]) == 1)

        # 6. Для чужого сайта карты нет — роутер не зовётся вовсе (экономия токенов).
        calls.clear()
        server.call_llm = scripted_llm({"command": EXECUTOR_PLAN})
        res = command({"text": "нажми кнопку", "url": FOREIGN})
        check("без карты роутер не вызывается", "router" not in [c["endpoint"] for c in calls])
        check("без карты исполнитель вызывается", [c["endpoint"] for c in calls] == ["command"])
        check("без карты план строится", "steps" in res)

        # 7. Исполнитель вернул reply — навигация не приклеивается к тексту.
        calls.clear()
        server.call_llm = scripted_llm({"router": '{"page": "diaries"}', "command": '{"reply": "не понял"}'})
        res = command({"text": "бла", "url": HOSPITAL, "active_tab": "mh-medicalrecords"})
        check("reply остаётся reply", res.get("reply") == "не понял" and "steps" not in res)

        # 8. Роутер видит команду, но не видит селекторы.
        calls.clear()
        server.call_llm = scripted_llm({"router": '{"page": null}', "command": EXECUTOR_PLAN})
        command({"text": "секретная команда", "url": HOSPITAL, "active_tab": "mh-diaries"})
        router_user = next(c["user"] for c in calls if c["endpoint"] == "router")
        check("роутер видит команду", "секретная команда" in router_user)
        check("роутер не видит селекторы вкладок", "mh-navigation" not in router_user)
    finally:
        server.call_llm = original
        shutil.rmtree(TMP, ignore_errors=True)

    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print("\n{}/{} тестов прошло".format(len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
