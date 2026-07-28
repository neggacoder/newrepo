"""
Suerte / Aqbobek — декодер шаблона #12 «Направление к специалисту».
──────────────────────────────────────────────────────────────────────────
Принимает распознанный (OCR) и исправленный ИИ текст медицинского документа
и превращает его в СТРОГИЙ план действий {template, steps:[...]} — ровно
в том формате, который исполняет расширение в браузере.

Селекторы и адреса берутся из соседнего templates/12.json (ключ example_output),
поэтому декодер и шаблон остаются синхронными: правите разметку страницы —
меняете только 12.json, код парсинга трогать не нужно.

Публичный интерфейс (его вызывает server.py):
    decode(text: str, address: str | None = None) -> dict

Формат одного шага (совпадает с исполнителем расширения и SYSTEM_PROMPT сервера):
    {selector, method: click|write, type_write: changeInnerHTML|write|writeByClick,
     value: <str|null>, address: <url>}

Пример output — см. templates/12.json → example_output.

Запуск как транскрибатора (standalone):
    python 12.py "<текст направления>"
    echo "<текст>" | python 12.py
    python 12.py --file направление.txt
"""

import os
import re
import sys
import json

# ─────────────────────────────── ПУТИ ───────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))            # templates/decoders
TEMPLATE_PATH = os.path.join(os.path.dirname(HERE), "12.json")  # templates/12.json

TEMPLATE_ID = 12
DEFAULT_ADDRESS = "https://akt.dmed.kz/referral"

# Логические имена полей → селектор в шаблоне (по example_output из 12.json).
# Если разметка изменится — правится только 12.json, здесь ничего.
FIELD_TO_SELECTOR = {
    "fio":       "#patient-fio",
    "iin":       "#patient-iin",
    "diagnosis": "#diagnosis-mkb",
    "specialty": "#specialty-select",
}
SAVE_SELECTOR = "#save-referral"

# Схема полей для LLM-добора (когда регулярка не нашла поле).
FIELD_SCHEMA = [
    {"key": "fio",       "label": "ФИО пациента",          "hint": "Фамилия Имя Отчество"},
    {"key": "iin",       "label": "ИИН",                    "hint": "12 цифр"},
    {"key": "diagnosis", "label": "Код диагноза МКБ-10",    "hint": "напр. J44.1"},
    {"key": "specialty", "label": "Специальность/специалист", "hint": "напр. Пульмонолог"},
]


# ─────────────────────────── ЗАГРУЗКА ШАБЛОНА ───────────────────────────
def _load_template():
    """Читаем 12.json → {selector: step-skeleton}, чтобы взять method/type_write/address."""
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
        print(f"[decoder 12] не удалось прочитать {TEMPLATE_PATH}: {e}", file=sys.stderr)
    return skeletons, address


# ─────────────────────────── ИЗВЛЕЧЕНИЕ ПОЛЕЙ ───────────────────────────
# OCR ошибается: путает пробелы, регистр, латиницу/кириллицу. Парсим терпимо.

_LABELS = {
    "fio": r"(?:Ф\.?\s*И\.?\s*О\.?|ФИО|Пациент|Больной|Ф\s*И\s*О)",
    "iin": r"(?:ИИН|И\s*И\s*Н|IIN)",
    "diagnosis": r"(?:Диагноз|МКБ[\s\-]*10|Диаг\.?)",
    "specialty": r"(?:Специальност[ьи]|Специалист[уа]?|Направляется\s+к|К\s+врачу)",
    "date": r"(?:Дата|От)",
}

# ФИО: три слова с заглавной (кириллица), допускаем инициалы «И. О.».
_FIO_RE = re.compile(
    r"[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+(?:\s+[А-ЯЁ][а-яё]+)?"
)
_IIN_RE = re.compile(r"\b(\d{12})\b")   # ровно 12 цифр (пробелы склеиваем заранее)
# Код МКБ-10: буква + 2 цифры + опц. .цифра  (латиница ИЛИ похожая кириллица)
_MKB_RE = re.compile(r"\b([A-ZА-Я][0-9OО]{2}(?:[.,][0-9]{1,2})?)\b")
_DATE_RE = re.compile(r"\b(\d{1,2}[.\-/]\d{1,2}[.\-/]\d{2,4})\b")

# Латиница ↔ похожие кириллические буквы (частая ошибка OCR в кодах МКБ).
_CYR_TO_LAT = str.maketrans({"А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H",
                             "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T",
                             "Х": "X", "О".lower(): "0"})


def _value_after_label(text, label_re):
    """Возвращает кусок строки после метки «Label:» до конца строки."""
    m = re.search(label_re + r"\s*[:\-–]?\s*(.+)", text, re.IGNORECASE)
    return m.group(1).strip() if m else ""


def _extract_fio(text):
    tail = _value_after_label(text, _LABELS["fio"])
    m = _FIO_RE.search(tail) or _FIO_RE.search(text)
    return m.group(0).strip() if m else ""


def _extract_iin(text):
    tail = _value_after_label(text, _LABELS["iin"]) or text
    # OCR часто разбивает ИИН пробелами: «8 7 0 3…» → склеиваем цифры.
    joined = re.sub(r"(?<=\d)[\s.](?=\d)", "", tail)
    m = _IIN_RE.search(joined)
    return m.group(1) if m else ""


def _normalize_mkb(code):
    code = code.upper().replace(",", ".").strip()
    code = code.translate(_CYR_TO_LAT)       # кириллица → латиница
    code = re.sub(r"[^A-Z0-9.]", "", code)
    return code


def _extract_diagnosis(text):
    tail = _value_after_label(text, _LABELS["diagnosis"]) or text
    m = _MKB_RE.search(tail) or _MKB_RE.search(text)
    return _normalize_mkb(m.group(1)) if m else ""


def _extract_specialty(text):
    val = _value_after_label(text, _LABELS["specialty"])
    if not val:
        return ""
    # берём первое слово-специальность (до знака препинания / переноса)
    val = re.split(r"[,.\n;]", val)[0].strip()
    return val


def _extract_date(text):
    tail = _value_after_label(text, _LABELS["date"]) or text
    m = _DATE_RE.search(tail)
    return m.group(1) if m else ""


def parse_fields(text):
    """Из сырого текста → словарь распознанных полей (пустые строки, если не найдено)."""
    text = (text or "").replace("\r", "")
    return {
        "fio": _extract_fio(text),
        "iin": _extract_iin(text),
        "diagnosis": _extract_diagnosis(text),
        "specialty": _extract_specialty(text),
        "date": _extract_date(text),
    }


# ───────────────────── СБОРКА ШАГОВ / НОРМАЛИЗАЦИЯ ─────────────────────
def build_steps(fields, address=None):
    """fields (логическое имя -> значение) -> шаги + финальный клик «Сохранить»."""
    skeletons, tpl_address = _load_template()
    address = address or tpl_address
    steps = []
    for field, selector in FIELD_TO_SELECTOR.items():
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

    if steps:
        save = dict(skeletons.get(SAVE_SELECTOR, {
            "selector": SAVE_SELECTOR, "method": "click",
            "type_write": "write", "address": address,
        }))
        save["value"] = None
        save["address"] = save.get("address") or address
        steps.append(save)
    return steps


def missing_fields(fields):
    return [k for k in FIELD_TO_SELECTOR if not (fields.get(k) or "").strip()]


def normalize_field(key, raw):
    """Приводим значение (в т.ч. из LLM) к нужному формату поля."""
    raw = (raw or "").strip()
    if not raw:
        return ""
    if key == "iin":
        return _extract_iin(raw)
    if key == "diagnosis":
        return _normalize_mkb(raw)
    return raw


# ─────────────────────────────── ДЕКОД ───────────────────────────────
def decode(text, address=None):
    """
    Главная точка входа. text — исправленный OCR-текст направления.
    Возвращает {template, id, fields, steps, missing}.
    steps содержит только заполненные поля + финальный клик «Сохранить».
    """
    fields = parse_fields(text)
    return {
        "template": "referral",
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
        print("Использование: python 12.py \"<текст направления>\" | --file f.txt | stdin",
              file=sys.stderr)
        sys.exit(2)
    result = decode(text)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
