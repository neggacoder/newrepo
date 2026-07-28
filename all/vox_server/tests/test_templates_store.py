"""
templates_store.py и /template/save, /template/list, /template/delete на
локальном сервере.

Запуск:  python vox_server/tests/test_templates_store.py
"""

import os
import sys
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="templates-store-test-")
os.environ["TEMPLATES_DIR"] = TMP

import templates_store  # noqa: E402
import vox_server as user_server  # noqa: E402

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


def tpl_save(body):
    return asyncio.run(user_server.template_save(FakeRequest(body)))


def tpl_list(body=None):
    return asyncio.run(user_server.template_list(FakeRequest(body or {})))


def tpl_delete(body):
    return asyncio.run(user_server.template_delete(FakeRequest(body)))


STEPS = [
    {
        "selector": "body > div:nth-child(1)",
        "method": "click",
        "type_write": "write",
        "value": None,
        "address": "https://x/y",
    }
]


def main():
    try:
        check("каталог шаблонов берётся из TEMPLATES_DIR", user_server.TEMPLATES_DIR == TMP)

        # 1. next_id на пустом каталоге -> 1
        check("next_id пустой каталог -> 1", templates_store.next_id(TMP) == 1)

        # 2. save пишет файл в форме 20.json
        rec = templates_store.save("Тест", STEPS, TMP)
        check("save вернул id=1", rec["id"] == 1)
        check("save вернул name", rec["name"] == "Тест")
        check("save вернул steps", rec["steps"] == STEPS)

        path = os.path.join(TMP, "1.json")
        check("файл создан", os.path.exists(path))
        import json
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        check("ключи файла совпадают с 20.json", set(data.keys()) == {"id", "name", "description", "example_output"})
        check("id в файле", data["id"] == 1)
        check("name в файле", data["name"] == "Тест")
        check("description непустое", isinstance(data["description"], str) and len(data["description"]) > 0)
        check("example_output.template == recorded", data["example_output"]["template"] == "recorded")
        check("example_output.steps == steps", data["example_output"]["steps"] == STEPS)

        # 3. next_id после одного сохранения -> 2
        check("next_id после первого сохранения -> 2", templates_store.next_id(TMP) == 2)

        rec2 = templates_store.save("Второй", STEPS, TMP)
        check("save вернул id=2", rec2["id"] == 2)
        check("next_id после двух сохранений -> 3", templates_store.next_id(TMP) == 3)

        # 4. save с пустыми шагами -> ValueError
        try:
            templates_store.save("Пусто", [], TMP)
            check("save с пустыми шагами кидает ValueError", False)
        except ValueError:
            check("save с пустыми шагами кидает ValueError", True)

        try:
            templates_store.save("Не список", "не список", TMP)
            check("save с не-списком кидает ValueError", False)
        except ValueError:
            check("save с не-списком кидает ValueError", True)

        # 5. list_all
        all_tpl = templates_store.list_all(TMP)
        check("list_all вернул 2 шаблона", len(all_tpl) == 2)
        check("list_all отсортирован по id", [t["id"] for t in all_tpl] == [1, 2])
        check("list_all элемент имеет id/name/steps/skill",
              set(all_tpl[0].keys()) == {"id", "name", "steps", "skill"})
        check("list_all: у шаблона без навыка skill=None", all_tpl[0]["skill"] is None)

        # 6. get
        got = templates_store.get(1, TMP)
        check("get вернул полный словарь", got is not None and set(got.keys()) == {"id", "name", "description", "example_output"})
        check("get несуществующего -> None", templates_store.get(999, TMP) is None)

        # 6b. set_skill: обогащение дописывается ПОСЛЕ сохранения — упавший
        #     вызов ИИ не должен стоить врачу записанного шаблона.
        skill = {"name": "Дневниковая запись", "triggers": ["дневник"],
                 "slots": [{"step": 0, "key": "text", "label": "", "skeleton": ""}]}
        check("set_skill -> True", templates_store.set_skill(1, skill, TMP, name="Дневниковая запись") is True)
        after = templates_store.get(1, TMP)
        check("set_skill записал навык", after.get("skill") == skill)
        check("set_skill обновил имя", after.get("name") == "Дневниковая запись")
        check("set_skill не тронул шаги", after["example_output"]["steps"] == got["example_output"]["steps"])
        check("set_skill отсутствующего -> False", templates_store.set_skill(999, skill, TMP) is False)
        check("list_all отдаёт навык", templates_store.list_all(TMP)[0]["skill"] == skill)

        # 7. list_all на отсутствующем каталоге -> []
        missing_dir = os.path.join(TMP, "no-such-dir")
        check("list_all отсутствующего каталога -> []", templates_store.list_all(missing_dir) == [])

        # 8. next_id на отсутствующем каталоге -> 1
        check("next_id отсутствующего каталога -> 1", templates_store.next_id(missing_dir) == 1)

        # ── эндпоинты ──────────────────────────────────────────────
        # чистый каталог для эндпоинтов
        shutil.rmtree(TMP, ignore_errors=True)

        res = tpl_save({"name": "", "steps": []})
        check("/template/save без шагов -> ok=false", res["ok"] is False)

        res = tpl_save({"name": "Мой шаблон", "steps": STEPS})
        check("/template/save -> ok=true", res["ok"] is True)
        check("/template/save вернул id", res["id"] == 1)
        check("/template/save вернул имя", res["name"] == "Мой шаблон")

        res2 = tpl_save({"steps": STEPS})
        check("/template/save без имени -> ok=true", res2["ok"] is True)
        check("/template/save без имени -> имя по умолчанию", res2["name"] == "Без имени")

        res = tpl_list()
        check("/template/list -> ok=true", res["ok"] is True)
        check("/template/list вернул оба шаблона", len(res["templates"]) == 2)
        check("/template/list id по возрастанию", [t["id"] for t in res["templates"]] == [1, 2])
        check("/template/list вернул steps сохранённого шаблона", res["templates"][0]["steps"] == STEPS)

        res = tpl_delete({"id": 1})
        check("/template/delete -> deleted=true", res["ok"] is True and res["deleted"] is True)

        res = tpl_list()
        check("/template/list после удаления не содержит id=1", 1 not in [t["id"] for t in res["templates"]])

        res = tpl_delete({"id": 999})
        check("/template/delete отсутствующего -> deleted=false", res["ok"] is True and res["deleted"] is False)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)

    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print("\n{}/{} тестов прошло".format(len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
