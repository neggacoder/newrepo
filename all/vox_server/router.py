"""
Suerte / Aqbobek — карта маршрутов и первый (дешёвый) ИИ-вызов.
──────────────────────────────────────────────────────────────────────────
Вместо того чтобы грузить в промпт ~120 отсканированных элементов, работаем
в две ступени:

    ИИ-1 (роутер)      видит команду врача и список {key, name, description}
                       -> {"page": "<key>"} либо {"page": null}
    ИИ-2 (исполнитель) видит команду и элементы ТОЛЬКО выбранной страницы
                       -> {"steps": [...]}

Шаги навигации модель не выдумывает — их приклеивает код из page["path"].
Это то же решение, что и в medrecord.py: корректность плана обеспечивается
кодом, а не промптом.

Почему нельзя определить страницу по URL: medicalHistory/medicalHistory — SPA,
адрес не меняется при переключении вкладок. Единственный признак — класс
активного пункта ul.mh-navigation (mh-diaries, mh-assignments, …), его же
читает _active_tab в user_server/first_scan.py.

Публичный интерфейс:
    ROUTER_SYSTEM_PROMPT
    load_routes(url, base_dir) -> dict | None
    build_router_prompt(text, pages) -> str
    pick_page(parsed, routes) -> dict | None
    navigation_steps(page, active_tab, url) -> list[dict]
"""

import os
import json

ROUTES_NAME = "routes.json"

ROUTER_SYSTEM_PROMPT = (
    "Ты — маршрутизатор медицинского помощника Suerte для системы Damumed.\n"
    "Врач диктует команду. Тебе дают список страниц системы: ключ, название, описание.\n"
    "Определи, на какой странице нужно выполнять команду.\n"
    "\n"
    "Правила:\n"
    '1. Отвечай ТОЛЬКО строгим JSON вида {"page": "<ключ страницы>"}. Без пояснений.\n'
    '2. Если команду можно выполнить на текущей странице или подходящей страницы нет — верни {"page": null}.\n'
    "3. Бери ключ ТОЛЬКО из предоставленного списка. Не придумывай новые ключи.\n"
)


# ───────────────────────────── ЗАГРУЗКА КАРТЫ ─────────────────────────────
def load_routes(url, base_dir):
    """Запись карты для сайта из URL. Нет карты или битый файл -> None."""
    path = os.path.join(base_dir, ROUTES_NAME)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print("[routes.json]", e)
        return None

    entries = data if isinstance(data, list) else [data]
    for entry in entries:
        site = (entry.get("site") or "").strip()
        # Сравниваем по домену, а не по полному адресу: у scaner.json именно из-за
        # этого была записана akt.dmed.kz, которая никогда не совпадала с
        # hospital-akt.dmed.kz.
        if site and site in (url or ""):
            if entry.get("pages"):
                return entry
    return None


# ───────────────────────────── ПРОМПТ РОУТЕРА ─────────────────────────────
def build_router_prompt(text, pages):
    """Роутер видит только команду и {key, name, description} — ни селекторов, ни файлов."""
    slim = [
        {
            "key": p.get("key"),
            "name": p.get("name") or "",
            "description": p.get("description") or "",
        }
        for p in (pages or [])
    ]
    return "\n".join([
        f"Команда врача: {text}",
        "Страницы системы:",
        json.dumps(slim, ensure_ascii=False),
    ])


# ───────────────────────────── ВЫБОР СТРАНИЦЫ ─────────────────────────────
def pick_page(parsed, routes):
    """Ответ роутера -> запись страницы.

    None означает «работаем по текущей странице» — это не ошибка, а штатный
    исход: так ведёт себя система и без карты вовсе.
    """
    if not isinstance(parsed, dict) or not routes:
        return None
    key = parsed.get("page")
    if not key or not isinstance(key, str):
        return None
    for page in routes.get("pages") or []:
        if page.get("key") == key:
            return page
    return None


# ───────────────────────────── ШАГИ НАВИГАЦИИ ─────────────────────────────
def navigation_steps(page, active_tab, url):
    """Шаги, чтобы попасть на выбранную страницу. Пусто, если врач уже на ней.

    active_tab неизвестен -> шаги добавляем: лишний клик по вкладке безвреден,
    а вот молча не перейти туда, куда надо, — вредно.
    """
    if not page:
        return []
    if active_tab and active_tab == page.get("tab_class"):
        return []
    return [
        {
            "selector": step.get("selector", ""),
            "method": "click",
            "type_write": "write",
            "value": None,
            "address": url,
        }
        for step in (page.get("path") or [])
        if step.get("selector")
    ]
