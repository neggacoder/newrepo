"""
Каталог голосовых типов (types.json).

Главное, что здесь защищается: ручные формулировки врача принадлежат врачу.
upsert их не трогает, put затирает намеренно («↻» = переделай заново), а
удалённая фраза не воскресает из файла шаблона.

Запуск:  python vox_server/tests/test_types_store.py
"""

import os
import sys
import json
import shutil
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

import types_store  # noqa: E402

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


# Регистр, лишние пробелы и дубль — нарочно: врач правит файл руками и не
# обязан думать про нормализацию, её делает _norm.
ENTRY = {"id": 4, "name": "Создать выписной эпикриз",
         "triggers": ["Создай  выписной эпикриз", "сделай выписку", "сделай выписку"],
         "fields": ["текст записи"]}


def t_load_empty(tmp):
    data = types_store.load(tmp)
    check("нет файла -> пустой каталог", data == {"version": 1, "types": []})

    with open(os.path.join(tmp, "types.json"), "w", encoding="utf-8") as f:
        f.write("{ это не json")
    check("битый файл -> пустой каталог", types_store.load(tmp)["types"] == [])
    os.remove(os.path.join(tmp, "types.json"))


def t_upsert(tmp):
    check("upsert создал запись", types_store.upsert(ENTRY, tmp) is True)
    rows = types_store.load(tmp)["types"]
    check("запись одна", len(rows) == 1 and rows[0]["id"] == 4)
    check("регистр, пробелы и дубли нормализованы",
          rows[0]["triggers"] == ["создай выписной эпикриз", "сделай выписку"])

    # Врач поправил фразы руками.
    types_store.put({"id": 4, "name": "Создать выписной эпикриз",
                     "triggers": ["выписка"], "fields": []}, tmp)
    # Повторное сохранение шаблона НЕ должно их вернуть.
    check("повторный upsert не перезаписывает", types_store.upsert(ENTRY, tmp) is False)
    check("ручная правка уцелела", types_store.load(tmp)["types"][0]["triggers"] == ["выписка"])

    check("upsert без id -> False", types_store.upsert({"name": "X"}, tmp) is False)
    check("upsert мусора -> False", types_store.upsert("не словарь", tmp) is False)


def t_put(tmp):
    check("put перезаписал", types_store.put(ENTRY, tmp) is True)
    check("вернулись фразы от обогащения",
          types_store.load(tmp)["types"][0]["triggers"] == ["создай выписной эпикриз",
                                                            "сделай выписку"])


def t_triggers_for(tmp):
    check("фразы существующей записи",
          types_store.triggers_for(4, tmp) == ["создай выписной эпикриз", "сделай выписку"])
    # None и [] означают РАЗНОЕ: на этом различии стоит правило отката.
    check("записи нет вообще -> None", types_store.triggers_for(999, tmp) is None)
    types_store.put({"id": 7, "name": "Выключен", "triggers": [], "fields": []}, tmp)
    check("запись есть, фраз нет -> [] (голос выключен)", types_store.triggers_for(7, tmp) == [])


def t_remove(tmp):
    check("remove удалил", types_store.remove(7, tmp) is True)
    check("remove несуществующего -> False", types_store.remove(999, tmp) is False)
    check("остальное на месте", [r["id"] for r in types_store.load(tmp)["types"]] == [4])


def t_no_pii(tmp):
    raw = open(os.path.join(tmp, "types.json"), encoding="utf-8").read()
    check("в каталоге только фразы и имена, без текста пациента",
          "Жалобы" not in raw and "блаблабла" not in raw)


# Форма элемента templates_store.list_all(): id, name, steps, skill.
TPL_A = {
    "id": 4, "name": "Записанный шаблон",
    "steps": [{"method": "click", "selector": "#a"},
              {"method": "write", "selector": "#editor_0", "value": "текст"}],
    "skill": {"name": "Создать выписной эпикриз",
              "triggers": ["создай выписной эпикриз"],
              "slots": [{"step": 1, "key": "text", "label": "жалобы и анамнез",
                         "skeleton": "Жалобы на …"}]},
}
TPL_B = {
    "id": 9, "name": "Записанный шаблон",
    "steps": [{"method": "click", "selector": "#b"}],
    "skill": None,          # записан до появления навыков
}


def t_entry_from_template():
    got = types_store.entry_from_template(TPL_A)
    check("имя берётся из навыка", got["name"] == "Создать выписной эпикриз")
    check("фразы берутся из навыка", got["triggers"] == ["создай выписной эпикриз"])
    check("подписи полей из слотов", got["fields"] == ["жалобы и анамнез"])

    got = types_store.entry_from_template(TPL_B)
    check("без навыка: имя шаблона", got["name"] == "Записанный шаблон")
    check("без навыка: фраз нет", got["triggers"] == [])
    # ensure_slots достроит слот на шаг ввода — у TPL_B шагов ввода нет.
    check("без полей ввода: fields пуст", got["fields"] == [])
    check("мусор -> None", types_store.entry_from_template("не словарь") is None)


def t_sync():
    # СВОЙ каталог: в общем tmp предыдущие тесты уже оставили запись id=4,
    # и счётчик добавленных записей был бы другим.
    tmp = tempfile.mkdtemp(prefix="types-sync-test-")
    try:
        # Каталог пуст, шаблонов два -> обе записи добавлены.
        check("sync добил недостающие", types_store.sync([TPL_A, TPL_B], tmp) == 2)
        check("записи по id", [r["id"] for r in types_store.load(tmp)["types"]] == [4, 9])

        # Повторный sync ничего не меняет.
        check("повторный sync -> 0 изменений", types_store.sync([TPL_A, TPL_B], tmp) == 0)

        # Врач поправил фразы — sync их не трогает.
        types_store.put({"id": 4, "name": "Выписка", "triggers": ["выписка"], "fields": []}, tmp)
        types_store.sync([TPL_A, TPL_B], tmp)
        row = next(r for r in types_store.load(tmp)["types"] if r["id"] == 4)
        check("sync не трогает существующие записи", row["triggers"] == ["выписка"])

        # Шаблон удалён -> запись осиротела и убирается.
        check("sync убрал осиротевшую", types_store.sync([TPL_A], tmp) == 1)
        check("осталась только живая", [r["id"] for r in types_store.load(tmp)["types"]] == [4])

        # Пустой список шаблонов НЕ вычищает каталог: это защита от сбоя чтения
        # каталога шаблонов, а не команда «удали всё».
        check("пустой список шаблонов -> 0 изменений", types_store.sync([], tmp) == 0)
        check("каталог уцелел", len(types_store.load(tmp)["types"]) == 1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    tmp = tempfile.mkdtemp(prefix="types-store-test-")
    try:
        t_load_empty(tmp)
        t_upsert(tmp)
        t_put(tmp)
        t_triggers_for(tmp)
        t_remove(tmp)
        t_entry_from_template()
        t_sync()
        t_no_pii(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print(f"\n{len(checks) - len(failed)}/{len(checks)} тестов прошло")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
