"""
Роутер страниц: выбор страницы первым ИИ + шаги навигации, которые строит код.

Запуск:  python server/tests/test_router.py
"""

import os
import sys

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

import router  # noqa: E402

URL = "https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186386"

ROUTES = {
    "site": "hospital-akt.dmed.kz",
    "pages": [
        {
            "key": "medical_records",
            "name": "Мед. записи пациента",
            "description": "список осмотров и выписок",
            "tab_class": "mh-medicalrecords",
            "path": [{"selector": "ul.mh-navigation .mh-medicalrecords a", "description": "вкладка"}],
            "elements_in": "medical_records.json",
        },
        {
            "key": "diaries",
            "name": "Дневники",
            "description": "дневниковые записи",
            "tab_class": "mh-diaries",
            "path": [{"selector": "ul.mh-navigation .mh-diaries a", "description": "вкладка"}],
            "elements_in": "diaries.json",
        },
    ],
}

checks = []


def check(name, cond):
    checks.append((name, bool(cond)))


def main():
    # ── pick_page
    check("валидный ключ", router.pick_page({"page": "diaries"}, ROUTES)["key"] == "diaries")
    check("page=null -> None", router.pick_page({"page": None}, ROUTES) is None)
    check("неизвестный ключ -> None", router.pick_page({"page": "нет_такой"}, ROUTES) is None)
    check("не-JSON (None) -> None", router.pick_page(None, ROUTES) is None)
    check("мусор вместо dict -> None", router.pick_page(["diaries"], ROUTES) is None)
    check("нет ключа page -> None", router.pick_page({"reply": "привет"}, ROUTES) is None)

    # ── navigation_steps
    page = router.pick_page({"page": "diaries"}, ROUTES)
    steps = router.navigation_steps(page, "mh-medicalrecords", URL)
    check("врач на другой вкладке -> есть шаг", len(steps) == 1)
    check("шаг — клик по вкладке", steps[0]["method"] == "click")
    check("шаг несёт селектор вкладки", steps[0]["selector"] == "ul.mh-navigation .mh-diaries a")
    check("шаг несёт адрес", steps[0]["address"] == URL)
    check("шаг в формате исполнителя",
          set(steps[0]) == {"selector", "method", "type_write", "value", "address"})

    check("врач уже на целевой вкладке -> шагов нет",
          router.navigation_steps(page, "mh-diaries", URL) == [])
    check("active_tab неизвестен -> шаги есть (лишний клик безвреден)",
          len(router.navigation_steps(page, None, URL)) == 1)
    check("страница не выбрана -> шагов нет", router.navigation_steps(None, "mh-diaries", URL) == [])

    # ── build_router_prompt: роутер видит только имена и описания, не селекторы
    prompt = router.build_router_prompt("покажи дневники", ROUTES["pages"])
    check("промпт содержит команду", "покажи дневники" in prompt)
    check("промпт содержит ключ", "diaries" in prompt)
    check("промпт содержит имя", "Дневники" in prompt)
    check("промпт НЕ содержит селекторы", "mh-navigation" not in prompt)
    check("промпт НЕ содержит elements_in", "diaries.json" not in prompt)

    # ── системный промпт роутера требует строгий JSON и разрешает null
    check("системный промпт требует JSON", '{"page"' in router.ROUTER_SYSTEM_PROMPT)
    check("системный промпт разрешает null", "null" in router.ROUTER_SYSTEM_PROMPT)

    # ── load_routes: совпадение по домену
    here = os.path.abspath(os.path.join(TESTS, ".."))
    found = router.load_routes(URL, here)
    check("карта для hospital-akt найдена", found is not None and found["site"] == "hospital-akt.dmed.kz")
    check("для чужого сайта карты нет", router.load_routes("https://example.com/x", here) is None)
    check("страницы карты непустые", found and len(found["pages"]) > 0)
    check("у каждой страницы есть ключ и tab_class",
          all(p.get("key") and p.get("tab_class") for p in (found or {}).get("pages", [])))

    failed = [n for n, ok in checks if not ok]
    for name, ok in checks:
        print(("  OK   " if ok else "  FAIL ") + name)
    print("\n{}/{} тестов прошло".format(len(checks) - len(failed), len(checks)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
