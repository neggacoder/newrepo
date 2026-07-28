"""
Проводка навыков: /template/save обогащает шаблон, /command запускает его.

Здесь проверяется не логика (она в test_skills.py), а ЦЕНА и МАРШРУТ: сколько
вызовов ИИ реально уходит на команду и какие. Ради этого всё и делалось —
совпавший шаблон должен снимать дорогой вызов исполнителя, а шаблон без
слотов не должен стоить ни одного вызова вообще.

Запуск:  python vox_server/tests/test_skills_endpoint.py
"""

import os
import sys
import json
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="skills-endpoint-test-")
os.environ["TEMPLATES_DIR"] = os.path.join(TMP, "templates")
os.environ["TYPES_DIR"] = os.path.join(TMP, "types")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import vox_server as server  # noqa: E402
import templates_store       # noqa: E402

URL = "https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=1"

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


STEPS = [
    {"selector": "ul > li:nth-child(2) > a", "method": "click", "type_write": "write",
     "value": None, "address": URL, "description": "Медицинские записи"},
    {"selector": "#editor_1", "method": "write", "type_write": "write",
     "value": "Состояние удовлетворительное. Жалоб нет.",
     "address": URL, "description": "Дневник"},
]

NAV_ONLY = [STEPS[0]]

ENRICH = json.dumps({
    "name": "Дневниковая запись",
    "triggers": ["новая дневниковая запись", "заполни дневник"],
    "slots": [{"step": 1, "key": "text", "label": "текст дневника",
               "skeleton": "Состояние … Жалоб …"}],
}, ensure_ascii=False)


def main():
    real_call = server.call_llm
    try:
        # ── 1. Сохранение шаблона обогащает его ровно ОДНИМ вызовом ────────
        server.call_llm = scripted_llm({"template-enrich": ENRICH})
        calls.clear()
        res = asyncio.run(server.template_save(FakeRequest(
            {"name": "Записанный шаблон", "steps": STEPS, "provider": "openai"})))
        check("save -> ok", res.get("ok") is True)
        check("обогащение — ровно 1 вызов", len(calls) == 1)
        check("вызов помечен как template-enrich", calls and calls[0]["endpoint"] == "template-enrich")
        check("имя пришло от обогащения", res.get("name") == "Дневниковая запись")
        check("навык вернулся расширению", bool(res.get("skill", {}).get("triggers")))
        # Экономия, ради которой всё затевалось: селекторы в промпт не уходят.
        check("в промпте обогащения нет селекторов", "ul > li" not in calls[0]["user"])
        check("но есть текст врача (для skeleton)", "Состояние удовлетворительное" in calls[0]["user"])

        saved = templates_store.get(res["id"], server.TEMPLATES_DIR)
        check("навык лёг в файл шаблона", saved.get("skill", {}).get("slots")[0]["step"] == 1)

        # ── 2. Голосовая команда попадает в шаблон ────────────────────────
        server.call_llm = scripted_llm({"skill-slots": json.dumps(
            {"text": "Жалоб нет. АД 130/85."}, ensure_ascii=False)})
        calls.clear()
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "заполни дневник", "url": URL, "provider": "openai"})))
        check("вернулся план шагов", isinstance(plan, dict) and bool(plan.get("steps")))
        check("сработал навык", plan.get("_skill", {}).get("name") == "Дневниковая запись")
        # Главное: НЕТ вызовов router/command — самый дорогой этап снят.
        eps = [c["endpoint"] for c in calls]
        check("только заполнение слотов", eps == ["skill-slots"])
        check("роутер не звался", "router" not in eps)
        check("исполнитель не звался", "command" not in eps)
        check("селекторы взяты из записи", plan["steps"][0]["selector"] == STEPS[0]["selector"])
        check("текст подставлен в шаг ввода", plan["steps"][1]["value"] == "Жалоб нет. АД 130/85.")
        check("шаблон на диске не испорчен",
              templates_store.get(res["id"], server.TEMPLATES_DIR)["example_output"]["steps"][1]["value"]
              == "Состояние удовлетворительное. Жалоб нет.")

        # ── 3. Шаблон без слотов — НОЛЬ вызовов ИИ на команду ─────────────
        server.call_llm = scripted_llm({"template-enrich": json.dumps(
            {"name": "Открыть мед. записи", "triggers": ["открой медицинские записи"], "slots": []},
            ensure_ascii=False)})
        asyncio.run(server.template_save(FakeRequest(
            {"name": "Записанный шаблон", "steps": NAV_ONLY, "provider": "openai"})))
        server.call_llm = scripted_llm({})
        calls.clear()
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "открой медицинские записи", "url": URL, "provider": "openai"})))
        check("навигационный навык сработал", plan.get("_skill", {}).get("name") == "Открыть мед. записи")
        check("НОЛЬ вызовов ИИ на команду", calls == [])

        # ── 4. Команда мимо шаблонов идёт прежним путём ───────────────────
        server.call_llm = scripted_llm({
            "router": json.dumps({"page": None}),
            "command": json.dumps({"reply": "Готово"}),
        })
        calls.clear()
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "распечатай направление в лабораторию", "url": URL, "provider": "openai"})))
        eps = [c["endpoint"] for c in calls]
        check("навык не подхватил чужую команду", "_skill" not in plan)
        check("сработал обычный путь", "command" in eps)

        # ── 4b. СТАРЫЙ шаблон со slots=[] чинится БЕЗ перезаписи ──────────
        # Ровно случай «выписного эпикриза #4»: модель при обогащении решила,
        # что поле постоянное, и текст «блаблабла» уехал бы каждому пациенту.
        legacy_id = templates_store.save("Создать выписной эпикриз", STEPS, server.TEMPLATES_DIR)["id"]
        templates_store.set_skill(legacy_id, {
            "name": "Создать выписной эпикриз",
            "triggers": ["создай выписной эпикриз", "сделай выписку"],
            "slots": [],                      # <- пусто, как в реальном файле
        }, server.TEMPLATES_DIR)

        server.call_llm = scripted_llm({"skill-slots": json.dumps(
            {"field_1": "Жалобы на боль в пояснице."}, ensure_ascii=False)})
        calls.clear()
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "создай выписной эпикриз, жалобы на боль в пояснице",
             "url": URL, "provider": "openai"})))
        check("старый шаблон сработал", plan.get("_skill", {}).get("id") == legacy_id)
        check("слот достроен кодом", [c["endpoint"] for c in calls] == ["skill-slots"])
        check("текст ЗАМЕНЁН, а не взят из записи",
              plan["steps"][1]["value"] == "Жалобы на боль в пояснице.")
        check("панель знает, что поле продиктовано",
              plan["_skill"]["slots"] == 1 and plan["_skill"]["slots_total"] == 1)
        # Врач ничего не продиктовал -> поле сохраняет запись (прежнее поведение),
        # но панель обязана это показать.
        server.call_llm = scripted_llm({"skill-slots": "{}"})
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "создай выписной эпикриз", "url": URL, "provider": "openai"})))
        check("без диктовки текст остаётся из записи",
              plan["steps"][1]["value"] == "Состояние удовлетворительное. Жалоб нет.")
        check("панель видит незаполненное поле",
              plan["_skill"]["slots"] == 0 and plan["_skill"]["slots_total"] == 1)

        # ── 4c. /template/reenrich чинит подписи без перезаписи шаблона ───
        server.call_llm = scripted_llm({"template-enrich": json.dumps({
            "name": "Создать выписной эпикриз",
            "triggers": ["создай выписной эпикриз"],
            "slots": [{"step": 1, "key": "text", "label": "жалобы и анамнез",
                       "skeleton": "Жалобы на … Состояние …"}],
        }, ensure_ascii=False)})
        calls.clear()
        res4 = asyncio.run(server.template_reenrich(FakeRequest(
            {"id": legacy_id, "provider": "openai"})))
        check("reenrich -> ok", res4.get("ok") is True)
        check("reenrich — ровно 1 вызов", len(calls) == 1)
        check("подписи стали человеческими",
              res4["skill"]["slots"][0]["label"] == "жалобы и анамнез")
        check("появился обезличенный образец",
              res4["skill"]["slots"][0]["skeleton"] == "Жалобы на … Состояние …")
        check("шаги шаблона не тронуты",
              templates_store.get(legacy_id, server.TEMPLATES_DIR)["example_output"]["steps"] == STEPS)
        check("reenrich несуществующего -> ok:false",
              asyncio.run(server.template_reenrich(FakeRequest({"id": 99999}))).get("ok") is False)

        # ── 4d. Каталог types.json ────────────────────────────────────────
        import types_store
        cat_id = templates_store.save("Каталожный", STEPS, server.TEMPLATES_DIR)["id"]
        # Имя и фраза НАРОЧНО разные: только так видно, что именно совпало.
        templates_store.set_skill(cat_id, {
            "name": "Каталожный сценарий",
            "triggers": ["фраза из шаблона"],
            "slots": [],
        }, server.TEMPLATES_DIR)

        # sync при открытии панели заводит записи и для старых шаблонов.
        asyncio.run(server.template_list(FakeRequest({})))
        check("sync завёл запись в каталоге",
              types_store.triggers_for(cat_id, server.TYPES_DIR) == ["фраза из шаблона"])

        # Врач поправил фразу руками — она и должна сработать.
        types_store.put({"id": cat_id, "name": "Каталожный сценарий",
                         "triggers": ["особая фраза"], "fields": []}, server.TYPES_DIR)
        server.call_llm = scripted_llm({})
        calls.clear()
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "особая фраза", "url": URL, "provider": "openai"})))
        check("ручная фраза запускает шаблон", plan.get("_skill", {}).get("id") == cat_id)
        # Сопоставление бесплатно; skill-slots — отдельная статья расхода
        # (у шаблона есть поле ввода), дорогой путь router+command не тронут.
        eps = [c["endpoint"] for c in calls]
        check("сопоставление по каталогу не звало роутер/исполнитель",
              "router" not in eps and "command" not in eps)

        # Фраза, оставшаяся ТОЛЬКО в файле шаблона, больше не работает:
        # каталог главнее, и стёртая врачом формулировка не воскресает.
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "фраза из шаблона", "url": URL, "provider": "openai"})))
        check("стёртая фраза не воскресает из шаблона", "_skill" not in plan)

        # А по ИМЕНИ типа запуск остаётся: имя тоже участвует в сопоставлении
        # и тоже правится в каталоге. Полное выключение голоса — пустой triggers.
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "каталожный сценарий", "url": URL, "provider": "openai"})))
        check("по имени типа запуск работает", plan.get("_skill", {}).get("id") == cat_id)

        types_store.put({"id": cat_id, "name": "Каталожный сценарий",
                         "triggers": [], "fields": []}, server.TYPES_DIR)
        plan = asyncio.run(server.command(FakeRequest(
            {"text": "каталожный сценарий", "url": URL, "provider": "openai"})))
        check("пустой triggers выключает голос целиком", "_skill" not in plan)

        # «↻» перезаписывает каталог намеренно.
        server.call_llm = scripted_llm({"template-enrich": json.dumps({
            "name": "Каталожный сценарий",
            "triggers": ["каталожный сценарий"], "slots": []}, ensure_ascii=False)})
        asyncio.run(server.template_reenrich(FakeRequest({"id": cat_id, "provider": "openai"})))
        check("«↻» перезаписал каталог",
              types_store.triggers_for(cat_id, server.TYPES_DIR) == ["каталожный сценарий"])

        # Удаление шаблона убирает запись.
        asyncio.run(server.template_delete(FakeRequest({"id": cat_id})))
        check("удаление шаблона убрало запись",
              types_store.triggers_for(cat_id, server.TYPES_DIR) is None)

        # ── 5. Упавшее обогащение не теряет шаблон ────────────────────────
        async def boom(*a, **kw):
            raise RuntimeError("LLM недоступен")
        server.call_llm = boom
        res5 = asyncio.run(server.template_save(FakeRequest(
            {"name": "Без обогащения", "steps": STEPS, "provider": "openai"})))
        check("шаблон сохранён несмотря на падение ИИ", res5.get("ok") is True)
        check("навыка нет, но файл есть",
              templates_store.get(res5["id"], server.TEMPLATES_DIR) is not None)
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
