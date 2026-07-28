"""
/patient/get и /patient/save на локальном сервере.

Запуск:  python vox_server/tests/test_patient_endpoints.py
"""

import os
import sys
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="patient-endpoints-test-")
os.environ["PATIENTS_DIR"] = TMP

import vox_server as user_server  # noqa: E402

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


def get(body):
    return asyncio.run(user_server.patient_get(FakeRequest(body)))


def save(body):
    return asyncio.run(user_server.patient_save(FakeRequest(body)))


def main():
    try:
        check("каталог карточек берётся из PATIENTS_DIR", user_server.PATIENTS_DIR == TMP)

        # 1. Карточки ещё нет.
        res = get({"ids": {"patientAdmissionRegisterID": "3136382"}})
        check("нет карточки -> found=false", res["found"] is False and res["patient"] is None)

        # 2. Без идентификаторов — отказ.
        res = save({"ids": {}})
        check("save без id -> ok=false", res["ok"] is False)
        res = get({"ids": {}})
        check("get без id -> found=false", res["found"] is False)

        # 3. Сохраняем.
        res = save({
            "ids": {"patientAdmissionRegisterID": "3136382", "medicalHistoryID": "2186386"},
            "full_name": "Белалова Раяна Романовна",
            "records": [{"type": "Осмотр", "date": "01.07.2026", "text": "Кашель"}],
        })
        check("save -> ok=true", res["ok"] is True)
        check("save вернул ключ", res["key"] == "3136382")

        # 4. Читаем по основному ключу.
        res = get({"ids": {"patientAdmissionRegisterID": "3136382"}})
        check("get по par -> found", res["found"] is True)
        check("get вернул ФИО", res["patient"]["full_name"] == "Белалова Раяна Романовна")
        check("get вернул запись", res["patient"]["records"][0]["text"] == "Кашель")

        # 5. Читаем по medicalHistoryID — тот самый случай, ради которого нужен индекс.
        res = get({"ids": {"medicalHistoryID": "2186386"}})
        check("get по mh через индекс -> found", res["found"] is True)
        check("get по mh вернул ту же карточку", res["patient"]["key"] == "3136382")

        # 6. Заметка врача переживает автосохранение без неё.
        save({"ids": {"patientAdmissionRegisterID": "3136382"}, "any_information": "аллергия на пенициллин"})
        save({"ids": {"patientAdmissionRegisterID": "3136382"},
              "records": [{"type": "Дневник", "date": "05.07.2026", "text": "Лучше"}]})
        res = get({"ids": {"patientAdmissionRegisterID": "3136382"}})
        check("заметка не потерялась", res["patient"]["any_information"] == "аллергия на пенициллин")
        check("новая запись добавилась", len(res["patient"]["records"]) == 2)

        # 7. Сохранение по medicalHistoryID попадает в ту же карточку, а не создаёт новую.
        save({"ids": {"medicalHistoryID": "2186386"}, "full_name": "Белалова Р. Р."})
        res = get({"ids": {"patientAdmissionRegisterID": "3136382"}})
        check("save по mh обновил существующую карточку", res["patient"]["full_name"] == "Белалова Р. Р.")
        files = [f for f in os.listdir(TMP) if f.endswith(".json") and f != "index.json"]
        check("вторая карточка не создалась", len(files) == 1)

        # 8. Сохранение по одному лишь неизвестному medicalHistoryID — некуда писать.
        res = save({"ids": {"medicalHistoryID": "999999"}, "full_name": "Неизвестный"})
        check("неизвестный mh без par -> ok=false", res["ok"] is False)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)

    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print("\n{}/{} тестов прошло".format(len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
