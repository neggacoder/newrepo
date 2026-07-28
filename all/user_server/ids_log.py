"""
Suerte / Aqbobek — журнал идентификаторов пациентов (ids.jsonl).
──────────────────────────────────────────────────────────────────────────
У одного пациента в Damumed ТРИ разных числовых id, и без любого из них
какая-то ссылка не строится:

    medicalHistory    — ?id= на странице истории болезни;
    editMedicalRecord — patientAdmissionRegisterID, второй аргумент
                        onEditButtonClick(0, '3136436', ...) в dropdown-меню
                        «создать запись»;
    watch             — id записи «01. Осмотр врача приёмного покоя», первый
                        аргумент onViewButtonClick('21641017', '1'). Берём
                        ТОЛЬКО тип '1' — остальные «Посмотреть» (12, 7, 5...)
                        это другие записи, их журналить не надо.

Условие сбора: врач на странице …/medicalHistory/medicalHistory И активна
вкладка «Медицинские записи» (есть элемент class="mh-medicalrecords active").
Иначе грида с onView/onEdit на странице просто нет — журналить нечего.

ФИО берётся из <div class="text-right patient-info"><h5>№981 ФИО дата (лет)
</h5></div>; <title> — запасной вариант. Сохранённые страницы иногда портят
«№» кодировкой («в„–981»), поэтому имя ищется от первой ЗАГЛАВНОЙ буквы
(включая казахские Ә, Ғ, Қ, Ң, Ө, Ұ, Ү, Һ, І) до даты.

Каждый пациент — одна строка ids.jsonl в каталоге карточек (PATIENTS_DIR):

    {"medicalHistory": 2186420, "editMedicalRecord": 3136436,
     "watch": 21641017, "name": "АМАНТАЙ ДИДАР ДАРХАНҰЛЫ"}

Публичный интерфейс:
    extract_ids(html, url="") -> dict | None   # None: условия сбора не выполнены
    remember(entry, base_dir) -> bool          # True: файл изменился
    load_all(base_dir) -> list[dict]
"""

import os
import re
import json
from html import unescape
from urllib.parse import urlparse, parse_qs

IDS_NAME = "ids.jsonl"

# Кавычка внутри onclick: живой DOM отдаёт обычную ', сохранённая страница —
# &#39;/&quot;. Kendo-шаблоны ('#: ID #') отсекаются требованием \d+.
_Q = r"(?:&#39;|&quot;|['\"])"

# dropdown «создать запись»: первый аргумент — литеральный 0 (новая запись)
_EDIT_DROPDOWN = re.compile(
    r"onEditButtonClick\(\s*0\s*,\s*" + _Q + r"(\d+)" + _Q)
# строка грида: первый аргумент — id существующей записи (в кавычках)
_EDIT_GRID = re.compile(
    r"onEditButtonClick\(\s*" + _Q + r"\d+" + _Q + r"\s*,\s*" + _Q + r"(\d+)" + _Q)
_VIEW_TYPE1 = re.compile(
    r"onViewButtonClick\(\s*" + _Q + r"(\d+)" + _Q + r"\s*,\s*" + _Q + r"1" + _Q + r"\s*\)")
_MH_LINK = re.compile(r"medicalHistory\?id=(\d+)")

# Активная вкладка «Медицинские записи»: обе части класса, порядок не важен.
_ACTIVE_RECORDS = re.compile(
    r"class=[\"'](?=[^\"']*\bmh-medicalrecords\b)(?=[^\"']*\bactive\b)[^\"']*[\"']")

# patient-info — целый класс-токен: patient-info-hidden и т.п. не считается
_PATIENT_INFO = re.compile(
    r"class=[\"'](?:[^\"']*\s)?patient-info(?:\s[^\"']*)?[\"'][^>]*>\s*<h5[^>]*>(.*?)</h5>",
    re.IGNORECASE | re.DOTALL)
_TITLE = re.compile(r"<title[^>]*>\s*(.*?)\s*</title>", re.IGNORECASE | re.DOTALL)

# ФИО стоит перед датой рождения. Явный [А-Я] не годится: казахские Ұ/Ә/І/Ң
# лежат вне этого диапазона, а префикс («№981» или его кракозябры) отсекается
# требованием начинаться с заглавной буквы.
_UPPER = "А-ЯЁӘҒҚҢӨҰҮҺІA-Z"
_BEFORE_DATE = re.compile(r"\s*(.+?)\s+\d{2}\.\d{2}\.\d{4}", re.DOTALL)


def _to_int(value):
    if isinstance(value, int):
        return value
    s = str(value or "")
    return int(s) if s.isdigit() else None


def _on_medical_history(html, url):
    """Страница истории болезни? По url, а без url (сохранённый файл) — по
    ссылкам medicalHistory?id= внутри html."""
    if url:
        try:
            path = urlparse(str(url)).path
        except Exception:
            return False
        return "/medicalhistory/" in (path.lower() + "/")
    return bool(_MH_LINK.search(html))


def _mh_from_url(url):
    """?id= означает пациента только на medicalHistory (ср. patient-ids.js)."""
    try:
        parts = urlparse(str(url or ""))
    except Exception:
        return None
    if "/medicalhistory/" not in parts.path.lower() + "/":
        return None
    values = parse_qs(parts.query).get("id") or []
    return _to_int(values[0]) if values else None


def _fio_from_text(text):
    text = unescape(str(text or "")).replace("\xa0", " ")
    m = _BEFORE_DATE.match(text)
    if not m:
        return ""
    fio = re.sub("^[^{}]+".format(_UPPER), "", m.group(1))
    return re.sub(r"\s+", " ", fio).strip()


def _name_from_html(html):
    m = _PATIENT_INFO.search(html)
    if m:
        name = _fio_from_text(m.group(1))
        if name:
            return name
    m = _TITLE.search(html)
    return _fio_from_text(m.group(1)) if m else ""


def extract_ids(html, url=""):
    """Три id + ФИО со страницы истории болезни.

    None, если условия сбора не выполнены: не страница medicalHistory,
    вкладка «Медицинские записи» не активна или нет ни одного якорного id."""
    html = str(html or "")
    if not _on_medical_history(html, url):
        return None
    if not _ACTIVE_RECORDS.search(html):
        return None

    mh = _mh_from_url(url)
    if mh is None:
        m = _MH_LINK.search(html)
        mh = _to_int(m.group(1)) if m else None

    m = _EDIT_DROPDOWN.search(html) or _EDIT_GRID.search(html)
    edit = _to_int(m.group(1)) if m else None

    m = _VIEW_TYPE1.search(html)
    watch = _to_int(m.group(1)) if m else None

    if mh is None and edit is None:
        return None
    return {
        "medicalHistory": mh,
        "editMedicalRecord": edit,
        "watch": watch,
        "name": _name_from_html(html),
    }


# ───────────────────────────── ЖУРНАЛ ─────────────────────────────
def _normal(entry):
    """Фиксированный порядок ключей — он же порядок полей в строке файла."""
    entry = entry if isinstance(entry, dict) else {}
    return {
        "medicalHistory": _to_int(entry.get("medicalHistory")),
        "editMedicalRecord": _to_int(entry.get("editMedicalRecord")),
        "watch": _to_int(entry.get("watch")),
        "name": str(entry.get("name") or "").strip(),
    }


def _key(entry):
    mh = entry.get("medicalHistory")
    if mh is not None:
        return ("mh", mh)
    return ("edit", entry.get("editMedicalRecord"))


def has_anchor(entry):
    """Есть ли якорный id (medicalHistory / editMedicalRecord), по которому
    строку можно найти и обновить."""
    entry = _normal(entry)
    return entry["medicalHistory"] is not None or entry["editMedicalRecord"] is not None


def load_all(base_dir):
    """Битый или отсутствующий журнал — пустой журнал, а не падение."""
    path = os.path.join(base_dir, IDS_NAME)
    if not os.path.exists(path):
        return []
    out = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if isinstance(row, dict):
                    out.append(row)
    except Exception as e:
        print("[ids_log] не читается ids.jsonl, начинаю с пустого:", e)
        return []
    return out


def remember(entry, base_dir):
    """Upsert строки пациента. Непустые новые значения перекрывают старые,
    пустые не затирают. Вернёт True, если файл изменился."""
    entry = _normal(entry)
    if entry["medicalHistory"] is None and entry["editMedicalRecord"] is None:
        return False   # без якорного id строку потом не найти и не обновить

    rows = [_normal(row) for row in load_all(base_dir)]

    changed = False
    for i, row in enumerate(rows):
        if _key(row) != _key(entry):
            continue
        merged = dict(row)
        for field in ("medicalHistory", "editMedicalRecord", "watch"):
            if entry[field] is not None and merged[field] != entry[field]:
                merged[field] = entry[field]
                changed = True
        if entry["name"] and merged["name"] != entry["name"]:
            merged["name"] = entry["name"]
            changed = True
        rows[i] = merged
        break
    else:
        rows.append(entry)
        changed = True

    if not changed:
        return False
    os.makedirs(base_dir, exist_ok=True)
    with open(os.path.join(base_dir, IDS_NAME), "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return True
