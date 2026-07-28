"""
Suerte / Vox — «навыки»: записанный шаблон как голосовая команда.
──────────────────────────────────────────────────────────────────────────
Записанный в режиме «Обучение» шаблон — это НЕ заготовка, а уже проверенный
план: он один раз реально сработал в Damumed конкретного врача. Значит для
команды, которая совпала с шаблоном, генерировать план заново не нужно —
и это снимает самый дорогой вызов в /command (исполнитель, видящий ~120
элементов страницы, ≈3000-4500 токенов).

Три ступени, от бесплатной к платной:

    A. ОБОГАЩЕНИЕ (1 раз за шаблон, при сохранении)
       ИИ видит шаги БЕЗ СЕЛЕКТОРОВ -> {name, triggers, slots}.
       Селекторы выкинуты не для красоты: один селектор Damumed — это ~250
       символов (~80 токенов), на 15-шаговом шаблоне 1200 токенов мусора,
       который модели не нужен ни для чего.

    B. СОПОСТАВЛЕНИЕ (обычно 0 токенов, локально)
       match() сравнивает команду с triggers/name по огрублённым основам слов.
       Уверенное совпадение -> вызова ИИ нет вообще. Несколько близких ->
       один крошечный вызов, видящий только {id, name, triggers}. Ничего не
       подошло -> None, и /command идёт прежним путём.

    C. СЛОТЫ (только если в шаблоне есть меняющийся текст)
       ИИ видит команду и {key, label, skeleton} -> {key: value}.
       Подстановку делает КОД, не модель.

Принцип тот же, что в router.py и medrecord.py: модель ВЫБИРАЕТ, код
СТРОИТ и ВАЛИДИРУЕТ. Всё, что модель вернула сверх контракта (несуществующий
номер шага, слот на шаге-клике, чужой ключ), молча отбрасывается.

ПДн. build_enrich_prompt отдаёт модели `value` шагов ввода — там может быть
реальный текст про пациента. Отправляется тем же провайдером, что и остальные
вызовы: при provider=openai/deepseek он уходит наружу (осознанное решение,
см. «Caution» в CLAUDE.md). Именно поэтому в сам навык кладётся не `value`, а
`skeleton` — обезличенный образец структуры: дальше, на каждой голосовой
команде, наружу уходит уже он, а не текст пациента.

Публичный интерфейс:
    cards(templates, catalog=None) -> list[dict]
    match(text, cards) -> dict
    ENRICH_SYSTEM_PROMPT / build_enrich_prompt(name, steps) / decode_skill(parsed, steps)
    ensure_slots(steps, skill) -> dict          # слот на каждый шаг ввода
    TIEBREAK_SYSTEM_PROMPT / build_tiebreak_prompt(text, cands) / pick_tiebreak(parsed, cands)
    SLOTS_SYSTEM_PROMPT / build_slots_prompt(text, skill) / decode_slots(parsed, skill)
    apply_slots(steps, skill, values) -> list[dict]
"""

import re
import json

# ─────────────────────────── ПОРОГИ СОПОСТАВЛЕНИЯ ───────────────────────────
# CONFIDENT — берём шаблон молча, без единого вызова ИИ.
# CANDIDATE — в разбор к ИИ-арбитру (дёшево: он видит только имена и фразы).
# GAP       — если второй кандидат ближе этого, «уверенно» не считаем: пусть
#             решает арбитр, а не случайность в подборе слов.
CONFIDENT = 0.75
CANDIDATE = 0.40
GAP = 0.15
MAX_CANDIDATES = 5

MAX_TRIGGERS = 8
MAX_SLOTS = 6
MAX_SLOT_VALUE = 4000

# ─────────────────────────── ОГРУБЛЁННЫЕ ОСНОВЫ СЛОВ ───────────────────────
# Полноценной морфологии здесь нет и не нужно: задача основы — уверенно
# опознать очевидное совпадение, а на сомнительном честно передать решение
# арбитру. Поэтому зависимостей не добавляем, обходимся отсечением окончаний.
_WORD_RE = re.compile(r"[0-9a-zа-яёәғқңөұүһі]+")

_STOP = {
    "и", "в", "во", "на", "с", "со", "по", "для", "мне", "это", "что", "как",
    "же", "бы", "а", "но", "у", "о", "об", "от", "до", "за", "из", "к", "не",
    "ну", "там", "тут", "вот", "давай", "пожалуйста", "его", "её", "их", "ему",
    "мой", "моя", "все", "всё", "надо", "нужно", "хочу", "можешь", "сделай",
}

# Порядок важен: сначала длинные, иначе «ого» никогда не сработает после «о».
_SUFFIXES = (
    "ами", "ями", "ого", "его", "ому", "ему", "ыми", "ими", "ать", "ять",
    "ая", "яя", "ую", "юю", "ое", "ее", "ый", "ий", "ой", "ем", "ом", "ах",
    "ях", "ов", "ев", "ии", "ие", "ые", "ых", "их", "ам", "ям", "ть",
    "а", "я", "о", "е", "ы", "и", "й", "ь", "у", "ю",
)
_STEM_LEN = 5


def _stem(word):
    for suf in _SUFFIXES:
        # +2: не срезаем окончание, если от слова останется огрызок в 1-2 буквы.
        if len(word) > len(suf) + 2 and word.endswith(suf):
            word = word[: -len(suf)]
            break
    return word[:_STEM_LEN]


def stems(text):
    """Множество огрублённых основ. Стоп-слова и односимвольный мусор выкинуты."""
    if not isinstance(text, str):
        return set()
    out = set()
    for w in _WORD_RE.findall(text.lower()):
        if len(w) < 2 or w in _STOP:
            continue
        out.add(_stem(w))
    return out


# ─────────────────────────── КАРТОЧКИ И СОПОСТАВЛЕНИЕ ──────────────────────
def cards(templates, catalog=None):
    """Из списка templates_store.list_all -> карточки для match().

    catalog — записи types.json (types_store.load()["types"]); необязателен,
    чтобы модуль оставался без файловых зависимостей: каталог передаёт
    вызывающий.

    ПРАВИЛО ЧТЕНИЯ. Запись в каталоге ЕСТЬ -> её фразы главные. Пустые фразы
    при существующей записи означают «врач намеренно выключил голосовой
    запуск», поэтому такой шаблон выпадает из кандидатов ЦЕЛИКОМ — иначе он
    совпал бы по имени, и «выключил» оказалось бы неправдой.
    Записи НЕТ ВООБЩЕ -> откат на skill.triggers из файла шаблона (шаблон
    записан до каталога или каталог потерян). Откат именно по отсутствию
    записи: иначе стёртая врачом фраза воскресала бы сама.

    Шаблон без блока skill (записан до появления навыков) не выбрасываем:
    у него остаётся имя, и по нему он тоже может совпасть.
    """
    by_id = {}
    for row in catalog or []:
        if not isinstance(row, dict):
            continue
        try:
            by_id[int(row.get("id"))] = row
        except (TypeError, ValueError):
            continue

    out = []
    for t in templates or []:
        if not isinstance(t, dict) or not t.get("steps"):
            continue
        skill = t.get("skill") or {}
        name = skill.get("name") or t.get("name") or ""

        try:
            entry = by_id.get(int(t.get("id")))
        except (TypeError, ValueError):
            entry = None

        if entry is not None:
            triggers = [x for x in (entry.get("triggers") or [])
                        if isinstance(x, str) and x.strip()]
            if not triggers:
                continue                      # голос выключен намеренно
            name = entry.get("name") or name
        else:
            triggers = [x for x in (skill.get("triggers") or [])
                        if isinstance(x, str) and x.strip()]
            if not name.strip() and not triggers:
                continue

        out.append({"id": t.get("id"), "name": name, "triggers": triggers})
    return out


def _phrase_score(cmd, phrase):
    """Доля основ фразы, покрытых командой. Меряем покрытие ФРАЗЫ, а не команды:
    длинная команда («заведи-ка новую дневниковую запись пациенту») не должна
    штрафоваться за лишние слова — важно, что триггер прозвучал целиком."""
    ph = stems(phrase)
    if not ph:
        return 0.0
    return len(ph & cmd) / len(ph)


def match(text, card_list):
    """Локальное сопоставление команды с навыками. Вызовов ИИ не делает.

    -> {"confident": bool, "id": int|None, "score": float, "candidates": [...]}

    confident=True  — берём id молча.
    confident=False и есть candidates — зовём арбитра (build_tiebreak_prompt).
    candidates пуст  — совпадений нет, обычный путь /command.
    """
    empty = {"confident": False, "id": None, "score": 0.0, "candidates": []}
    cmd = stems(text)
    if not cmd or not card_list:
        return empty

    scored = []
    for c in card_list:
        if c.get("id") is None:
            continue
        best = _phrase_score(cmd, c.get("name") or "")
        for tr in c.get("triggers") or []:
            s = _phrase_score(cmd, tr)
            if s > best:
                best = s
        if best > 0:
            scored.append({"id": c["id"], "name": c.get("name") or "",
                           "triggers": list(c.get("triggers") or []), "score": round(best, 3)})
    if not scored:
        return empty

    # id в ключе сортировки — чтобы одинаковые баллы всегда разрешались
    # одинаково, а не как ляжет порядок файлов в каталоге.
    scored.sort(key=lambda x: (-x["score"], x["id"]))
    best = scored[0]
    second = scored[1]["score"] if len(scored) > 1 else 0.0

    if best["score"] >= CONFIDENT and (best["score"] - second) > GAP:
        return {"confident": True, "id": best["id"], "score": best["score"], "candidates": []}

    cands = [c for c in scored if c["score"] >= CANDIDATE][:MAX_CANDIDATES]
    return {"confident": False, "id": None, "score": best["score"], "candidates": cands}


# ═══════════════════════════ A. ОБОГАЩЕНИЕ ═════════════════════════════════
ENRICH_SYSTEM_PROMPT = (
    "Ты превращаешь записанную последовательность действий врача в «навык» голосового\n"
    "помощника Suerte для системы Damumed.\n"
    "Тебе дают шаги: i — номер шага, method — click или write, description — подпись\n"
    "элемента, value — что врач напечатал в поле.\n"
    "\n"
    'Верни СТРОГИЙ JSON: {"name": "...", "triggers": ["...", "..."], '
    '"slots": [{"step": <i>, "key": "...", "label": "...", "skeleton": "..."}]}\n'
    "\n"
    "Правила:\n"
    "1. name — короткое название действия по-русски, как назвал бы его врач (до 60 символов).\n"
    "2. triggers — 3-6 РАЗНЫХ коротких фраз, которыми врач попросил бы это голосом.\n"
    "   Только то, что реально произносят вслух. Без канцелярита.\n"
    "3. slots — ОДИН слот на КАЖДЫЙ шаг с method=write. Не пропускай ни одного и не\n"
    "   решай, «меняется ли поле»: поле, которое врач не продиктует, просто сохранит\n"
    "   текст из записи.\n"
    "4. step — точный номер i из входных данных. Новых номеров не придумывай.\n"
    "5. label — что это за поле словами врача («жалобы», «объективный статус»,\n"
    "   «рекомендации»). По нему потом решается, какую часть сказанного куда писать.\n"
    "6. skeleton — обезличенный образец: та же структура и тот же стиль, что у value,\n"
    "   но БЕЗ данных конкретного пациента. Имена, даты, диагнозы, цифры замени на «…».\n"
    "7. Никакого текста вне JSON.\n"
)


def slim_steps(steps):
    """Шаги для промпта: без селекторов (см. шапку модуля — это и есть экономия)."""
    out = []
    for i, st in enumerate(steps or []):
        if not isinstance(st, dict):
            continue
        method = st.get("method") or "click"
        item = {"i": i, "method": method,
                "description": str(st.get("description") or "")[:80]}
        if method == "write":
            v = st.get("value")
            item["value"] = str(v)[:400] if v is not None else ""
        out.append(item)
    return out


def build_enrich_prompt(name, steps):
    return "\n".join([
        f"Название, которое дал врач: {name or '(нет)'}",
        "Шаги:",
        json.dumps(slim_steps(steps), ensure_ascii=False),
    ])


def _clean_key(raw):
    key = str(raw or "").strip().lower().replace(" ", "_").replace("-", "_")
    return re.sub(r"[^a-z0-9_]", "", key)[:24]


def decode_skill(parsed, steps):
    """Ответ ИИ -> блок skill. Всё несоответствующее контракту отбрасывается молча.

    Главная проверка: слот обязан указывать на РЕАЛЬНО СУЩЕСТВУЮЩИЙ шаг ввода.
    Иначе подстановка ушла бы в шаг-клик или за границу списка — то есть модель
    смогла бы испортить план, а она этого уметь не должна.
    """
    if not isinstance(parsed, dict):
        return None

    write_idx = {
        i for i, st in enumerate(steps or [])
        if isinstance(st, dict) and (st.get("method") or "click") == "write"
    }

    raw_name = parsed.get("name")
    name = " ".join(raw_name.split())[:60] if isinstance(raw_name, str) else ""

    triggers, seen = [], set()
    for t in parsed.get("triggers") or []:
        if not isinstance(t, str):
            continue
        t = " ".join(t.split()).strip().lower()[:60]
        if not t or t in seen:
            continue
        seen.add(t)
        triggers.append(t)
        if len(triggers) >= MAX_TRIGGERS:
            break

    slots, used_steps, used_keys = [], set(), set()
    for s in parsed.get("slots") or []:
        if not isinstance(s, dict):
            continue
        try:
            idx = int(s.get("step"))
        except (TypeError, ValueError):
            continue
        if idx not in write_idx or idx in used_steps:
            continue
        key = _clean_key(s.get("key"))
        if not key or key in used_keys:
            continue
        label = " ".join(str(s.get("label") or "").split())[:80]
        skeleton = str(s.get("skeleton") or "")[:400]
        slots.append({"step": idx, "key": key, "label": label, "skeleton": skeleton})
        used_steps.add(idx)
        used_keys.add(key)
        if len(slots) >= MAX_SLOTS:
            break

    if not name and not triggers:
        return None
    # Слоты, которые модель всё же пропустила, дописывает код.
    return ensure_slots(steps, {"name": name, "triggers": triggers, "slots": slots})


def ensure_slots(steps, skill):
    """Слот на КАЖДЫЙ шаг ввода. Возвращает КОПИЮ навыка.

    Почему слот по умолчанию, а не «поле-константа». Цена ошибки несимметрична:
      • лишний слот — врач про него не сказал, decode_slots ничего не вернул,
        apply_slots оставил записанное значение. Ровно прежнее поведение;
      • пропущенный слот — текст заморожен навсегда, и фраза из записи едет
        в документ каждого следующего пациента.
    Модель видит ОДНУ запись и «меняется ли это поле» узнать не может в
    принципе, поэтому решение отдано коду. Заодно это чинит шаблоны, записанные
    раньше: у них slots пуст, но поля ввода всё равно станут заполняемыми.
    """
    out = dict(skill or {})
    slots = [dict(s) for s in (out.get("slots") or [])]

    covered = set()
    for s in slots:
        try:
            covered.add(int(s.get("step")))
        except (TypeError, ValueError):
            continue

    write_idx = [i for i, st in enumerate(steps or [])
                 if isinstance(st, dict) and (st.get("method") or "click") == "write"]
    for n, i in enumerate(write_idx, start=1):
        if i in covered:
            continue
        # Подпись НЕ берём из description шага: у поля ввода туда попадает текст,
        # который врач напечатал при записи, то есть данные прошлого пациента —
        # а подпись уходит в промпт на КАЖДОЙ команде. Нейтральное имя безопаснее;
        # человеческие подписи и обезличенный skeleton даёт «Обновить навык».
        label = "текст записи" if len(write_idx) == 1 else f"поле ввода {n}"
        slots.append({"step": i, "key": f"field_{i}", "label": label, "skeleton": ""})

    slots.sort(key=lambda s: s.get("step", 0))
    out["slots"] = slots
    return out


# ═══════════════════════════ B. АРБИТР ПРИ НИЧЬЕЙ ══════════════════════════
TIEBREAK_SYSTEM_PROMPT = (
    "Ты выбираешь готовый сценарий по команде врача (система Damumed).\n"
    "Тебе дают команду и список сценариев: id, name, triggers.\n"
    'Верни СТРОГИЙ JSON {"id": <id сценария>} либо {"id": null}, если не подходит ни один.\n'
    "Бери id ТОЛЬКО из списка. Сомневаешься — возвращай null: лучше обычный разбор\n"
    "команды, чем запуск не того сценария.\n"
)


def build_tiebreak_prompt(text, candidates):
    slim = [{"id": c.get("id"), "name": c.get("name") or "",
             "triggers": list(c.get("triggers") or [])} for c in candidates or []]
    return "\n".join([
        f"Команда врача: {text}",
        "Сценарии:",
        json.dumps(slim, ensure_ascii=False),
    ])


def pick_tiebreak(parsed, candidates):
    """id из ответа арбитра, только если он есть среди кандидатов. Иначе None."""
    if not isinstance(parsed, dict):
        return None
    raw = parsed.get("id")
    if raw is None:
        return None
    try:
        tpl_id = int(raw)
    except (TypeError, ValueError):
        return None
    for c in candidates or []:
        if c.get("id") == tpl_id:
            return tpl_id
    return None


# ═══════════════════════════ C. ЗАПОЛНЕНИЕ СЛОТОВ ══════════════════════════
SLOTS_SYSTEM_PROMPT = (
    "Ты заполняешь поля медицинской формы по устной команде врача (система Damumed).\n"
    "Тебе дают: что сказал врач и список полей {key, label, skeleton}.\n"
    "skeleton — обезличенный образец того, как это поле заполняли раньше: держись\n"
    "его структуры и стиля изложения.\n"
    '\nВерни СТРОГИЙ JSON вида {"<key>": "<текст поля>"}. Без пояснений.\n'
    "\nПравила:\n"
    "1. Ключи бери ТОЛЬКО из списка полей. Новых не придумывай.\n"
    "2. Поле, про которое врач ничего не сказал, пропусти. Пустое поле лучше выдуманного.\n"
    "3. Ничего не добавляй от себя. Диагнозы, показатели, дозы и назначения бери\n"
    "   ИСКЛЮЧИТЕЛЬНО из слов врача — из skeleton берётся только форма, не содержание.\n"
)


def build_slots_prompt(text, skill):
    slim = [{"key": s.get("key"), "label": s.get("label") or "",
             "skeleton": s.get("skeleton") or ""}
            for s in (skill or {}).get("slots") or []]
    return "\n".join([
        f"Врач сказал: {text}",
        "Поля:",
        json.dumps(slim, ensure_ascii=False),
    ])


def decode_slots(parsed, skill):
    """Ответ ИИ -> {key: value}. Чужие ключи и пустые значения отбрасываются."""
    if not isinstance(parsed, dict):
        return {}
    known = {s.get("key") for s in (skill or {}).get("slots") or []}
    out = {}
    for k, v in parsed.items():
        if k not in known or not isinstance(v, str):
            continue
        v = v.strip()
        if v:
            out[k] = v[:MAX_SLOT_VALUE]
    return out


def apply_slots(steps, skill, values):
    """Копия шагов с подставленными значениями. Исходный шаблон не трогаем —
    он на диске один на всех запусков."""
    out = [dict(st) for st in (steps or []) if isinstance(st, dict)]
    for slot in (skill or {}).get("slots") or []:
        key = slot.get("key")
        val = (values or {}).get(key)
        if not val:
            continue
        try:
            idx = int(slot.get("step"))
        except (TypeError, ValueError):
            continue
        if 0 <= idx < len(out) and (out[idx].get("method") or "click") == "write":
            out[idx]["value"] = val
    return out
