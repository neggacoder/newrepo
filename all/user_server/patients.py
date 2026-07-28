"""
Suerte / Aqbobek — карточка пациента на машине врача.
──────────────────────────────────────────────────────────────────────────
Небольшой JSON на пациента: ФИО, заметки врача, последние мед. записи.
Лежит ТОЛЬКО здесь, на компьютере врача. Главный сервер (VPS) получает
карточку в теле запроса, кладёт её в промпт и ничего не сохраняет.

Ловушка, ради которой существует индекс: «id в конце ссылки» у одного и того
же человека разный. На medicalHistory это medicalHistoryID (2186386), на
editMedicalRecord — patientAdmissionRegisterID (3136382). Ключом выбран
patientAdmissionRegisterID (по нему же ходит API мед. записей), а index.json
переводит любой встреченный id в этот ключ. Префиксы («par:», «mh:») нужны,
чтобы одинаковые числа разных сущностей не столкнулись.

Публичный интерфейс:
    merge_card(old, new) -> dict
    index_keys(ids) -> list[str]
    resolve_key(ids, index) -> str | None
    load_card(key, base_dir) -> dict | None
    save_card(card, ids, base_dir) -> str        # вернёт ключ
    load_index(base_dir) -> dict
"""

import os
import re
import json
from datetime import datetime

MAX_RECORDS = 3           # last data, pre-last data и ещё одна про запас
MAX_RECORD_CHARS = 4000   # на одну мед. запись
MAX_NOTE_CHARS = 2000     # на заметку врача

INDEX_NAME = "index.json"

# Имя файла = ключ. Только цифры: и потому что это id, и чтобы исключить
# выход за пределы каталога (../../etc/passwd).
_KEY_RE = re.compile(r"^\d+$")

# Как id называется в ссылке -> префикс в индексе.
_ID_PREFIX = {
    "patientAdmissionRegisterID": "par",
    "medicalHistoryID": "mh",
    "iin": "iin",
}


# ───────────────────────────── ИНДЕКС ─────────────────────────────
def index_keys(ids):
    """{'medicalHistoryID': '2186386'} -> ['mh:2186386']. Пустые значения пропускаем."""
    out = []
    for name, prefix in _ID_PREFIX.items():
        value = (ids or {}).get(name)
        if value:
            out.append("{}:{}".format(prefix, value))
    return out


def resolve_key(ids, index):
    """Ключ карточки по любому известному id.

    patientAdmissionRegisterID сам является ключом — индекс для него не нужен.
    Остальные id переводятся через индекс; неизвестный -> None.
    """
    par = (ids or {}).get("patientAdmissionRegisterID")
    if par and _KEY_RE.match(str(par)):
        return str(par)
    for key in index_keys(ids):
        found = (index or {}).get(key)
        if found:
            return str(found)
    return None


# ───────────────────────────── СЛИЯНИЕ ─────────────────────────────
def _clip(text, limit):
    return (str(text or ""))[:limit]


def _norm_records(raw):
    out = []
    for rec in (raw or []):
        if not isinstance(rec, dict):
            continue
        out.append({
            "type": str(rec.get("type") or ""),
            "date": str(rec.get("date") or ""),
            "text": _clip(rec.get("text"), MAX_RECORD_CHARS),
        })
    return out


def merge_card(old, new):
    """Старая карточка + новые данные -> карточка. Чистая функция, диска не касается.

    Правила:
      - записи дедуплицируются по паре (type, date), новые идут впереди, хвост режется;
      - заметку врача (any_information) НЕЛЬЗЯ затереть пустым значением;
      - full_name перезаписывается только непустым;
      - алиасы накапливаются и не обнуляются.
    """
    old = old if isinstance(old, dict) else {}
    new = new if isinstance(new, dict) else {}

    card = {
        "key": str(new.get("key") or old.get("key") or ""),
        "aliases": dict(old.get("aliases") or {}),
        "full_name": old.get("full_name") or "",
        "any_information": old.get("any_information") or "",
        "records": _norm_records(old.get("records")),
    }

    for name, value in (new.get("aliases") or {}).items():
        if value:
            card["aliases"][name] = str(value)

    if new.get("full_name"):
        card["full_name"] = str(new["full_name"])
    if new.get("any_information"):
        card["any_information"] = _clip(new["any_information"], MAX_NOTE_CHARS)
    else:
        card["any_information"] = _clip(card["any_information"], MAX_NOTE_CHARS)

    # Новые записи впереди, старые следом; дубли по (type, date) выбрасываем.
    merged, seen = [], set()
    for rec in _norm_records(new.get("records")) + card["records"]:
        mark = (rec["type"], rec["date"])
        if mark in seen:
            continue
        seen.add(mark)
        merged.append(rec)
    card["records"] = merged[:MAX_RECORDS]

    card["updated_at"] = datetime.now().isoformat(timespec="seconds")
    return card


# ───────────────────────────── ДИСК ─────────────────────────────
def _card_path(key, base_dir):
    return os.path.join(base_dir, "{}.json".format(key))


def load_index(base_dir):
    """Битый или отсутствующий индекс — это пустой индекс, а не падение."""
    path = os.path.join(base_dir, INDEX_NAME)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception as e:
        print("[patients] битый index.json, начинаю с пустого:", e)
        return {}


def load_card(key, base_dir):
    """Карточка по ключу. Нет файла, битый JSON или небезопасный ключ -> None."""
    key = str(key or "")
    if not _KEY_RE.match(key):
        return None
    path = _card_path(key, base_dir)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception as e:
        print("[patients] битая карточка {}: {}".format(key, e))
        return None


def save_card(card, ids, base_dir):
    """Пишем карточку и обновляем индекс. Возвращаем ключ."""
    key = str(card.get("key") or "")
    if not _KEY_RE.match(key):
        raise ValueError("небезопасный ключ карточки: {!r}".format(key))

    os.makedirs(base_dir, exist_ok=True)
    with open(_card_path(key, base_dir), "w", encoding="utf-8") as f:
        json.dump(card, f, ensure_ascii=False, indent=2)

    index = load_index(base_dir)
    # Индексируем и то, что пришло со страницы, и то, что уже лежит в карточке.
    known = dict(ids or {})
    for name, value in (card.get("aliases") or {}).items():
        known.setdefault(name, value)
    known.setdefault("patientAdmissionRegisterID", key)

    for idx_key in index_keys(known):
        index[idx_key] = key

    with open(os.path.join(base_dir, INDEX_NAME), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
    return key
