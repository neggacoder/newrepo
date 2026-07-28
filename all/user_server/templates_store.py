"""
Suerte / Aqbobek — хранилище шаблонов (templates/) на локальном сервере.
──────────────────────────────────────────────────────────────────────────
«Шаблон» — записанная в режиме «Обучение» последовательность шагов UI
(клик/ввод по селектору), в том же формате, что и заготовки в server/templates
(см. server/templates/20.json): один файл <id>.json на шаблон, id — целое
число без пропусков специально не требуется, просто max+1.

Файл на диске:
    {
      "id": <int>,
      "name": "<str>",
      "description": "<str>",
      "example_output": {"template": "recorded", "steps": [...]}
    }

Каждый "step" — {"selector", "method", "type_write", "value", "address"};
внутренности шагов эта модель не проверяет, только что steps — непустой
список.

Публичный интерфейс:
    build_file(name, tpl_id, steps) -> dict         # форма файла, без записи
    next_id(base_dir) -> int
    save(name, steps, base_dir) -> dict              # {"id", "name", "steps"}
    list_all(base_dir) -> list[dict]                 # [{"id", "name", "steps"}, ...]
    get(tpl_id, base_dir) -> dict | None              # полный файл
    delete(tpl_id, base_dir) -> bool
"""

import os
import json


def build_file(name, tpl_id, steps):
    return {
        "id": tpl_id,
        "name": name,
        "description": f"Записано в режиме «Обучение» (id {tpl_id})",
        "example_output": {
            "template": "recorded",
            "steps": steps,
        },
    }


def next_id(base_dir):
    """Максимальный существующий <int>.json + 1; 1, если каталога/файлов нет."""
    if not os.path.isdir(base_dir):
        return 1
    ids = []
    for name in os.listdir(base_dir):
        if not name.endswith(".json"):
            continue
        stem = name[: -len(".json")]
        if stem.isdigit():
            ids.append(int(stem))
    return max(ids) + 1 if ids else 1


def save(name, steps, base_dir):
    """Сохраняет новый шаблон под следующим свободным id. Кидает ValueError,
    если steps не непустой список."""
    if not isinstance(steps, list) or not steps:
        raise ValueError("steps должен быть непустым списком")

    os.makedirs(base_dir, exist_ok=True)
    tpl_id = next_id(base_dir)
    data = build_file(name, tpl_id, steps)
    path = os.path.join(base_dir, f"{tpl_id}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    return {"id": tpl_id, "name": name, "steps": steps}


def list_all(base_dir):
    """Краткая карточка каждого валидного шаблона, отсортированная по id.
    Битые/нечитаемые файлы молча пропускаются."""
    if not os.path.isdir(base_dir):
        return []
    out = []
    for fname in os.listdir(base_dir):
        if not fname.endswith(".json"):
            continue
        stem = fname[: -len(".json")]
        if not stem.isdigit():
            continue
        path = os.path.join(base_dir, fname)
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            out.append({
                "id": data["id"],
                "name": data["name"],
                "steps": data["example_output"]["steps"],
            })
        except Exception:
            continue
    out.sort(key=lambda t: t["id"])
    return out


def get(tpl_id, base_dir):
    """Полный сохранённый файл шаблона или None."""
    path = os.path.join(base_dir, f"{int(tpl_id)}.json")
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def delete(tpl_id, base_dir):
    """True, если файл существовал и был удалён."""
    path = os.path.join(base_dir, f"{int(tpl_id)}.json")
    if not os.path.exists(path):
        return False
    os.remove(path)
    return True
