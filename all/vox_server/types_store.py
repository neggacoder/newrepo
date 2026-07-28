"""
Suerte / Vox — каталог голосовых типов (types.json).
──────────────────────────────────────────────────────────────────────────
Фразы, которыми запускается записанный шаблон, придумывает модель один раз
при сохранении. Совпасть с тем, как врач говорит на самом деле, они обязаны
не всегда — значит их надо править руками. Каталог собирает фразы всех
шаблонов в один файл, который видно целиком.

ПРАВИЛО ВЛАДЕНИЯ. Файл производный от шаблонов, но правит его человек.
Полная пересборка стирала бы правки, полный отказ от пересборки разошёлся бы
с шаблонами. Поэтому владение разделено по событиям:

    записан шаблон   -> upsert: создаёт, ЕСЛИ ЗАПИСИ ЕЩЁ НЕТ
    нажата «↻»       -> put:    перезаписывает (кнопка значит «переделай заново»)
    шаблон удалён    -> remove
    открыта панель   -> sync:   добить недостающие, убрать осиротевшие
    всё остальное    -> не трогаем

То есть: как только запись появилась — она принадлежит врачу. Единственный
способ потерять его формулировки — нажать «↻» самому.

ПРАВИЛО ЧТЕНИЯ (см. skills.cards). triggers_for различает None и []:
    None — записи нет вообще -> откат на skill.triggers из файла шаблона;
    []   — запись есть, фраз нет -> врач НАМЕРЕННО выключил голосовой запуск.
Откат именно по отсутствию записи: иначе удалённая врачом фраза воскресала бы
из шаблона сама.

Файл types.json:
    {"version": 1, "types": [
       {"id": 4, "name": "Создать выписной эпикриз",
        "triggers": ["создай выписной эпикриз", "сделай выписку"],
        "fields": ["текст записи"]}
    ]}

ПДн сюда не попадают: имя типа и фразы, которыми его зовут. `fields` — подписи
слотов, только для чтения глазами.

Публичный интерфейс:
    load(base_dir) -> dict
    upsert(entry, base_dir) -> bool                 # создать, ЕСЛИ НЕТ
    put(entry, base_dir) -> bool                    # перезаписать
    remove(tpl_id, base_dir) -> bool
    triggers_for(tpl_id, base_dir) -> list | None
    entry_from_template(tpl) -> dict | None         # запись из шаблона
    sync(templates, base_dir) -> int                # добить/подчистить
"""

import os
import json

import skills   # ensure_slots: подписи полей берём после достройки слотов

TYPES_NAME = "types.json"
VERSION = 1


def _path(base_dir):
    return os.path.join(base_dir, TYPES_NAME)


def load(base_dir):
    """Битый или отсутствующий каталог — пустой каталог, а не падение."""
    try:
        with open(_path(base_dir), "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("types"), list):
            return data
    except Exception:
        pass
    return {"version": VERSION, "types": []}


def _save(rows, base_dir):
    os.makedirs(base_dir, exist_ok=True)
    with open(_path(base_dir), "w", encoding="utf-8") as f:
        json.dump({"version": VERSION, "types": rows}, f, ensure_ascii=False, indent=2)


def _norm(entry):
    """Запись в фиксированной форме. None — если нет пригодного id.

    Фразы приводим к нижнему регистру и схлопываем пробелы: сопоставление
    работает с нормализованным текстом, и врач не должен об этом думать,
    когда правит файл руками.
    """
    if not isinstance(entry, dict):
        return None
    try:
        tpl_id = int(entry.get("id"))
    except (TypeError, ValueError):
        return None

    triggers, seen = [], set()
    for t in entry.get("triggers") or []:
        if not isinstance(t, str):
            continue
        t = " ".join(t.split()).strip().lower()
        if t and t not in seen:
            seen.add(t)
            triggers.append(t)

    fields = [" ".join(str(f).split()).strip()
              for f in (entry.get("fields") or [])
              if str(f).strip()]

    return {"id": tpl_id, "name": " ".join(str(entry.get("name") or "").split()),
            "triggers": triggers, "fields": fields}


def _rows(base_dir):
    """Валидные записи каталога. Битые пропускаются молча — остальной
    каталог обязан работать."""
    return [r for r in (_norm(x) for x in load(base_dir).get("types") or []) if r]


def upsert(entry, base_dir):
    """Создать запись, ЕСЛИ ЕЁ ЕЩЁ НЕТ. True — файл изменился.

    Существующую не трогаем ни при каких условиях: она принадлежит врачу.
    """
    norm = _norm(entry)
    if not norm:
        return False
    rows = _rows(base_dir)
    if any(r["id"] == norm["id"] for r in rows):
        return False
    rows.append(norm)
    rows.sort(key=lambda r: r["id"])
    _save(rows, base_dir)
    return True


def put(entry, base_dir):
    """Перезаписать запись. Единственное место, где ручные правки теряются —
    и это осознанное действие врача («↻» = переделай заново)."""
    norm = _norm(entry)
    if not norm:
        return False
    rows = [r for r in _rows(base_dir) if r["id"] != norm["id"]]
    rows.append(norm)
    rows.sort(key=lambda r: r["id"])
    _save(rows, base_dir)
    return True


def remove(tpl_id, base_dir):
    """True, если запись существовала и была удалена."""
    try:
        tpl_id = int(tpl_id)
    except (TypeError, ValueError):
        return False
    rows = _rows(base_dir)
    kept = [r for r in rows if r["id"] != tpl_id]
    if len(kept) == len(rows):
        return False
    _save(kept, base_dir)
    return True


def triggers_for(tpl_id, base_dir):
    """Фразы записи, [] если врач их стёр, None если записи нет вообще.

    Различие None/[] — несущее, см. шапку модуля.
    """
    try:
        tpl_id = int(tpl_id)
    except (TypeError, ValueError):
        return None
    for r in _rows(base_dir):
        if r["id"] == tpl_id:
            return r["triggers"]
    return None


def entry_from_template(tpl):
    """Запись каталога из элемента templates_store.list_all(). None — мусор.

    Ничего не выдумывает и ИИ не зовёт: имя и фразы берёт из самого шаблона,
    подписи полей — из слотов после skills.ensure_slots (у шаблонов, записанных
    до слотов, их достраивает код).
    """
    if not isinstance(tpl, dict):
        return None
    skill = skills.ensure_slots(tpl.get("steps"), tpl.get("skill") or {})
    fields = [(s.get("label") or "").strip() for s in skill.get("slots") or []]
    return _norm({
        "id": tpl.get("id"),
        "name": skill.get("name") or tpl.get("name") or "",
        "triggers": skill.get("triggers") or [],
        "fields": [f for f in fields if f],
    })


def sync(templates, base_dir):
    """Добить недостающие записи и убрать осиротевшие. -> число изменений.

    Существующие записи НЕ трогает: они принадлежат врачу (см. шапку модуля).

    Пустой список шаблонов трактуется как «нечего синхронизировать», а не как
    «удали всё»: сбой чтения каталога шаблонов не должен стоить врачу
    настроенных формулировок.
    """
    if not templates:
        return 0

    rows = _rows(base_dir)
    known = {r["id"] for r in rows}
    alive, changed = set(), 0

    for tpl in templates:
        entry = entry_from_template(tpl)
        if not entry:
            continue
        alive.add(entry["id"])
        if entry["id"] not in known:
            rows.append(entry)
            changed += 1

    before = len(rows)
    rows = [r for r in rows if r["id"] in alive]
    changed += before - len(rows)

    if not changed:
        return 0
    rows.sort(key=lambda r: r["id"])
    _save(rows, base_dir)
    return changed
