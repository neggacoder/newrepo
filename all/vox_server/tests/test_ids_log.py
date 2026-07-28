"""
ids_log: извлечение id пациента со страницы medicalHistory и журнал ids.jsonl.

Запуск:  python vox_server/tests/test_ids_log.py
"""

import os
import sys
import json
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="ids-log-test-")
os.environ["PATIENTS_DIR"] = TMP

import ids_log       # noqa: E402
import vox_server as user_server   # noqa: E402

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


class FakeRequest:
    def __init__(self, body):
        self._body = body

    async def json(self):
        return self._body


URL = "https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186420#"

# Сохранённая страница: кавычки в onclick сериализованы как &#39;.
# В <title> НАРОЧНО другое имя: ФИО должно браться из div.patient-info.
# «Посмотреть» с типом '12' стоит РАНЬШЕ типа '1' — watch выбирается по типу,
# а не по первому попавшемуся. Kendo-шаблон в конце не должен матчиться.
SAVED = (
    '<html><head><title>БЕЛАЛОВА РАЯНА РОМАНОВНА 04.06.2019 - Dmed.Стационар</title></head><body>'
    '<div class="text-right patient-info"> <h5>№981 АМАНТАЙ ДИДАР ДАРХАНҰЛЫ 10.12.2017&nbsp;(8) </h5> </div>'
    '<ul class="mh-navigation nav nav-pills big-screen">'
    '<li role="presentation" class="mh-main"><a href="#" onclick="onMainClick();">Главная</a></li>'
    '<li role="presentation" class="mh-medicalrecords active">'
    '<a href="https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186420#"'
    ' onclick="onMedicalRecordsClick();">Медицинские записи</a></li>'
    '</ul>'
    '<ul class="dropdown-menu right-0 left-auto">'
    '<li><a href="https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186420#"'
    ' onclick="PatientMedicalRecordList.onEditButtonClick(0, &#39;3136436&#39;, &#39;12&#39;)">Первичный осмотр</a></li>'
    '<li><a href="https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186420#"'
    ' onclick="PatientMedicalRecordList.onEditButtonClick(0, &#39;3136436&#39;, &#39;2&#39;)">Осмотр врача отделения</a></li>'
    '</ul>'
    '<a onclick="PatientMedicalRecordList.onViewButtonClick(&#39;21641095&#39;, &#39;12&#39;);">Посмотреть</a>'
    '<a onclick="PatientMedicalRecordList.onEditButtonClick(&#39;21641095&#39;, &#39;3136436&#39;, &#39;12&#39;);">Изменить</a>'
    '<a onclick="PatientMedicalRecordList.onViewButtonClick(&#39;21641017&#39;, &#39;1&#39;);">Посмотреть</a>'
    "<a onclick=\"PatientMedicalRecordList.onViewButtonClick('#: ID #', '#: MedicalRecordTypeID #');\">Посмотреть</a>"
    '</body></html>'
)

# Живой DOM: outerHTML отдаёт обычные одинарные кавычки.
LIVE = SAVED.replace("&#39;", "'")

EXPECTED = {
    "medicalHistory": 2186420,
    "editMedicalRecord": 3136436,
    "watch": 21641017,
    "name": "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ",
}

EXPECTED_LINE = ('{"medicalHistory": 2186420, "editMedicalRecord": 3136436, '
                 '"watch": 21641017, "name": "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ"}')


def read_lines(base_dir):
    path = os.path.join(base_dir, "ids.jsonl")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return [line for line in f.read().splitlines() if line.strip()]


def main():
    tmp2 = tempfile.mkdtemp(prefix="ids-log-remember-")
    try:
        # ── extract_ids ───────────────────────────────────────────────
        check("сохранённая страница (&#39;) разбирается",
              ids_log.extract_ids(SAVED, URL) == EXPECTED)
        check("живой DOM (обычные кавычки) разбирается",
              ids_log.extract_ids(LIVE, URL) == EXPECTED)

        # условие сбора: страница medicalHistory И активная вкладка записей
        check("другой url (myCab) -> None даже с полным html",
              ids_log.extract_ids(SAVED, "https://hospital-akt.dmed.kz/myCab") is None)
        inactive = SAVED.replace('class="mh-medicalrecords active"',
                                 'class="mh-medicalrecords"')
        check("вкладка записей не активна -> None",
              ids_log.extract_ids(inactive, URL) is None)

        # watch: только запись с типом '1', а не первая попавшаяся
        entry = ids_log.extract_ids(SAVED, URL)
        check("watch взят у типа '1', тип '12' пропущен",
              entry and entry["watch"] == 21641017)

        no_type1 = SAVED.replace("&#39;21641017&#39;, &#39;1&#39;",
                                 "&#39;21641017&#39;, &#39;3&#39;")
        entry = ids_log.extract_ids(no_type1, URL)
        check("нет записи типа '1' -> watch пустой",
              entry is not None and entry["watch"] is None)

        # editMedicalRecord: без dropdown берётся из строки грида
        no_dropdown = SAVED.replace("onEditButtonClick(0, ", "ignored(0, ")
        entry = ids_log.extract_ids(no_dropdown, URL)
        check("без dropdown editMedicalRecord взят из грида",
              entry is not None and entry["editMedicalRecord"] == 3136436)

        # medicalHistory: url без id -> из ссылки в html
        entry = ids_log.extract_ids(SAVED, "https://hospital-akt.dmed.kz/medicalHistory/medicalHistory")
        check("medicalHistory из html, когда в url нет id",
              entry is not None and entry["medicalHistory"] == 2186420)

        # чужая страница — журналить нечего
        check("не страница пациента -> None",
              ids_log.extract_ids("<html><body>ничего</body></html>",
                                  "https://hospital-akt.dmed.kz/myCab") is None)

        # ФИО: сохранённый файл портит «№» кодировкой («в„–981 ...») — имя всё
        # равно должно выделяться
        mojibake = SAVED.replace("№981", "в„–981")
        entry = ids_log.extract_ids(mojibake, URL)
        check("битый префикс номера не мешает ФИО",
              entry is not None and entry["name"] == "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ")

        # ФИО: div нет — откат на <title>
        no_div = SAVED.replace("patient-info", "patient-info-hidden")
        entry = ids_log.extract_ids(no_div, URL)
        check("без div ФИО берётся из title",
              entry is not None and entry["name"] == "БЕЛАЛОВА РАЯНА РОМАНОВНА")

        # ── remember ──────────────────────────────────────────────────
        check("первая запись меняет файл",
              ids_log.remember(dict(EXPECTED), tmp2) is True)
        lines = read_lines(tmp2)
        check("в файле ровно строка из задания",
              lines == [EXPECTED_LINE])

        check("повторный скан не плодит дублей",
              ids_log.remember(dict(EXPECTED), tmp2) is False and
              read_lines(tmp2) == [EXPECTED_LINE])

        check("запись без якорных id не пишется",
              ids_log.remember({"name": "БЕЗ ИД"}, tmp2) is False and
              read_lines(tmp2) == [EXPECTED_LINE])

        partial = {"medicalHistory": 111, "editMedicalRecord": 222,
                   "watch": None, "name": ""}
        ids_log.remember(partial, tmp2)
        fuller = {"medicalHistory": 111, "editMedicalRecord": 222,
                  "watch": 333, "name": "ИМЯ"}
        check("дозаполнение меняет файл", ids_log.remember(fuller, tmp2) is True)
        rows = [json.loads(line) for line in read_lines(tmp2)]
        check("две строки: два пациента", len(rows) == 2)
        upd = [r for r in rows if r["medicalHistory"] == 111][0]
        check("пустые watch/name дозаполнились",
              upd["watch"] == 333 and upd["name"] == "ИМЯ")

        # пустым нельзя затереть непустое
        ids_log.remember(partial, tmp2)
        rows = [json.loads(line) for line in read_lines(tmp2)]
        upd = [r for r in rows if r["medicalHistory"] == 111][0]
        check("пустое не затирает заполненное",
              upd["watch"] == 333 and upd["name"] == "ИМЯ")

        # ── хук в /scan ───────────────────────────────────────────────
        check("каталог журнала берётся из PATIENTS_DIR",
              user_server.PATIENTS_DIR == TMP)
        asyncio.run(user_server.scan(FakeRequest(
            {"html": SAVED, "values": {}, "url": URL})))
        check("после /scan появился ids.jsonl",
              read_lines(TMP) == [EXPECTED_LINE])

        # скан чужой страницы файл не трогает
        asyncio.run(user_server.scan(FakeRequest(
            {"html": "<html><body>ничего</body></html>",
             "url": "https://hospital-akt.dmed.kz/myCab"})))
        check("чужая страница не пишет в журнал",
              read_lines(TMP) == [EXPECTED_LINE])

        # ── /ids/save: расширение шлёт уже извлечённую запись ─────────
        res = asyncio.run(user_server.ids_save(FakeRequest({"entry": {
            "medicalHistory": 555, "editMedicalRecord": 666,
            "watch": None, "name": "ТЕСТ ТЕСТОВ"}})))
        rows = [json.loads(line) for line in read_lines(TMP)]
        check("/ids/save дописал строку",
              res["ok"] is True and
              any(r.get("medicalHistory") == 555 for r in rows))

        res = asyncio.run(user_server.ids_save(FakeRequest(
            {"entry": {"name": "БЕЗ ИД"}})))
        check("/ids/save без якорного id -> ok=false", res["ok"] is False)
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)
        shutil.rmtree(TMP, ignore_errors=True)

    failed = [name for name, ok in checks if not ok]
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    print("\n{} / {}".format(len(checks) - len(failed), len(checks)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
