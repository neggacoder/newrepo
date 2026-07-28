"""
Декодер мед. записи: ответ ИИ -> строгий план шагов.

Запуск:  python server/tests/test_medrecord.py
"""

import os
import sys

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

import medrecord  # noqa: E402

URL = "https://hospital-akt.dmed.kz/patientMedicalRecord/editMedicalRecord?id=0"

BLOCKS = [
    {"id": "-1", "name": "Жалобы при поступлении", "text": "", "empty": True},
    {"id": "-2", "name": "Анамнез заболевания", "text": "", "empty": True},
    {"id": "-3", "name": "Анамнез жизни", "text": "Без особенностей", "empty": False},
]

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


def main():
    # 1. Базовая раскладка: клик по блоку, затем запись текста.
    steps = medrecord.decode({"-1": "Кашель"}, BLOCKS, URL)
    check("два шага на блок + финальный клик", len(steps) == 3)
    check("первый шаг — клик по блоку", steps[0] == {
        "selector": '#divFieldData a[data-id="-1"]', "method": "click",
        "type_write": "write", "value": None, "address": URL})
    check("второй шаг — запись в editor_0", steps[1] == {
        "selector": "#editor_0", "method": "write",
        "type_write": "write", "value": "Кашель", "address": URL})
    check("последний шаг — клик по первому блоку (коммит)",
          steps[-1]["method"] == "click" and steps[-1]["selector"] == '#divFieldData a[data-id="-1"]')

    # 2. Непустые блоки не трогаем, даже если ИИ их вернул.
    steps = medrecord.decode({"-3": "Переписать всё"}, BLOCKS, URL)
    check("непустой блок не попадает в план", steps == [])

    # 3. Неизвестные и мусорные id отбрасываются.
    steps = medrecord.decode({"-99": "x", "abc": "y", "-1": "Кашель"}, BLOCKS, URL)
    check("неизвестный id отброшен", len(steps) == 3)
    check("мусорный id не создал селектор", all("abc" not in s["selector"] for s in steps))

    # 4. Пустое/пробельное значение не создаёт шагов.
    check("пустая строка игнорируется", medrecord.decode({"-1": "   "}, BLOCKS, URL) == [])
    check("None игнорируется", medrecord.decode({"-1": None}, BLOCKS, URL) == [])
    check("пустой ответ ИИ -> пустой план", medrecord.decode({}, BLOCKS, URL) == [])

    # 5. Порядок блоков — как на странице, а не как в ответе ИИ.
    steps = medrecord.decode({"-2": "Б", "-1": "А"}, BLOCKS, URL)
    check("порядок шагов повторяет порядок блоков",
          steps[0]["selector"] == '#divFieldData a[data-id="-1"]' and
          steps[2]["selector"] == '#divFieldData a[data-id="-2"]')

    # 6. Никогда не жмём «Сохранить».
    check("нет шага сохранения", all("btnSaveMedicalRecord" not in s["selector"] for s in steps))

    # 7. Нормализация текста: CRLF и хвостовые пробелы.
    steps = medrecord.decode({"-1": "А\r\nБ  \n\n\n\nВ\n"}, BLOCKS, URL)
    check("CRLF -> LF, лишние пустые строки схлопнуты", steps[1]["value"] == "А\nБ\n\nВ")

    # 8. Значение всегда строка (исполнитель расширения делает String(value)).
    steps = medrecord.decode({"-1": 42}, BLOCKS, URL)
    check("число приводится к строке", steps[1]["value"] == "42")

    # 9. Промпт содержит имена блоков и текст истории.
    user = medrecord.build_user_prompt(BLOCKS, [{"type": "Осмотр", "date": "01.07.2026", "text": "Кашель"}])
    check("промпт содержит имя блока", "Жалобы при поступлении" in user)
    check("промпт содержит id блока", '"-1"' in user)
    check("промпт содержит текст истории", "Кашель" in user)
    check("промпт содержит дату записи", "01.07.2026" in user)

    # 10. Системный промпт запрещает выдумывать и требует строгий JSON.
    check("системный промпт требует JSON", '{"blocks"' in medrecord.SYSTEM_PROMPT)

    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print("\n{}/{} тестов прошло".format(len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
