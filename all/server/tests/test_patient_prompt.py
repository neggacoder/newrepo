"""
Карточка пациента в промпте: секция появляется только когда карточка есть,
и главный сервер ничего не сохраняет на диск.

Запуск:  python server/tests/test_patient_prompt.py
"""

import os
import sys
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="patient-prompt-test-")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import server  # noqa: E402

URL = "https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186386"

CARD = {
    "key": "3136382",
    "full_name": "Белалова Раяна Романовна",
    "any_information": "аллергия на пенициллин",
    "records": [{"type": "Осмотр", "date": "01.07.2026", "text": "Кашель третий день"}],
}

checks = []
llm_calls = []


def check(name, cond):
    checks.append((name, bool(cond)))


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


async def fake_llm(system, user, provider, endpoint=None):
    llm_calls.append({"endpoint": endpoint, "user": user})
    # Роутеру отвечаем «остаёмся здесь», исполнителю — текстом.
    return '{"page": null}' if endpoint == "router" else '{"reply": "ок"}'


def executor_prompts():
    return [c["user"] for c in llm_calls if c["endpoint"] == "command"]


def main():
    original = server.call_llm
    try:
        # 1. Промпт без карточки — никакой секции «Пациент».
        prompt = server._build_user_prompt("привет", URL, [], None)
        check("без карточки нет секции", "Пациент" not in prompt)

        # 2. Промпт с карточкой — есть ФИО, заметка и запись.
        prompt = server._build_user_prompt("привет", URL, [], CARD)
        check("с карточкой есть секция", "Пациент" in prompt)
        check("промпт содержит ФИО", "Белалова Раяна Романовна" in prompt)
        check("промпт содержит заметку врача", "аллергия на пенициллин" in prompt)
        check("промпт содержит текст записи", "Кашель третий день" in prompt)

        # 3. Пустая карточка равносильна её отсутствию.
        check("пустой dict -> нет секции", "Пациент" not in server._build_user_prompt("привет", URL, [], {}))

        # 4. Служебные поля не тратят токены.
        check("updated_at не уходит в промпт", "updated_at" not in prompt)
        check("key не уходит в промпт", '"key"' not in prompt)

        # 5. /command прокидывает patient в промпт исполнителя.
        server.call_llm = fake_llm
        asyncio.run(server.command(FakeRequest({"text": "привет", "url": URL, "patient": CARD})))
        check("/command передал карточку исполнителю",
              executor_prompts() and "Белалова Раяна Романовна" in executor_prompts()[-1])

        # ПДн не должны утекать в лишний вызов: роутеру карточка не нужна.
        router_prompts = [c["user"] for c in llm_calls if c["endpoint"] == "router"]
        check("роутер вызван (для hospital-akt есть карта)", len(router_prompts) == 1)
        check("карточка НЕ уходит роутеру", "Белалова" not in router_prompts[0])
        check("заметки врача НЕ уходят роутеру", "пенициллин" not in router_prompts[0])

        # 6. /command без карточки работает как раньше.
        llm_calls.clear()
        asyncio.run(server.command(FakeRequest({"text": "привет", "url": URL})))
        check("/command без карточки не падает", len(executor_prompts()) == 1)
        check("/command без карточки не выдумывает секцию", "Пациент" not in executor_prompts()[-1])

        # 7. Главный сервер не создаёт хранилища ПДн.
        check("нет каталога server/patients", not os.path.exists(os.path.join(server.HERE, "patients")))
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
