"""
Suerte / Aqbobek — заполнение блоков мед. записи (Damumed, editMedicalRecord).
──────────────────────────────────────────────────────────────────────────
Страница делит мед. запись на блоки («Жалобы при поступлении», «Анамнез
заболевания», …). Расширение присылает список блоков с их текущим текстом и
текст предыдущей мед. записи пациента. ИИ раскладывает содержание по ПУСТЫМ
блокам, а этот модуль превращает его ответ в строгий план шагов.

Корректность плана гарантируется здесь, а не промптом: неизвестные id,
непустые блоки и пустые значения отбрасываются молча.

Публичный интерфейс (его зовёт server.py):
    SYSTEM_PROMPT
    build_user_prompt(blocks, history) -> str
    decode(ai_blocks, blocks, url) -> list[dict]
"""

import re
import json

# Клик по пункту списка вызывает onFieldDataChange(), который сначала делает
# saveCurrentField() — сбрасывает содержимое редактора в модель. Поэтому
# «клик -> запись -> клик по следующему» коммитит написанное само собой.
BLOCK_SELECTOR = '#divFieldData a[data-id="{id}"]'
EDITOR_SELECTOR = "#editor_0"

# id блока на странице — это целое число со знаком: -1 … -16.
_ID_RE = re.compile(r"^-?\d+$")

# Сколько символов текущего текста блока и истории отдавать модели.
MAX_BLOCK_TEXT = 500
MAX_HISTORY_CHARS = 12000

SYSTEM_PROMPT = (
    "Ты — ассистент врача. Тебе дают структуру мед. записи (список блоков) и текст "
    "предыдущей мед. записи этого же пациента.\n"
    "Задача: разложить содержание предыдущей записи по блокам, которые сейчас ПУСТЫ.\n"
    "\n"
    "Правила:\n"
    '1. Отвечай ТОЛЬКО строгим JSON вида {"blocks": {"<id блока>": "текст"}}. Без пояснений.\n'
    '2. Используй только те id, что переданы во входных данных, и только те, у которых "empty": true.\n'
    "3. Ничего не выдумывай и не додумывай. Если данных для блока нет — не упоминай этот блок.\n"
    "4. Текст блока — обычные строки, разделённые \\n. Без HTML, без markdown, без маркеров списка.\n"
    "5. Не переноси в блок то, что относится к другому блоку.\n"
    '6. Если подходящих данных нет ни для одного блока — верни {"blocks": {}}\n'
)


def build_user_prompt(blocks, history):
    """Список блоков (как JSON) + предыдущие записи пациента (как текст)."""
    slim = [
        {
            "id": str(b.get("id")),
            "name": b.get("name") or "",
            "empty": bool(b.get("empty")),
            "text": (b.get("text") or "")[:MAX_BLOCK_TEXT],
        }
        for b in blocks
    ]

    parts = ["Блоки мед. записи:", json.dumps(slim, ensure_ascii=False), "", "Предыдущие мед. записи пациента:"]
    budget = MAX_HISTORY_CHARS
    for rec in history:
        head = "--- {} , {} ---".format(rec.get("type") or "мед. запись", rec.get("date") or "без даты")
        text = (rec.get("text") or "")[:budget]
        budget -= len(text)
        parts.append(head)
        parts.append(text)
        if budget <= 0:
            break
    return "\n".join(parts)


def _norm_text(raw):
    """Ответ модели -> текст для построчного редактора: LF, без хвостов, без простыней пустых строк."""
    if raw is None:
        return ""
    s = str(raw).replace("\r\n", "\n").replace("\r", "\n")
    s = "\n".join(line.rstrip() for line in s.split("\n"))
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def _click(block_id, url):
    return {
        "selector": BLOCK_SELECTOR.format(id=block_id),
        "method": "click",
        "type_write": "write",
        "value": None,
        "address": url,
    }


def _write(text, url):
    # type_write='write' — исполнитель расширения сам опознает построчный
    # редактор (<body id="editor_0">) и обернёт строки в <div>.
    return {
        "selector": EDITOR_SELECTOR,
        "method": "write",
        "type_write": "write",
        "value": text,
        "address": url,
    }


def decode(ai_blocks, blocks, url):
    """Ответ ИИ {"<id>": "текст"} -> план шагов. Пустой список, если заполнять нечего."""
    if not isinstance(ai_blocks, dict) or not blocks:
        return []

    order = [str(b.get("id")) for b in blocks]
    known = {str(b.get("id")): b for b in blocks}

    chosen = {}
    for raw_id, raw_text in ai_blocks.items():
        block_id = str(raw_id)
        if not _ID_RE.match(block_id):
            continue
        block = known.get(block_id)
        if block is None or not block.get("empty"):
            continue
        text = _norm_text(raw_text)
        if not text:
            continue
        chosen[block_id] = text

    if not chosen:
        return []

    steps = []
    for block_id in order:
        if block_id in chosen:
            steps.append(_click(block_id, url))
            steps.append(_write(chosen[block_id], url))

    # Финальный клик коммитит последний записанный блок в модель страницы.
    # Клик по первому блоку безопасен, даже если он же был записан последним:
    # onFieldDataChange сохранит его и тут же перечитает то, что сохранил.
    steps.append(_click(order[0], url))
    return steps
