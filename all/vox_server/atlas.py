"""
Suerte / Vox — атлас страниц: карта сайта, которую сервер строит САМ.
──────────────────────────────────────────────────────────────────────────
routes.json пишется руками и знает ровно то, что в него вписали. Атлас —
то же самое, но накопленное наблюдением: врач ходит по Damumed, расширение
на каждой команде и каждом скане присылает адрес, код запоминает.

ЦЕНА — НОЛЬ ТОКЕНОВ. Обучение здесь целиком кодовое: разобрать URL, схлопнуть
в шаблон, увеличить счётчик. Модель в обучении не участвует вообще; она лишь
получает готовую компактную выжимку (путь + заголовок), когда надо выбрать,
куда идти.

ЗАЧЕМ. Damumed открывает страницы кликами через меню, но почти у всех есть
прямой адрес: /doctorTask/index, /medicalHistory/medicalHistory?id=…,
/patientMedicalRecord/editMedicalRecord?id=0&… Пройти по адресу — это один
шаг вместо четырёх кликов, и он не ломается, когда сайт переставит кнопку.

ПДн — ГЛАВНОЕ ОГРАНИЧЕНИЕ ЭТОГО ФАЙЛА. В адресах Damumed сидят идентификаторы
пациентов (?id=2195085). Поэтому атлас хранит ТОЛЬКО имена параметров, а их
ЗНАЧЕНИЯ выбрасывает при разборе — в atlas.json физически нечему утечь.
Значения подставляются в момент перехода, из ids.jsonl на машине врача.

Файл atlas.json:
    {"version": 1, "pages": [
       {"path": "/medicalHistory/medicalHistory", "params": ["id"],
        "title": "История болезни", "tab": "mh-medicalrecords",
        "hits": 42, "last": "2026-07-27"}
    ]}

Публичный интерфейс:
    split(url) -> (origin, path, params) | None
    learn(url, base_dir, title=None, tab=None, when=None) -> bool
    learn_steps(steps, base_dir) -> int
    load(base_dir) -> dict
    pages(base_dir, limit=MAX_PROMPT_PAGES) -> list[dict]   # выжимка для промпта
    find(path, base_dir) -> dict | None
    same_target(a, b) -> bool                   # адрес ЦЕЛИКОМ, включая ?id=
    splice_from(steps, dest_url) -> (steps, cut)  # отрезать «дорогу» до страницы
    build_url(origin, path, values=None) -> str
    goto_step(url, description="") -> dict
"""

import os
import re
import json
import datetime
from urllib.parse import urlparse, urlencode, parse_qs

ATLAS_NAME = "atlas.json"
VERSION = 1

# Сколько страниц уходит в промпт. Атлас может накопить сотни, модели нужны
# самые ходовые — иначе экономия на прямой навигации съедается промптом.
MAX_PROMPT_PAGES = 25
MAX_PAGES_STORED = 300

_TITLE_RE = re.compile(r"<title[^>]*>\s*(.*?)\s*</title>", re.IGNORECASE | re.DOTALL)
# Хвост заголовка Damumed: «Кабинет врача - Dmed.Стационар» -> «Кабинет врача».
_TITLE_TAIL = re.compile(r"\s*[-—|]\s*Dmed[^|]*$", re.IGNORECASE)


def title_from_html(html):
    m = _TITLE_RE.search(str(html or ""))
    if not m:
        return ""
    title = re.sub(r"\s+", " ", m.group(1)).strip()
    return _TITLE_TAIL.sub("", title).strip()[:80]


def split(url):
    """URL -> (origin, path, params). params — только ИМЕНА параметров.

    Значения не возвращаются и никуда не попадают: в них лежат id пациентов.
    None — если это не http(s)-адрес с внятным путём.
    """
    try:
        u = urlparse(str(url or ""))
    except Exception:
        return None
    if u.scheme not in ("http", "https") or not u.netloc:
        return None
    path = re.sub(r"/+$", "", u.path) or "/"
    params = sorted({
        part.split("=", 1)[0].strip()
        for part in (u.query or "").split("&")
        if part.split("=", 1)[0].strip()
    })
    return (u.scheme + "://" + u.netloc, path, params)


# ───────────────────────────── ХРАНИЛИЩЕ ─────────────────────────────
def _path(base_dir):
    return os.path.join(base_dir, ATLAS_NAME)


def load(base_dir):
    """Битый или отсутствующий атлас — пустой атлас, а не падение."""
    try:
        with open(_path(base_dir), "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("pages"), list):
            return data
    except Exception:
        pass
    return {"version": VERSION, "pages": []}


def _save(data, base_dir):
    os.makedirs(base_dir, exist_ok=True)
    with open(_path(base_dir), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _today(when=None):
    if when:
        return str(when)[:10]
    return datetime.date.today().isoformat()


def learn(url, base_dir, title=None, tab=None, when=None):
    """Запомнить страницу. True — если атлас изменился.

    Параметры объединяются: одну и ту же страницу открывают то с ?id=, то без
    него, и знать надо все встречавшиеся имена. Заголовок/вкладка перезаписывают
    прежние, только если непустые — скан приносит их, голосовая команда нет.
    """
    parts = split(url)
    if not parts:
        return False
    _, path, params = parts

    title = re.sub(r"\s+", " ", str(title or "")).strip()[:80]
    tab = str(tab or "").strip()[:60]

    data = load(base_dir)
    known = next((p for p in data["pages"] if p.get("path") == path), None)
    if known is not None:
        known["params"] = sorted(set(known.get("params") or []) | set(params))
        # Заголовок и вкладку приносит только скан; голосовая команда знает
        # лишь адрес — пустым значением затирать уже известное нельзя.
        if title:
            known["title"] = title
        if tab:
            known["tab"] = tab
        known["hits"] = int(known.get("hits") or 0) + 1
        known["last"] = _today(when)
        _save(data, base_dir)
        return True

    data["pages"].append({
        "path": path, "params": params, "title": title, "tab": tab,
        "hits": 1, "last": _today(when),
    })

    # Держим атлас конечным: редкие и старые страницы вытесняются.
    data["pages"].sort(key=lambda p: (-int(p.get("hits") or 0), p.get("path") or ""))
    del data["pages"][MAX_PAGES_STORED:]
    _save(data, base_dir)
    return True


def learn_steps(steps, base_dir):
    """Обучение по шагам шаблона: address каждого шага — реально посещённая
    страница. Так атлас наполняется сразу после записи «Обучения», не дожидаясь,
    пока врач обойдёт систему заново. Возвращает число обученных адресов."""
    seen, n = set(), 0
    for st in steps or []:
        if not isinstance(st, dict):
            continue
        for key in ("address", "value"):
            url = st.get(key)
            # value несёт адрес только у шага goto; у write там текст пациента.
            if key == "value" and (st.get("method") or "") != "goto":
                continue
            if not url or url in seen:
                continue
            seen.add(url)
            if learn(url, base_dir):
                n += 1
    return n


# ───────────────────────────── ВЫЖИМКА ДЛЯ ПРОМПТА ─────────────────────────
def pages(base_dir, limit=MAX_PROMPT_PAGES):
    """Самые ходовые страницы: путь, заголовок, имена параметров.

    Без счётчиков, дат и вкладок — модели они не нужны, а токены стоят.
    Страницы без заголовка не отдаём: «/Doctor/getMedicalHistories» ничего не
    говорит ни модели, ни врачу (и это обычно ajax-ручка, а не страница).
    """
    data = load(base_dir)
    rows = [p for p in data.get("pages") or [] if (p.get("title") or "").strip()]
    rows.sort(key=lambda p: (-int(p.get("hits") or 0), p.get("path") or ""))
    out = []
    for p in rows[:max(0, int(limit))]:
        row = {"path": p.get("path"), "title": p.get("title")}
        if p.get("params"):
            row["params"] = p["params"]
        out.append(row)
    return out


def find(path, base_dir):
    """Запись атласа по точному пути (или None)."""
    if not path:
        return None
    path = re.sub(r"/+$", "", str(path)) or "/"
    for page in load(base_dir).get("pages") or []:
        if page.get("path") == path:
            return page
    return None


# ───────────────────────────── ПОСТРОЕНИЕ ПЕРЕХОДА ─────────────────────────
def build_url(origin, path, values=None):
    """Собрать адрес. values — {имя: значение}; пустые значения выбрасываются."""
    origin = re.sub(r"/+$", "", str(origin or ""))
    path = str(path or "/")
    if not path.startswith("/"):
        path = "/" + path
    clean = {str(k): str(v) for k, v in (values or {}).items()
             if v is not None and str(v).strip() != ""}
    query = urlencode(clean) if clean else ""
    return origin + path + ("?" + query if query else "")


def same_target(url_a, url_b):
    """Один и тот же адрес ЦЕЛИКОМ, включая параметры.

    Сравнивать только путь тут нельзя: страницы двух разных пациентов
    отличаются ровно значением ?id=, и путь у них общий. Проверка «мы уже
    там?» по пути молча отменила бы переход к другому пациенту.
    """
    a, b = split(url_a), split(url_b)
    if not a or not b or a[0] != b[0] or a[1] != b[1]:
        return False
    try:
        qa = parse_qs(urlparse(str(url_a)).query, keep_blank_values=True)
        qb = parse_qs(urlparse(str(url_b)).query, keep_blank_values=True)
    except Exception:
        return False
    return qa == qb


def splice_from(steps, dest_url):
    """Отрезать у плана начало — ту часть, что лишь добиралась до dest_url.

    Возвращает (шаги, сколько отрезано); 0 — склейка не применима.

    Зачем. Шаблон записан от кабинета врача: первый шаг кликает «Выбрать» в
    гриде, то есть открывает того, кто СЕЙЧАС первый в списке. Если врач назвал
    пациента, к нему идут по адресу, а эта «дорога» в шаблоне становится лишней
    и вредной.

    Режем ТОЛЬКО клики: наткнулись на шаг ввода раньше целевой страницы —
    отказываемся склеивать целиком, потому что пропуск ввода потерял бы текст.
    """
    steps = list(steps or [])
    parts = split(dest_url)
    if not parts or not steps:
        return steps, 0
    for i, st in enumerate(steps):
        if not isinstance(st, dict):
            return steps, 0
        here = split(st.get("address"))
        if here and here[1] == parts[1]:
            return (steps, 0) if i == 0 else (steps[i:], i)
        if (st.get("method") or "click") != "click":
            return steps, 0
    return steps, 0


def goto_step(url, description=""):
    """Шаг прямого перехода — тот же универсальный формат действий.

    address=None намеренно: шаг исполняется на ТЕКУЩЕЙ странице, какой бы она
    ни была (иначе исполнитель начал бы ждать «нужную» страницу перед тем, как
    на неё перейти). navigates=True — чтобы после него он ждал загрузки.
    """
    return {
        "selector": "", "method": "goto", "type_write": "write",
        "value": str(url or ""), "address": None, "navigates": True,
        "description": description or ("переход: " + str(url or "")),
    }
