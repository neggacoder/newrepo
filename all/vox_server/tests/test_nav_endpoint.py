"""
Прямая навигация через /command: карта учится сама, переходы строятся кодом.

Как и в test_skills_endpoint, меряем МАРШРУТ И ЦЕНУ: сколько вызовов ИИ уходит
на «открой такую-то страницу» и «открой такого-то пациента». Обе команды
должны обходиться нулём вызовов.

Запуск:  python vox_server/tests/test_nav_endpoint.py
"""

import os
import sys
import json
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="nav-endpoint-test-")
os.environ["TEMPLATES_DIR"] = os.path.join(TMP, "templates")
os.environ["PATIENTS_DIR"] = os.path.join(TMP, "patients")
os.environ["ATLAS_DIR"] = os.path.join(TMP, "atlas")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import vox_server as server  # noqa: E402
import atlas                 # noqa: E402
import ids_log               # noqa: E402

HOST = "https://hospital-akt.dmed.kz"
DOCTOR = HOST + "/doctor"

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
    async def _call(system, user, provider, endpoint=None):
        calls.append({"endpoint": endpoint, "user": user})
        return by_endpoint.get(endpoint, "{}")
    return _call


def command(body):
    return asyncio.run(server.command(FakeRequest(body)))


def main():
    real_call = server.call_llm
    server.call_llm = scripted_llm({"router": json.dumps({"page": None}),
                                    "command": json.dumps({"reply": "ок"})})
    try:
        # ── 1. Карта учится молча, на обычных командах ─────────────────────
        calls.clear()
        command({"text": "что-нибудь непонятное", "url": DOCTOR,
                 "title": "Кабинет врача - Dmed.Стационар", "provider": "openai"})
        page = atlas.find("/doctor", server.ATLAS_DIR)
        check("страница попала в карту сама", page is not None)
        check("заголовок запомнен", page and page["title"] == "Кабинет врача - Dmed.Стационар")
        check("обучение не стоило вызовов ИИ",
              [c["endpoint"] for c in calls] == ["router", "command"])

        # ── 2. ПДн: значения параметров в карту не попадают ───────────────
        command({"text": "что-то", "url": HOST + "/medicalHistory/medicalHistory?id=2195085",
                 "title": "История болезни", "provider": "openai"})
        raw = open(os.path.join(server.ATLAS_DIR, "atlas.json"), encoding="utf-8").read()
        check("id пациента в atlas.json не попал", "2195085" not in raw)
        check("имя параметра сохранено", '"id"' in raw)

        # ── 3. «Открой мои задачи» -> прямой переход, НОЛЬ вызовов ────────
        atlas.learn(HOST + "/doctorTask/index", server.ATLAS_DIR, title="Задачи врача")
        calls.clear()
        plan = command({"text": "открой задачи врача", "url": DOCTOR, "provider": "openai"})
        check("вернулся шаг перехода",
              plan.get("steps") and plan["steps"][0]["method"] == "goto")
        check("адрес собран прямой",
              plan["steps"][0]["value"] == HOST + "/doctorTask/index")
        check("переход не стоил вызовов ИИ", calls == [])
        check("панель знает, куда идём", plan.get("_nav", {}).get("kind") == "page")

        # ── 4. Без намерения перейти карта молчит ─────────────────────────
        calls.clear()
        plan = command({"text": "заполни задачи врача", "url": DOCTOR, "provider": "openai"})
        check("без «открой» команда идёт обычным путём", "_nav" not in plan)
        check("обычный путь звал ИИ", "command" in [c["endpoint"] for c in calls])

        # ── 5. Пациент по имени из ids.jsonl -> прямой адрес, НОЛЬ вызовов ─
        for row in ({"medicalHistory": 2186420, "editMedicalRecord": 3136436,
                     "name": "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ"},
                    {"medicalHistory": 2195085, "editMedicalRecord": 3140001,
                     "name": "ЕЛЕМЕС ИСЛАМИЯ АҚЫЛБЕКҚЫЗЫ"}):
            ids_log.remember(row, server.PATIENTS_DIR)

        calls.clear()
        plan = command({"text": "открой историю болезни Амантая", "url": DOCTOR, "provider": "openai"})
        check("пациент -> шаг перехода",
              plan.get("steps") and plan["steps"][0]["method"] == "goto")
        check("адрес пациента собран кодом",
              plan["steps"][0]["value"] == HOST + "/medicalHistory/medicalHistory?id=2186420")
        check("пациент не стоил вызовов ИИ", calls == [])
        check("панель называет пациента",
              plan.get("_nav", {}).get("name") == "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ")
        # Позиционного селектора в плане нет вообще — в этом весь смысл.
        check("никаких nth-child", "nth-child" not in json.dumps(plan, ensure_ascii=False))

        # ── 6. Уже на нужной странице — не переходим ──────────────────────
        plan = command({"text": "открой историю болезни Амантая",
                        "url": HOST + "/medicalHistory/medicalHistory?id=2186420",
                        "provider": "openai"})
        check("повторный переход не строится", "_nav" not in plan)

        # ── 6b. КОМПОЗИЦИЯ: «создай эпикриз Амантаю» = переход + шаблон ───
        import templates_store
        tpl_steps = [
            {"method": "click", "selector": "#vybrat", "address": DOCTOR, "description": "Выбрать"},
            {"method": "click", "selector": "#zapisi",
             "address": HOST + "/medicalHistory/medicalHistory", "description": "Мед. записи"},
            {"method": "write", "selector": "#editor_0",
             "address": HOST + "/patientMedicalRecord/editMedicalRecord", "value": "старый текст"},
        ]
        tid = templates_store.save("Создать выписной эпикриз", tpl_steps, server.TEMPLATES_DIR)["id"]
        templates_store.set_skill(tid, {
            "name": "Создать выписной эпикриз",
            "triggers": ["создай выписной эпикриз", "сделай выписку"],
            "slots": [],
        }, server.TEMPLATES_DIR)

        server.call_llm = scripted_llm({"skill-slots": json.dumps(
            {"field_2": "Жалобы на боль в пояснице."}, ensure_ascii=False)})
        calls.clear()
        plan = command({"text": "создай выписной эпикриз Амантаю", "url": DOCTOR, "provider": "openai"})
        steps = plan.get("steps") or []
        check("композиция: первый шаг — переход к пациенту",
              steps and steps[0]["method"] == "goto"
              and steps[0]["value"] == HOST + "/medicalHistory/medicalHistory?id=2186420")
        check("композиция: клик по гриду срезан",
              all(s.get("selector") != "#vybrat" for s in steps))
        check("композиция: работа шаблона сохранена",
              [s.get("selector") for s in steps[1:]] == ["#zapisi", "#editor_0"])
        check("композиция: текст всё равно продиктован",
              steps[-1]["value"] == "Жалобы на боль в пояснице.")
        check("композиция: панель показывает и пациента, и срез",
              plan["_nav"]["name"] == "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ" and plan["_nav"]["cut"] == 1)
        check("композиция: шаблон на диске не тронут",
              templates_store.get(tid, server.TEMPLATES_DIR)["example_output"]["steps"] == tpl_steps)

        # Пациента не назвали — шаблон идёт как записан (прежнее поведение).
        plan = command({"text": "создай выписной эпикриз", "url": DOCTOR, "provider": "openai"})
        check("без имени пациента склейки нет", "_nav" not in plan)
        check("без имени шаблон целиком", plan["steps"][0]["selector"] == "#vybrat")

        # Уже на карточке этого пациента: перехода нет, но дорога всё равно срезана.
        plan = command({"text": "создай выписной эпикриз Амантаю",
                        "url": HOST + "/medicalHistory/medicalHistory?id=2186420",
                        "provider": "openai"})
        check("уже у пациента: лишнего перехода нет", plan["steps"][0]["method"] != "goto")
        check("уже у пациента: дорога всё равно срезана",
              plan["steps"][0]["selector"] == "#zapisi")

        # ── 7. Шаблон обучает карту при сохранении ────────────────────────
        server.call_llm = scripted_llm({"template-enrich": "{}"})
        steps = [{"method": "click", "selector": "#a", "address": HOST + "/emergency/reception"},
                 {"method": "click", "selector": "#b", "address": HOST + "/inspection/inspection"}]
        asyncio.run(server.template_save(FakeRequest(
            {"name": "Тест", "steps": steps, "provider": "openai"})))
        check("страницы шаблона попали в карту",
              atlas.find("/emergency/reception", server.ATLAS_DIR) is not None
              and atlas.find("/inspection/inspection", server.ATLAS_DIR) is not None)
    finally:
        server.call_llm = real_call

    print()
    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print(f"\n{len(checks) - len(failed)}/{len(checks)} тестов прошло")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        code = main()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(code)
