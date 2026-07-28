"""
/medical-record/plan: ранние отказы без обращения к ИИ + сборка плана.

Запуск:  python vox_server/tests/test_medrecord_endpoint.py
"""

import os
import sys
import json
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="medrec-endpoint-test-")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import vox_server as server  # noqa: E402

URL = "https://hospital-akt.dmed.kz/patientMedicalRecord/editMedicalRecord?id=0"

checks = []
llm_calls = []


def check(name, cond):
    checks.append((name, bool(cond)))


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


def fake_llm(reply):
    async def _call(system, user, provider, endpoint=None):
        llm_calls.append({"endpoint": endpoint, "user": user})
        return reply
    return _call


def call(body):
    return asyncio.run(server.medical_record_plan(FakeRequest(body)))


def main():
    blocks = [
        {"id": "-1", "name": "Жалобы при поступлении", "text": "", "empty": True},
        {"id": "-2", "name": "Анамнез заболевания", "text": "Уже есть", "empty": False},
    ]
    history = [{"type": "Осмотр", "date": "01.07.2026", "text": "Кашель третий день"}]

    original = server.call_llm
    try:
        # 1. Без блоков — отказ до вызова ИИ.
        server.call_llm = fake_llm("{}")
        res = call({"blocks": [], "history": history, "url": URL})
        check("нет блоков -> reply", "reply" in res)
        check("нет блоков -> ИИ не вызывался", not llm_calls)

        # 2. Все блоки заполнены — отказ до вызова ИИ.
        res = call({"blocks": [dict(blocks[1])], "history": history, "url": URL})
        check("все блоки заполнены -> reply", "reply" in res)
        check("все блоки заполнены -> ИИ не вызывался", not llm_calls)

        # 3. Нет истории — отказ до вызова ИИ.
        res = call({"blocks": blocks, "history": [], "url": URL})
        check("нет истории -> reply", "reply" in res)
        check("нет истории -> ИИ не вызывался", not llm_calls)

        # 4. Счастливый путь.
        server.call_llm = fake_llm(json.dumps({"blocks": {"-1": "Кашель третий день"}}, ensure_ascii=False))
        res = call({"blocks": blocks, "history": history, "url": URL})
        check("счастливый путь -> steps", "steps" in res)
        check("счастливый путь -> 3 шага", len(res.get("steps", [])) == 3)
        check("счастливый путь -> запись текста", res["steps"][1]["value"] == "Кашель третий день")
        check("endpoint попал в журнал затрат", llm_calls and llm_calls[-1]["endpoint"] == "medical-record")
        check("промпт содержит текст истории", "Кашель третий день" in llm_calls[-1]["user"])

        # 5. Мусор от ИИ.
        llm_calls.clear()
        server.call_llm = fake_llm("не json вовсе")
        res = call({"blocks": blocks, "history": history, "url": URL})
        check("неразобранный ответ -> reply", "reply" in res)

        # 6. ИИ ничего не предложил.
        server.call_llm = fake_llm('{"blocks": {}}')
        res = call({"blocks": blocks, "history": history, "url": URL})
        check("пустой ответ ИИ -> reply", "reply" in res and "steps" not in res)
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
