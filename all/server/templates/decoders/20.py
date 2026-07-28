"""
Suerte / Aqbobek — декодер шаблона #20 «Первичный приём пациента».
──────────────────────────────────────────────────────────────────────────
Цель — вкладка «Новый приём» страницы Damumed
(демо: https://herachxx.github.io/damumed-example/, id формы #tab-new-visit).

Принимает распознанный (OCR) и исправленный ИИ текст осмотра пациента и
превращает его в СТРОГИЙ план {template, steps:[...]} для исполнителя в
расширении. Врач при этом уже должен находиться на вкладке «Новый приём».

Селекторы/method/type_write/address берутся из соседнего templates/20.json
(ключ example_output) — код парсинга не зависит от разметки страницы.

Публичный интерфейс (его вызывает server.py → run_decoder):
    decode(text: str, address: str | None = None) -> dict

Standalone:
    python 20.py "<текст осмотра>"
    python 20.py --file осмотр.txt
    echo "<текст>" | python 20.py
"""

import os
import re
import sys
import json

# ─────────────────────────────── ПУТИ ───────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))               # templates/decoders
TEMPLATE_PATH = os.path.join(os.path.dirname(HERE), "20.json")  # templates/20.json

TEMPLATE_ID = 20
DEFAULT_ADDRESS = "https://herachxx.github.io/damumed-example/"

# Логическое имя поля → селектор в 20.json (example_output).
FIELD_TO_SELECTOR = {
    "lastname":   "#patient-lastname",
    "firstname":  "#patient-firstname",
    "middlename": "#patient-middlename",
    "iin":        "#patient-iin",
    "dob":        "#patient-dob",
    "gender":     "#patient-gender",
    "phone":      "#patient-phone",
    "address_p":  "#patient-address",
    "bp_sys":     "#bp-sys",
    "bp_dia":     "#bp-dia",
    "pulse":      "#pulse",
    "temp":       "#temp",
    "height":     "#height",
    "weight":     "#weight",
    "spo2":       "#spo2",
    "complaints": "#complaints",
    "anamnesis":  "#anamnesis",
    "icd":        "#icd-search",
    "diagnosis":  "#diag-text",
    "non_med":    "#non-med",
    "recommend":  "#recommendations",
}
# Порядок заполнения важен (сначала пациент, затем осмотр).
FIELD_ORDER = [
    "lastname", "firstname", "middlename", "iin", "dob", "gender",
    "phone", "address_p", "bp_sys", "bp_dia", "pulse", "temp",
    "height", "weight", "spo2", "complaints", "anamnesis",
    "icd", "diagnosis", "non_med", "recommend",
]
# Финального клика «Сохранить» шаблон НЕ делает — сохранение остаётся за врачом.

# Схема полей для LLM-добора (когда регулярка не нашла поле). label — что искать,
# hint — требуемый формат значения.
FIELD_SCHEMA = [
    {"key": "lastname",   "label": "Фамилия пациента",          "hint": "только фамилия"},
    {"key": "firstname",  "label": "Имя пациента",              "hint": "только имя"},
    {"key": "middlename", "label": "Отчество пациента",         "hint": "только отчество"},
    {"key": "iin",        "label": "ИИН",                        "hint": "12 цифр"},
    {"key": "dob",        "label": "Дата рождения",              "hint": "ГГГГ-ММ-ДД"},
    {"key": "gender",     "label": "Пол",                        "hint": "Мужской или Женский"},
    {"key": "phone",      "label": "Номер телефона",             "hint": "как в тексте"},
    {"key": "address_p",  "label": "Адрес проживания",           "hint": "как в тексте"},
    {"key": "bp_sys",     "label": "АД систолическое",           "hint": "число, напр. 130"},
    {"key": "bp_dia",     "label": "АД диастолическое",          "hint": "число, напр. 85"},
    {"key": "pulse",      "label": "Пульс (ЧСС)",                "hint": "число уд/мин"},
    {"key": "temp",       "label": "Температура тела",           "hint": "число, напр. 36.8"},
    {"key": "height",     "label": "Рост",                       "hint": "число см"},
    {"key": "weight",     "label": "Вес",                        "hint": "число кг"},
    {"key": "spo2",       "label": "Сатурация SpO2",             "hint": "число процентов"},
    {"key": "complaints", "label": "Жалобы пациента",            "hint": "текст"},
    {"key": "anamnesis",  "label": "Анамнез заболевания",        "hint": "текст"},
    {"key": "icd",        "label": "Код диагноза МКБ-10",        "hint": "напр. J44.1"},
    {"key": "diagnosis",  "label": "Формулировка диагноза",      "hint": "текст"},
    {"key": "non_med",    "label": "Немедикаментозное лечение",  "hint": "текст"},
    {"key": "recommend",  "label": "Рекомендации пациенту",      "hint": "текст"},
]


# ─────────────────────────── ЗАГРУЗКА ШАБЛОНА ───────────────────────────
def _load_template():
    """Читаем 20.json → {selector: step-skeleton} + address по умолчанию."""
    skeletons = {}
    address = DEFAULT_ADDRESS
    try:
        with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
            tpl = json.load(f)
        for st in (tpl.get("example_output", {}) or {}).get("steps", []):
            sel = st.get("selector")
            if not sel:
                continue
            skeletons[sel] = {
                "selector": sel,
                "method": st.get("method", "write"),
                "type_write": st.get("type_write", "write"),
                "value": None,
                "address": st.get("address") or DEFAULT_ADDRESS,
            }
            if st.get("address"):
                address = st["address"]
    except Exception as e:
        print(f"[decoder 20] не удалось прочитать {TEMPLATE_PATH}: {e}", file=sys.stderr)
    return skeletons, address


# ─────────────────────────── УТИЛИТЫ ПАРСИНГА ───────────────────────────
_CYR_TO_LAT = str.maketrans({"А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H",
                             "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T", "Х": "X"})
_MONTHS = {
    "янв": "01", "фев": "02", "мар": "03", "апр": "04", "мая": "05", "май": "05",
    "июн": "06", "июл": "07", "авг": "08", "сен": "09", "окт": "10", "ноя": "11", "дек": "12",
}


def _line_after(text, label_re):
    """Значение после метки «Label:» до конца строки."""
    m = re.search(label_re + r"\s*[:\-–]?\s*(.+)", text, re.IGNORECASE)
    return m.group(1).strip() if m else ""


def _num_after(text, label_re, allow_float=False):
    """Первое число после метки (для витальных показателей)."""
    tail = _line_after(text, label_re)
    pat = r"\d+(?:[.,]\d+)?" if allow_float else r"\d+"
    m = re.search(pat, tail)
    if not m:
        return ""
    return m.group(0).replace(",", ".")


def _to_iso_date(raw):
    """Любой формат даты → YYYY-MM-DD (для <input type=date>)."""
    raw = raw.strip()
    m = re.search(r"(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})", raw)      # 1987-03-12
    if m:
        y, mo, d = m.groups()
        return f"{y}-{int(mo):02d}-{int(d):02d}"
    m = re.search(r"(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{4})", raw)      # 12.03.1987
    if m:
        d, mo, y = m.groups()
        return f"{y}-{int(mo):02d}-{int(d):02d}"
    m = re.search(r"(\d{1,2})\s+([А-Яа-я]{3,})\s+(\d{4})", raw)       # 12 марта 1987
    if m:
        d, mon, y = m.groups()
        mon = _MONTHS.get(mon[:3].lower())
        if mon:
            return f"{y}-{mon}-{int(d):02d}"
    return ""


# ─────────────────────────── ИЗВЛЕЧЕНИЕ ПОЛЕЙ ───────────────────────────
_FIO_RE = re.compile(r"[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+(?:\s+[А-ЯЁ][а-яё]+)?")
_IIN_RE = re.compile(r"\b(\d{12})\b")
_MKB_RE = re.compile(r"\b([A-ZА-Я][0-9OО]{2}(?:[.,][0-9]{1,2})?)\b")
_PHONE_RE = re.compile(r"(\+?7[\s\-()]*\d[\d\s\-()]{8,}\d)")
_BP_RE = re.compile(r"(\d{2,3})\s*/\s*(\d{2,3})")   # 130/85


def _extract_fio_parts(text):
    tail = _line_after(text, r"(?:Ф\.?\s*И\.?\s*О\.?|ФИО|Пациент|Больной)")
    m = _FIO_RE.search(tail) or _FIO_RE.search(text)
    if not m:
        return "", "", ""
    parts = m.group(0).split()
    last = parts[0] if len(parts) > 0 else ""
    first = parts[1] if len(parts) > 1 else ""
    middle = parts[2] if len(parts) > 2 else ""
    return last, first, middle


def _extract_iin(text):
    tail = _line_after(text, r"(?:ИИН|И\s*И\s*Н|IIN)") or text
    joined = re.sub(r"(?<=\d)[\s.](?=\d)", "", tail)
    m = _IIN_RE.search(joined)
    return m.group(1) if m else ""


def _extract_gender(text):
    tail = _line_after(text, r"Пол") or text
    low = tail.lower()
    if re.search(r"\bмуж", low):
        return "Мужской"
    if re.search(r"\bжен", low):
        return "Женский"
    return ""


def _extract_mkb(text):
    tail = _line_after(text, r"(?:Диагноз|МКБ[\s\-]*10|Код)") or text
    m = _MKB_RE.search(tail) or _MKB_RE.search(text)
    if not m:
        return ""
    code = m.group(1).upper().replace(",", ".").translate(_CYR_TO_LAT)
    return re.sub(r"[^A-Z0-9.]", "", code)


def _extract_phone(text):
    tail = _line_after(text, r"(?:Телефон|Тел\.?|Номер телефона)") or text
    m = _PHONE_RE.search(tail)
    return m.group(1).strip() if m else ""


def _extract_bp(text):
    # «АД» — как отдельное СЛОВО в верхнем регистре, иначе ловится «Адрес».
    m = re.search(r"(?:\bАД\b|Артериальное давление|Давление)\s*[:\-–]?\s*" + _BP_RE.pattern, text)
    if m:
        return m.group(1), m.group(2)
    m = _BP_RE.search(text)   # запасной вариант: любое NNN/NNN
    return (m.group(1), m.group(2)) if m else ("", "")


def parse_fields(text):
    text = (text or "").replace("\r", "")
    last, first, middle = _extract_fio_parts(text)
    bp_sys, bp_dia = _extract_bp(text)
    return {
        "lastname": last,
        "firstname": first,
        "middlename": middle,
        "iin": _extract_iin(text),
        "dob": _to_iso_date(_line_after(text, r"(?:Дата рождения|Д\.?р\.?|Родил)")),
        "gender": _extract_gender(text),
        "phone": _extract_phone(text),
        "address_p": _line_after(text, r"(?:Адрес проживания|Адрес)"),
        "bp_sys": bp_sys,
        "bp_dia": bp_dia,
        "pulse": _num_after(text, r"(?:Пульс|ЧСС)"),
        "temp": _num_after(text, r"(?:Температура|Темп\.?|t)", allow_float=True),
        "height": _num_after(text, r"(?:Рост)"),
        "weight": _num_after(text, r"(?:Вес|Масса)"),
        "spo2": _num_after(text, r"(?:SpO2|Сатурация|Сат\.?)"),
        "complaints": _line_after(text, r"(?:Жалобы|Жалуется)"),
        "anamnesis": _line_after(text, r"(?:Анамнез заболевания|Анамнез болезни|Анамнез)"),
        "icd": _extract_mkb(text),
        "diagnosis": _line_after(text, r"(?:Формулировка диагноза|Клинический диагноз|Заключение)"),
        "non_med": _line_after(text, r"(?:Немедикаментозное|Режим)"),
        "recommend": _line_after(text, r"(?:Рекомендации|Рекомендовано)"),
    }


# ───────────────────── СБОРКА ШАГОВ / НОРМАЛИЗАЦИЯ ─────────────────────
def build_steps(fields, address=None):
    """fields (логическое имя -> значение) -> список шагов (только заполненные поля)."""
    skeletons, tpl_address = _load_template()
    address = address or tpl_address
    steps = []
    for field in FIELD_ORDER:
        selector = FIELD_TO_SELECTOR[field]
        value = (fields.get(field) or "").strip()
        if not value:
            continue
        step = dict(skeletons.get(selector, {
            "selector": selector, "method": "write",
            "type_write": "write", "address": address,
        }))
        step["value"] = value
        step["address"] = step.get("address") or address
        steps.append(step)
    return steps


def missing_fields(fields):
    return [k for k in FIELD_ORDER if not (fields.get(k) or "").strip()]


def normalize_field(key, raw):
    """Приводим значение (в т.ч. из LLM) к нужному формату для конкретного поля."""
    raw = (raw or "").strip()
    if not raw:
        return ""
    if key == "iin":
        return _extract_iin(raw)
    if key == "dob":
        return _to_iso_date(raw) or raw
    if key == "gender":
        low = raw.lower()
        if low.startswith("муж"):
            return "Мужской"
        if low.startswith("жен"):
            return "Женский"
        return raw
    if key == "icd":
        return _extract_mkb(raw)
    if key in ("bp_sys", "bp_dia", "pulse", "height", "weight", "spo2"):
        m = re.search(r"\d+", raw)
        return m.group(0) if m else ""
    if key == "temp":
        m = re.search(r"\d+(?:[.,]\d+)?", raw)
        return m.group(0).replace(",", ".") if m else ""
    return raw


# ─────────────────────────────── ДЕКОД ───────────────────────────────
def decode(text, address=None):
    """
    text — исправленный OCR-текст первичного осмотра.
    Возвращает {template, id, fields, steps, missing}.
    steps содержит только заполненные поля (без клика «Сохранить» — его делает врач).
    """
    fields = parse_fields(text)
    return {
        "template": "new-visit",
        "id": TEMPLATE_ID,
        "fields": fields,
        "steps": build_steps(fields, address),
        "missing": missing_fields(fields),
    }


# ─────────────────────────────── CLI ───────────────────────────────
def _read_cli_text(argv):
    if "--file" in argv:
        i = argv.index("--file")
        with open(argv[i + 1], "r", encoding="utf-8") as f:
            return f.read()
    positional = [a for a in argv[1:] if not a.startswith("--")]
    if positional:
        return " ".join(positional)
    if not sys.stdin.isatty():
        return sys.stdin.read()
    return ""


def main():
    text = _read_cli_text(sys.argv)
    if not text.strip():
        print("Использование: python 20.py \"<текст осмотра>\" | --file f.txt | stdin",
              file=sys.stderr)
        sys.exit(2)
    print(json.dumps(decode(text), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
