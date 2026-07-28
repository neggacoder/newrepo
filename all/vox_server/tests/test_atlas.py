"""
Атлас страниц: карта, которую сервер строит наблюдением, и поиск пациента
в ids.jsonl для прямого перехода по адресу.

Главное, что здесь защищается: в atlas.json не должны попадать ЗНАЧЕНИЯ
параметров (там id пациентов), а поиск пациента по имени не должен угадывать
при неоднозначности — открыть чужую историю болезни хуже, чем не открыть.

Запуск:  python vox_server/tests/test_atlas.py
"""

import os
import sys
import json
import shutil
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

import atlas     # noqa: E402
import ids_log   # noqa: E402

HOST = "https://hospital-akt.dmed.kz"
checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


# ───────────────────────────── split ─────────────────────────────
def t_split():
    got = atlas.split(HOST + "/medicalHistory/medicalHistory?id=2195085&tab=2")
    check("split: origin", got[0] == HOST)
    check("split: путь", got[1] == "/medicalHistory/medicalHistory")
    check("split: только ИМЕНА параметров", got[2] == ["id", "tab"])
    check("split: значение id не возвращается", "2195085" not in json.dumps(got))
    check("split: хвостовой слэш срезан", atlas.split(HOST + "/doctor/")[1] == "/doctor")
    check("split: не-http -> None", atlas.split("javascript:void(0)") is None)
    check("split: мусор -> None", atlas.split("") is None)


def t_title():
    check("title: хвост Dmed убран",
          atlas.title_from_html("<title>Кабинет врача - Dmed.Стационар</title>") == "Кабинет врача")
    check("title: без тега -> пусто", atlas.title_from_html("<html></html>") == "")


# ───────────────────────────── learn / pages ─────────────────────────────
def t_learn(tmp):
    atlas.learn(HOST + "/doctor", tmp, title="Кабинет врача")
    atlas.learn(HOST + "/doctor", tmp)                       # второй заход
    atlas.learn(HOST + "/doctorTask/index?doctorTaskRole=2", tmp, title="Задачи врача")
    atlas.learn(HOST + "/medicalHistory/medicalHistory?id=2195085", tmp,
                title="История болезни", tab="mh-medicalrecords")

    raw = open(os.path.join(tmp, "atlas.json"), encoding="utf-8").read()
    check("ПДн: id пациента в файл не попал", "2195085" not in raw)
    check("ПДн: имя параметра сохранено", '"id"' in raw)

    data = atlas.load(tmp)
    doctor = next(p for p in data["pages"] if p["path"] == "/doctor")
    check("счётчик посещений растёт", doctor["hits"] == 2)
    check("заголовок не затёрт пустым", doctor["title"] == "Кабинет врача")

    mh = next(p for p in data["pages"] if p["path"] == "/medicalHistory/medicalHistory")
    check("вкладка запомнена", mh["tab"] == "mh-medicalrecords")

    # Ту же страницу открыли с другим набором параметров — имена объединяются.
    atlas.learn(HOST + "/doctorTask/index?status=10", tmp)
    task = next(p for p in atlas.load(tmp)["pages"] if p["path"] == "/doctorTask/index")
    check("имена параметров объединяются", task["params"] == ["doctorTaskRole", "status"])


def t_pages(tmp):
    rows = atlas.pages(tmp)
    check("выжимка отсортирована по частоте", rows[0]["path"] == "/doctor")
    check("выжимка компактна: только путь/заголовок/параметры",
          all(set(r.keys()) <= {"path", "title", "params"} for r in rows))
    check("в выжимке нет счётчиков и дат", "hits" not in json.dumps(rows))

    # Страница без заголовка — обычно ajax-ручка; модели она бесполезна.
    atlas.learn(HOST + "/Doctor/getMedicalHistories", tmp)
    check("страницы без заголовка в промпт не идут",
          all(r["path"] != "/Doctor/getMedicalHistories" for r in atlas.pages(tmp)))


def t_learn_steps(tmp2):
    steps = [
        {"method": "click", "address": HOST + "/doctor"},
        {"method": "click", "address": HOST + "/medicalHistory/medicalHistory"},
        {"method": "click", "address": HOST + "/medicalHistory/medicalHistory"},
        {"method": "write", "address": HOST + "/patientMedicalRecord/editMedicalRecord",
         "value": "Жалобы на головные боли"},
    ]
    n = atlas.learn_steps(steps, tmp2)
    check("шаблон обучил карту", n == 3)
    paths = {p["path"] for p in atlas.load(tmp2)["pages"]}
    check("страницы шаблона в карте",
          paths == {"/doctor", "/medicalHistory/medicalHistory", "/patientMedicalRecord/editMedicalRecord"})
    # value шага write — текст пациента, а не адрес: разбираться он не должен.
    check("текст поля не принят за адрес", "Жалобы" not in json.dumps(list(paths)))


def t_same_target():
    mh = HOST + "/medicalHistory/medicalHistory"
    check("тот же адрес целиком", atlas.same_target(mh + "?id=1", mh + "?id=1"))
    # Карточки двух пациентов отличаются ровно значением id: сравнение по пути
    # молча отменило бы переход от одного пациента к другому.
    check("разные пациенты — РАЗНЫЕ адреса", not atlas.same_target(mh + "?id=1", mh + "?id=2"))
    check("другой путь — другой адрес", not atlas.same_target(HOST + "/doctor", mh))
    check("мусор -> False", not atlas.same_target("", mh))


# ───────────────────────────── склейка плана ─────────────────────────────
# Шаблон «выписной эпикриз»: первый шаг — «дорога» (клик по гриду в кабинете),
# дальше работа уже на странице пациента.
TPL = [
    {"method": "click", "address": HOST + "/doctor", "description": "Выбрать"},
    {"method": "click", "address": HOST + "/medicalHistory/medicalHistory", "description": "Мед. записи"},
    {"method": "click", "address": HOST + "/patientMedicalRecord/editMedicalRecord", "description": "Да"},
    {"method": "write", "address": HOST + "/patientMedicalRecord/editMedicalRecord", "value": "текст"},
]
DEST = HOST + "/medicalHistory/medicalHistory?id=2186420"


def t_splice():
    steps, cut = atlas.splice_from(TPL, DEST)
    check("дорога до пациента отрезана", cut == 1)
    check("остаток начинается с работы на странице пациента",
          steps[0]["description"] == "Мед. записи" and len(steps) == 3)
    check("исходный план не испорчен", TPL[0]["description"] == "Выбрать")

    # План и так начинается на нужной странице — резать нечего.
    _, cut0 = atlas.splice_from(TPL[1:], DEST)
    check("уже на месте -> не режем", cut0 == 0)

    # Целевой страницы в шаблоне нет вовсе — склейка не применима.
    _, cutx = atlas.splice_from(TPL, HOST + "/archive")
    check("чужая страница -> не режем", cutx == 0)

    # До целевой страницы есть ВВОД: пропустить его значило бы потерять текст.
    risky = [{"method": "click", "address": HOST + "/doctor"},
             {"method": "write", "address": HOST + "/doctor", "value": "важное"},
             {"method": "click", "address": HOST + "/medicalHistory/medicalHistory"}]
    _, cut2 = atlas.splice_from(risky, DEST)
    check("шаг ввода в начале -> резать отказываемся", cut2 == 0)


def t_build_and_step():
    url = atlas.build_url(HOST, "/medicalHistory/medicalHistory", {"id": 2195085})
    check("адрес собран", url == HOST + "/medicalHistory/medicalHistory?id=2195085")
    check("пустые значения выброшены",
          atlas.build_url(HOST, "/doctor", {"id": None, "x": ""}) == HOST + "/doctor")

    st = atlas.goto_step(url, "карточка")
    check("goto: адрес в value", st["value"] == url)
    check("goto: address=None (шаг идёт на текущей странице)", st["address"] is None)
    check("goto: помечен навигационным", st["navigates"] is True)
    check("goto: метод goto", st["method"] == "goto")


# ───────────────────────────── поиск пациента ─────────────────────────────
ROWS = [
    {"medicalHistory": 2186420, "editMedicalRecord": 3136436, "name": "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ"},
    {"medicalHistory": 2195085, "editMedicalRecord": 3140001, "name": "ЕЛЕМЕС ИСЛАМИЯ АҚЫЛБЕКҚЫЗЫ"},
    {"medicalHistory": 2195090, "editMedicalRecord": 3140002, "name": "ЕЛЕМЕС АДИЛЬБЕК АКЫЛБЕКОВИЧ"},
    {"medicalHistory": 2196001, "editMedicalRecord": 3140003, "name": "АХМЕТОВА ГУЛЬНАРА СЕРИКОВНА"},
    {"medicalHistory": 2196002, "editMedicalRecord": 3140004, "name": "АХМЕТОВ БАУРЖАН СЕРИКОВИЧ"},
]


def t_find_by_name():
    got = ids_log.find_by_name("открой историю болезни Амантай Дидар", ROWS)
    check("пациент найден по фамилии и имени", got and got["medicalHistory"] == 2186420)

    got = ids_log.find_by_name("покажи карточку Исламии", ROWS)
    check("одного имени достаточно, если оно уникально",
          got and got["medicalHistory"] == 2195085)

    # Врач говорит склонённо — журнал хранит именительный.
    check("склонение: «Амантая» -> АМАНТАЙ",
          (ids_log.find_by_name("открой историю Амантая", ROWS) or {}).get("medicalHistory") == 2186420)
    check("склонение: «Гульнару» -> ГУЛЬНАРА",
          (ids_log.find_by_name("покажи Гульнару", ROWS) or {}).get("medicalHistory") == 2196001)

    # ДВА Елемеса: угадывать нельзя — врач будет писать в чужую историю.
    check("однофамильцы -> None (не угадываем)",
          ids_log.find_by_name("открой Елемес", ROWS) is None)
    # Точное слово важнее основы: «Ахметова» — это она, а не он.
    check("точное совпадение выигрывает у основы",
          (ids_log.find_by_name("открой Ахметова", ROWS) or {}).get("medicalHistory") == 2196001)
    # А склонённая форма подходит обоим Ахметовым — значит не переходим никуда.
    check("склонение, подходящее двоим -> None",
          ids_log.find_by_name("открой Ахметову", ROWS) is None)

    check("никого не назвали -> None", ids_log.find_by_name("открой мои задачи", ROWS) is None)
    check("пустая команда -> None", ids_log.find_by_name("", ROWS) is None)
    check("пустой журнал -> None", ids_log.find_by_name("открой Амантай", []) is None)


def main():
    tmp = tempfile.mkdtemp(prefix="atlas-test-")
    tmp2 = tempfile.mkdtemp(prefix="atlas-steps-test-")
    try:
        t_split()
        t_title()
        t_learn(tmp)
        t_pages(tmp)
        t_learn_steps(tmp2)
        t_same_target()
        t_splice()
        t_build_and_step()
        t_find_by_name()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(tmp2, ignore_errors=True)

    print()
    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print(f"\n{len(checks) - len(failed)}/{len(checks)} тестов прошло")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
