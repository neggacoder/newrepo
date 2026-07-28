"""
Навыки: шаблон как голосовая команда (skills.py).

Проверяем ровно то, что защищает план от модели: слот не может уехать на
несуществующий шаг или на шаг-клик, чужие ключи отбрасываются, подстановка
не портит исходный шаблон, а сопоставление честно передаёт сомнительный
случай арбитру вместо того, чтобы запустить не тот сценарий.

Запуск:  python vox_server/tests/test_skills.py
"""

import os
import sys

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

import skills  # noqa: E402

STEPS = [
    {"selector": "ul > li:nth-child(2) > a", "method": "click", "type_write": "write",
     "value": None, "address": "/doctor", "description": "Медицинские записи"},
    {"selector": "#btn-add", "method": "click", "type_write": "write",
     "value": None, "address": "/medicalHistory", "description": "Добавить"},
    {"selector": "#editor_1", "method": "write", "type_write": "write",
     "value": "Состояние удовлетворительное. Жалоб нет. АД 120/80.",
     "address": "/medicalHistory", "description": "Дневник"},
]

SKILL = {
    "name": "Дневниковая запись",
    "triggers": ["новая дневниковая запись", "заполни дневник"],
    "slots": [{"step": 2, "key": "text", "label": "текст дневника",
               "skeleton": "Состояние … Жалоб … АД …"}],
}


# ─────────────────────────── основы слов и сопоставление ───────────────────
def test_stems_snimayut_okonchaniya():
    # Врач не повторит триггер слово в слово: «дневниковая» / «дневниковую».
    assert skills.stems("дневниковая") == skills.stems("дневниковую")
    assert skills.stems("новая запись") == skills.stems("новую записи")
    # Стоп-слова не должны создавать ложное сходство между разными командами.
    assert skills.stems("и в на для") == set()


CARDS = [
    {"id": 1, "name": "Дневниковая запись", "triggers": ["новая дневниковая запись", "заполни дневник"]},
    {"id": 2, "name": "Выписной эпикриз", "triggers": ["выписной эпикриз", "выписка пациента"]},
]


def test_match_uverennoe_sovpadenie_bez_ii():
    m = skills.match("заполни дневник", CARDS)
    assert m["confident"] is True, m
    assert m["id"] == 1
    assert m["candidates"] == []      # арбитра не зовём вовсе


def test_match_drugimi_slovami():
    m = skills.match("заведи новую дневниковую запись пациенту", CARDS)
    assert m["confident"] is True and m["id"] == 1, m


def test_match_nichego_ne_podoshlo():
    m = skills.match("напечатай направление в лабораторию", CARDS)
    assert m["id"] is None and m["candidates"] == [], m


def test_match_pustaya_komanda():
    assert skills.match("", CARDS)["id"] is None
    assert skills.match("заполни дневник", [])["id"] is None


def test_match_nichya_uhodit_k_arbitru():
    # Два похожих навыка: молча выбирать любой нельзя — врач получит не то.
    cards = [
        {"id": 1, "name": "Дневник в отделении", "triggers": ["дневник"]},
        {"id": 2, "name": "Дневник в реанимации", "triggers": ["дневник"]},
    ]
    m = skills.match("дневник", cards)
    assert m["confident"] is False, m
    assert [c["id"] for c in m["candidates"]] == [1, 2]


def test_cards_shablon_bez_navyka_ne_teryaetsya():
    # Записан до появления навыков: имени достаточно, чтобы совпасть.
    cs = skills.cards([{"id": 7, "name": "Выписной эпикриз", "steps": STEPS, "skill": None}])
    assert cs == [{"id": 7, "name": "Выписной эпикриз", "triggers": []}]
    # А вот шаблон без шагов запускать нечем.
    assert skills.cards([{"id": 8, "name": "Пусто", "steps": []}]) == []


CARD_TPL = {"id": 4, "name": "Записанный шаблон", "steps": STEPS,
            "skill": {"name": "Выписной эпикриз",
                      "triggers": ["создай выписной эпикриз"], "slots": []}}


def test_cards_katalog_glavnee_shablona():
    # Врач поправил фразу в types.json — она и должна работать.
    catalog = [{"id": 4, "name": "Выписной эпикриз", "triggers": ["выписка"], "fields": []}]
    got = skills.cards([CARD_TPL], catalog)
    assert got == [{"id": 4, "name": "Выписной эпикриз", "triggers": ["выписка"]}], got


def test_cards_bez_zapisi_otkat_na_shablon():
    # Записи в каталоге нет вообще -> берём фразы из файла шаблона.
    assert skills.cards([CARD_TPL], [])[0]["triggers"] == ["создай выписной эпикриз"]
    assert skills.cards([CARD_TPL])[0]["triggers"] == ["создай выписной эпикриз"]


def test_cards_pustye_frazy_vyklyuchayut_golos():
    # Запись ЕСТЬ, фраз нет -> врач намеренно выключил голосовой запуск.
    # Шаблон должен выпасть из кандидатов ЦЕЛИКОМ, иначе он всё равно
    # совпадёт по имени, и «выключил» окажется неправдой.
    catalog = [{"id": 4, "name": "Выписной эпикриз", "triggers": [], "fields": []}]
    assert skills.cards([CARD_TPL], catalog) == []


def test_cards_bitaya_zapis_kataloga_ne_lomaet():
    catalog = ["не словарь", {"id": "нет"}, {"нет": "id"}]
    assert skills.cards([CARD_TPL], catalog)[0]["triggers"] == ["создай выписной эпикриз"]


def test_cards_osirotevshaya_zapis_ignoriruetsya():
    # Запись каталога ссылается на удалённый шаблон: исполнять нечего,
    # в кандидаты она попасть не должна (sync уберёт её позже).
    catalog = [{"id": 999, "name": "Призрак", "triggers": ["призрак"], "fields": []}]
    got = skills.cards([CARD_TPL], catalog)
    assert [c["id"] for c in got] == [4], got


# ─────────────────────────── обогащение (decode_skill) ─────────────────────
def test_decode_skill_normalnyy_otvet():
    got = skills.decode_skill({
        "name": "  Дневниковая   запись ",
        "triggers": ["Заполни дневник", "заполни дневник", "  "],
        "slots": [{"step": 2, "key": "Text", "label": "текст", "skeleton": "Состояние …"}],
    }, STEPS)
    assert got["name"] == "Дневниковая запись"      # схлопнули пробелы
    assert got["triggers"] == ["заполни дневник"]   # дубль и пустышка убраны
    assert got["slots"] == [{"step": 2, "key": "text", "label": "текст", "skeleton": "Состояние …"}]


def test_decode_skill_slot_tolko_na_shag_vvoda():
    # Модель указала шаг-КЛИК — подстановка туда испортила бы план.
    # Слот на шаге 0 отброшен; шаг 2 (реальный ввод) достроен кодом.
    got = skills.decode_skill({"name": "X", "slots": [{"step": 0, "key": "a"}]}, STEPS)
    assert [s["step"] for s in got["slots"]] == [2]


# ─────────────────────────── ensure_slots ──────────────────────────────────
def test_ensure_slots_dostraivaet_propushchennoe_pole():
    # Главная регрессия: модель вернула slots=[] (так и вышло с эпикризом #4),
    # и текст поля навсегда остался бы текстом из записи.
    got = skills.ensure_slots(STEPS, {"name": "X", "triggers": ["x"], "slots": []})
    assert [s["step"] for s in got["slots"]] == [2]
    assert got["slots"][0]["key"] == "field_2"


def test_ensure_slots_dlya_starogo_shablona_bez_navyka():
    got = skills.ensure_slots(STEPS, {})
    assert [s["step"] for s in got["slots"]] == [2]
    assert got["slots"][0]["label"] == "текст записи"   # поле одно — подпись говорящая


def test_ensure_slots_ne_dubliruet_uzhe_opisannoe():
    got = skills.ensure_slots(STEPS, SKILL)
    assert len(got["slots"]) == 1
    assert got["slots"][0]["key"] == "text"             # авторский слот не затёрт
    assert got["slots"][0]["skeleton"] == "Состояние … Жалоб … АД …"


def test_ensure_slots_ne_beret_podpis_iz_description():
    # description шага ввода — это то, что врач НАПЕЧАТАЛ при записи, то есть
    # данные прошлого пациента. Подпись уходит в промпт на каждой команде.
    steps = [{"method": "write", "value": "Жалобы на головные боли",
              "description": "Жалобы на головные боли.блаблабла*[align=\"right\"] {"}]
    got = skills.ensure_slots(steps, {})
    assert "блаблабла" not in got["slots"][0]["label"]
    assert "головные" not in got["slots"][0]["label"]


def test_ensure_slots_neskolko_poley_numeruyutsya():
    steps = [{"method": "write", "value": "a"}, {"method": "click"}, {"method": "write", "value": "b"}]
    got = skills.ensure_slots(steps, {})
    assert [s["step"] for s in got["slots"]] == [0, 2]
    assert [s["label"] for s in got["slots"]] == ["поле ввода 1", "поле ввода 2"]


def test_ensure_slots_ne_portit_ishodnyy_navyk():
    src = {"name": "X", "slots": []}
    skills.ensure_slots(STEPS, src)
    assert src["slots"] == []


def test_ensure_slots_bez_poley_vvoda():
    nav = [{"method": "click", "selector": "#a"}]
    assert skills.ensure_slots(nav, {})["slots"] == []


def test_decode_skill_slot_za_granicey_spiska():
    # Выдуманные номера отброшены, но реальный шаг ввода (2) достроен кодом —
    # иначе поле осталось бы незаполняемым из-за ошибки модели.
    got = skills.decode_skill({"name": "X", "slots": [{"step": 99, "key": "a"},
                                                      {"step": "нет", "key": "b"}]}, STEPS)
    assert [s["step"] for s in got["slots"]] == [2]
    assert [s["key"] for s in got["slots"]] == ["field_2"]


def test_decode_skill_dubli_shagov_i_klyuchey():
    got = skills.decode_skill({"name": "X", "slots": [
        {"step": 2, "key": "text"},
        {"step": 2, "key": "other"},     # тот же шаг
    ]}, STEPS)
    assert len(got["slots"]) == 1


def test_decode_skill_musor():
    assert skills.decode_skill(None, STEPS) is None
    assert skills.decode_skill({}, STEPS) is None
    assert skills.decode_skill({"name": "", "triggers": [], "slots": []}, STEPS) is None


def test_slim_steps_bez_selektorov():
    # Селекторы Damumed — сотни символов на шаг; в промпте им делать нечего.
    slim = skills.slim_steps(STEPS)
    assert all("selector" not in s for s in slim)
    assert slim[0] == {"i": 0, "method": "click", "description": "Медицинские записи"}
    assert slim[2]["value"].startswith("Состояние удовлетворительное")
    prompt = skills.build_enrich_prompt("Записанный шаблон", STEPS)
    assert "ul > li" not in prompt


# ─────────────────────────── арбитр ────────────────────────────────────────
def test_pick_tiebreak():
    cands = [{"id": 1}, {"id": 2}]
    assert skills.pick_tiebreak({"id": 2}, cands) == 2
    assert skills.pick_tiebreak({"id": "2"}, cands) == 2      # строку принимаем
    assert skills.pick_tiebreak({"id": 99}, cands) is None    # не из списка
    assert skills.pick_tiebreak({"id": None}, cands) is None
    assert skills.pick_tiebreak(None, cands) is None


# ─────────────────────────── слоты ─────────────────────────────────────────
def test_decode_slots_tolko_svoi_klyuchi():
    got = skills.decode_slots({"text": " Жалоб нет ", "чужой": "x", "пусто": "  "}, SKILL)
    assert got == {"text": "Жалоб нет"}


def test_decode_slots_musor():
    assert skills.decode_slots(None, SKILL) == {}
    assert skills.decode_slots({"text": 42}, SKILL) == {}


def test_apply_slots_podstavlyaet_i_ne_portit_original():
    out = skills.apply_slots(STEPS, SKILL, {"text": "Жалоб нет. АД 130/85."})
    assert out[2]["value"] == "Жалоб нет. АД 130/85."
    assert out[0] == STEPS[0]
    # Шаблон на диске один на все запуски — исходник обязан остаться прежним.
    assert STEPS[2]["value"] == "Состояние удовлетворительное. Жалоб нет. АД 120/80."


def test_apply_slots_bez_znacheniy_otdaet_shablon_kak_est():
    out = skills.apply_slots(STEPS, SKILL, {})
    assert out == STEPS
    assert skills.apply_slots(STEPS, {}, {}) == STEPS


def test_apply_slots_slot_na_shag_klika_ignoriruetsya():
    # Защита на исполнении, а не только на разборе: даже если такой слот
    # попал в файл руками, значение в шаг-клик не уедет.
    bad = {"slots": [{"step": 0, "key": "text"}]}
    out = skills.apply_slots(STEPS, bad, {"text": "нельзя"})
    assert out[0]["value"] is None


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_") or not callable(fn):
            continue
        try:
            fn()
            print("ok   ", name)
        except AssertionError as e:
            failed += 1
            print("FAIL ", name, "->", e)
    print("\nпровалено:", failed)
    sys.exit(1 if failed else 0)
