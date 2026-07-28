"""
Карточка пациента: слияние, индекс, лимиты.

Запуск:  python vox_server/tests/test_patients.py
"""

import os
import sys
import shutil
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

import patients  # noqa: E402

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


def main():
    tmp = tempfile.mkdtemp(prefix="patients-test-")
    try:
        # ── index_keys: типизированные ключи, чтобы одинаковые числа не сталкивались
        keys = patients.index_keys({"patientAdmissionRegisterID": "3136382", "medicalHistoryID": "2186386"})
        check("index_keys даёт префиксы типов", set(keys) == {"par:3136382", "mh:2186386"})
        check("index_keys пуст без id", patients.index_keys({}) == [])

        # ── resolve_key: находим карточку по medicalHistoryID через индекс
        index = {"par:3136382": "3136382", "mh:2186386": "3136382"}
        check("resolve по par", patients.resolve_key({"patientAdmissionRegisterID": "3136382"}, index) == "3136382")
        check("resolve по mh через индекс", patients.resolve_key({"medicalHistoryID": "2186386"}, index) == "3136382")
        check("resolve неизвестного mh -> None", patients.resolve_key({"medicalHistoryID": "999"}, index) is None)
        # par известен всегда — он и есть ключ, даже если индекса ещё нет
        check("resolve по par без индекса", patients.resolve_key({"patientAdmissionRegisterID": "777"}, {}) == "777")

        # ── merge_card: создание с нуля
        card = patients.merge_card(None, {
            "key": "3136382",
            "aliases": {"medicalHistoryID": "2186386"},
            "full_name": "Белалова Раяна Романовна",
            "records": [{"type": "Осмотр", "date": "01.07.2026", "text": "Кашель"}],
        })
        check("новая карточка: ключ", card["key"] == "3136382")
        check("новая карточка: алиас", card["aliases"]["medicalHistoryID"] == "2186386")
        check("новая карточка: одна запись", len(card["records"]) == 1)
        check("новая карточка: есть updated_at", bool(card.get("updated_at")))
        check("новая карточка: заметка пустая", card["any_information"] == "")

        # ── дедуп по (type, date), новые впереди
        merged = patients.merge_card(card, {
            "key": "3136382",
            "records": [
                {"type": "Дневник", "date": "05.07.2026", "text": "Лучше"},
                {"type": "Осмотр", "date": "01.07.2026", "text": "Кашель"},
            ],
        })
        check("дедуп: без дублей", len(merged["records"]) == 2)
        check("дедуп: новая запись впереди", merged["records"][0]["type"] == "Дневник")

        # ── обрезка до MAX_RECORDS
        many = patients.merge_card(merged, {"key": "3136382", "records": [
            {"type": "A", "date": "06.07.2026", "text": "a"},
            {"type": "B", "date": "07.07.2026", "text": "b"},
        ]})
        check("обрезка до MAX_RECORDS", len(many["records"]) == patients.MAX_RECORDS)

        # ── заметку врача нельзя затереть пустым
        with_note = patients.merge_card(card, {"key": "3136382", "any_information": "аллергия на пенициллин"})
        check("заметка записалась", with_note["any_information"] == "аллергия на пенициллин")
        kept = patients.merge_card(with_note, {"key": "3136382", "any_information": ""})
        check("пустая заметка не затирает", kept["any_information"] == "аллергия на пенициллин")
        kept2 = patients.merge_card(with_note, {"key": "3136382"})
        check("отсутствие заметки не затирает", kept2["any_information"] == "аллергия на пенициллин")

        # ── full_name не затирается пустым, алиасы накапливаются
        no_name = patients.merge_card(card, {"key": "3136382", "full_name": ""})
        check("пустое ФИО не затирает", no_name["full_name"] == "Белалова Раяна Романовна")
        more_alias = patients.merge_card(card, {"key": "3136382", "aliases": {"iin": "870312300247"}})
        check("алиасы накапливаются", more_alias["aliases"]["medicalHistoryID"] == "2186386"
              and more_alias["aliases"]["iin"] == "870312300247")

        # ── лимиты на длину
        long_card = patients.merge_card(None, {
            "key": "1", "any_information": "x" * 5000,
            "records": [{"type": "T", "date": "D", "text": "y" * 9000}],
        })
        check("заметка обрезана", len(long_card["any_information"]) == patients.MAX_NOTE_CHARS)
        check("текст записи обрезан", len(long_card["records"][0]["text"]) == patients.MAX_RECORD_CHARS)

        # ── диск: сохранить и прочитать, индекс обновился
        ids = {"patientAdmissionRegisterID": "3136382", "medicalHistoryID": "2186386"}
        patients.save_card(card, ids, tmp)
        check("карточка читается с диска", patients.load_card("3136382", tmp)["key"] == "3136382")
        idx = patients.load_index(tmp)
        check("индекс знает mh", idx.get("mh:2186386") == "3136382")

        # ── битый файл не роняет
        with open(os.path.join(tmp, "666.json"), "w", encoding="utf-8") as f:
            f.write("{не json")
        check("битая карточка -> None", patients.load_card("666", tmp) is None)
        with open(os.path.join(tmp, "index.json"), "w", encoding="utf-8") as f:
            f.write("[не json")
        check("битый индекс -> {}", patients.load_index(tmp) == {})

        check("несуществующая карточка -> None", patients.load_card("нет", tmp) is None)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print("\n{}/{} тестов прошло".format(len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
