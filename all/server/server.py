"""
Suerte / Aqbobek — ГЛАВНЫЙ сервер (Linux VPS).
──────────────────────────────────────────────────────────────────────────
«Мозг» системы. Получает запрос врача (текст) + скан страницы (или берёт
готовый сканер), просит ИИ (qwen2.5-coder:14b через Ollama, ИЛИ OpenAI gpt-4o,
ИЛИ DeepSeek deepseek-chat) выбрать элементы и действия, и возвращает
расширению строгий JSON-план.

/command работает в две ступени, когда для сайта есть карта (routes.json):
    ИИ-1 (роутер)      -> какая страница нужна (видит только имена/описания)
    ИИ-2 (исполнитель) -> план действий по элементам ЭТОЙ страницы
Шаги перехода между вкладками приклеивает код, а не модель (см. router.py).
Карточку пациента присылает расширение (её хранит локальный сервер врача);
здесь она попадает только в промпт и никуда не сохраняется.

Эндпоинты:
    POST /command              — {text, provider, url, scan} -> {steps:[...]} | {reply}
    POST /ocr-template          — {text, provider} -> {id, data}  (text начинается с [OCR])
    POST /medical-record/plan   — {blocks, history, url, provider} -> {steps:[...]} | {reply}
    POST /transcribe            — аудио -> текст (faster-whisper, единственный движок транскрипции)
    GET  /health                — статус
    (админ-панель — отдельный модуль, добавляется после согласования доступа)

Формат одного действия (совпадает с исполнителем в расширении):
    {selector, method: click|write, type_write: changeInnerHTML|write|writeByClick,
     value: <str|null>, address: <url>}

Запуск:   uvicorn server:app --host 0.0.0.0 --port 8080
Прод:     systemd unit aqbobek.service
"""

import os
import re
import json
import glob
import traceback

import httpx
import router
import medrecord
from fastapi import FastAPI, Request, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# ───────────────────────────── КОНФИГ ─────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
SCANERS_DIR = os.path.join(HERE, "Scaners")
TEMPLATES_DIR = os.path.join(HERE, "templates")
SCANER_INDEX = os.path.join(HERE, "scaner.json")

DEFAULT_CONFIG = {
    "host": "0.0.0.0",
    "port": 8080,
    "provider": "qwen",
    "openai_api_key": "",
    "openai_model": "gpt-4o",
    "deepseek_api_key": "",
    "deepseek_model": "deepseek-chat",
    "deepseek_prices": None,
    "ollama_url": "http://127.0.0.1:11434",
    "ollama_model": "qwen2.5-coder:14b",
    "request_timeout": 120,
    "whisper_model": "large-v3-turbo",
    "whisper_language": "ru",
    "whisper_device": "cpu",
    "whisper_compute_type": "int8",
}


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception as e:
            print("[config] ошибка чтения config.json:", e)
    if os.environ.get("OPENAI_API_KEY"):
        cfg["openai_api_key"] = os.environ["OPENAI_API_KEY"]
    if os.environ.get("DEEPSEEK_API_KEY"):
        cfg["deepseek_api_key"] = os.environ["DEEPSEEK_API_KEY"]
    return cfg


CONFIG = load_config()

app = FastAPI(title="Suerte Main Server", version="11.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],       # запросы приходят из расширения (chrome-extension://)
    allow_methods=["*"],
    allow_headers=["*"],
)

# Админ-панель (аутентификация, управление службой, файлы) — отдельный модуль
try:
    import admin
    app.include_router(admin.router)
except Exception as _e:  # чтобы отсутствие argon2/itsdangerous не роняло основной сервер
    print("[admin] панель не подключена:", _e)

# База учёта затрат: применяем схему и, при первом запуске, переливаем в неё
# старый token_usage.txt. Падение здесь не должно ронять сервер — учёт затрат
# не критичен для работы помощника.
try:
    import usage
    usage.init_db()
except Exception as _e:
    print("[usage] база затрат не инициализирована:", _e)

# ───────────────────────── ЗАГРУЗКА СКАНЕРОВ ─────────────────────────
def load_scaner_index():
    """scaner.json может быть одним объектом или списком {site, scaner_in}."""
    if not os.path.exists(SCANER_INDEX):
        return []
    try:
        with open(SCANER_INDEX, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else [data]
    except Exception as e:
        print("[scaner.json]", e)
        return []


def load_page_elements(page):
    """Элементы конкретной страницы карты: Scaners/<elements_in>.

    Файла может не быть — карта заполняется постепенно. Тогда возвращаем None,
    и /command откатывается на живой скан, как и раньше.
    """
    fname = (page or {}).get("elements_in")
    if not fname:
        return None
    path = os.path.join(SCANERS_DIR, fname)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else [data]
    except Exception as e:
        print("[routes] не читается {}: {}".format(fname, e))
        return None


def get_ready_scanner(url):
    """Готовый сканер для сайта: ищем совпадение в scaner.json и грузим Scaners/<file>."""
    for entry in load_scaner_index():
        site = (entry.get("site") or "").strip()
        if site and site in url:
            fname = (entry.get("scaner_in") or "").strip()
            path = os.path.join(SCANERS_DIR, fname)
            if os.path.exists(path):
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                return data if isinstance(data, list) else [data]
    return None


# ───────────────────────── ПРОВАЙДЕРЫ ИИ ─────────────────────────
SYSTEM_PROMPT = """Ты — управляющий модуль медицинского помощника Suerte для системы Damumed.
Врач диктует команду на русском. Тебе дают: запрос врача, URL страницы и список
элементов страницы (селектор, описание, текущее value). Ты должен вернуть СТРОГИЙ JSON
с планом действий, которые надо выполнить в браузере.

Формат ответа — ТОЛЬКО JSON, без пояснений:
{"steps": [
  {"selector": "<css>", "method": "click|write",
   "type_write": "write|changeInnerHTML|writeByClick",
   "value": "<текст или null>", "address": "<url страницы, где выполняется шаг>"}
]}

Правила:
- method="click" — нажать элемент (кнопка/ссылка/пункт). value=null.
- method="write" — ввести текст. Для обычного input/textarea type_write="write".
  Для div, который слушает клавиатуру (contenteditable) — type_write="writeByClick".
  Для замены содержимого узла — type_write="changeInnerHTML".
- Если действие переходит на другую страницу, у следующих шагов ставь их реальный address.
- Бери селекторы ТОЛЬКО из предоставленного списка элементов.
- Если данных не хватает или это просто вопрос — верни {"reply": "<короткий ответ по-русски>"}.
- Если говорят о редакторе мед. записи — это селектор #editor_0, method="write",
  type_write="write", а value — обычный текст с переносами строк \\n. Не пиши туда HTML:
  исполнитель сам построчно обернёт строки в <div>.
- Шаги перехода между вкладками добавлять НЕ надо — их подставляет сервер.
"""


def _patient_section(patient):
    """Карточка пациента -> строки промпта. Пустая карточка не даёт ничего.

    Карточка приходит от ЛОКАЛЬНОГО сервера врача в теле запроса; здесь она
    только читается и нигде не сохраняется — на VPS не должно быть хранилища
    медицинских ПДн. Служебные поля (key, updated_at, aliases) в промпт не
    попадают: модели они не нужны, а токены стоят денег.
    """
    if not patient:
        return []
    lines = ["Пациент (из локальной карточки врача):"]
    if patient.get("full_name"):
        lines.append(f"  ФИО: {patient['full_name']}")
    if patient.get("any_information"):
        lines.append(f"  Заметки врача: {patient['any_information']}")
    for rec in (patient.get("records") or []):
        head = " ".join(filter(None, [rec.get("type"), rec.get("date")]))
        lines.append(f"  --- Предыдущая запись: {head} ---")
        lines.append(f"  {rec.get('text') or ''}")
    # Одно лишь «Пациент:» без единого факта — тоже пусто.
    return lines if len(lines) > 1 else []


def _build_user_prompt(text, url, elements, patient=None):
    lines = [f"Запрос врача: {text}", f"URL: {url}"]
    lines.extend(_patient_section(patient))
    lines.append("Элементы страницы:")
    for e in (elements or [])[:120]:
        lines.append(json.dumps({
            "selector": e.get("selector"),
            "description": e.get("description") or e.get("label"),
            "value": e.get("value"),
            "method": e.get("method"),
            "type_write": e.get("type_write"),
        }, ensure_ascii=False))
    if not elements:
        lines.append("(нет — элементы не сканировались)")
    return "\n".join(lines)


async def call_llm(system, user, provider, endpoint=None):
    provider = (provider or CONFIG["provider"]).lower()
    if provider == "openai":
        return await _call_openai(system, user, endpoint=endpoint)
    if provider == "deepseek":
        return await _call_deepseek(system, user, endpoint=endpoint)
    # Ollama работает локально и токенов не тарифицирует — endpoint ему не нужен.
    return await _call_ollama(system, user)


async def _call_ollama(system, user):
    url = CONFIG["ollama_url"].rstrip("/") + "/api/chat"
    payload = {
        "model": CONFIG["ollama_model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "format": "json",
        "stream": False,
        "options": {"temperature": 0.1},
    }
    async with httpx.AsyncClient(timeout=CONFIG["request_timeout"]) as client:
        r = await client.post(url, json=payload)
        r.raise_for_status()
        data = r.json()
        return data.get("message", {}).get("content", "")


async def _call_openai(system, user, endpoint=None):
    key = CONFIG.get("openai_api_key")
    if not key:
        raise RuntimeError("openai_api_key не задан")
    url = "https://api.openai.com/v1/chat/completions"
    payload = {
        "model": CONFIG["openai_model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
    }
    headers = {"Authorization": f"Bearer {key}"}
    async with httpx.AsyncClient(timeout=CONFIG["request_timeout"]) as client:
        r = await client.post(url, json=payload, headers=headers)
        r.raise_for_status()
        data = r.json()
        # учёт затрат токенов -> usage.db
        try:
            import usage
            usage.record_usage("openai", CONFIG["openai_model"], data.get("usage"),
                               CONFIG.get("openai_prices"), endpoint=endpoint)
        except Exception as e:
            print("[usage]", e)
        return data["choices"][0]["message"]["content"]


async def _call_deepseek(system, user, endpoint=None):
    key = CONFIG.get("deepseek_api_key")
    if not key:
        raise RuntimeError("deepseek_api_key не задан")
    url = "https://api.deepseek.com/chat/completions"
    payload = {
        "model": CONFIG["deepseek_model"],
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
        "stream": False,
    }
    headers = {"Authorization": f"Bearer {key}"}
    async with httpx.AsyncClient(timeout=CONFIG["request_timeout"]) as client:
        r = await client.post(url, json=payload, headers=headers)
        r.raise_for_status()
        data = r.json()
        # учёт затрат токенов -> usage.db
        try:
            import usage
            usage.record_usage("deepseek", CONFIG["deepseek_model"], data.get("usage"),
                               CONFIG.get("deepseek_prices"), endpoint=endpoint)
        except Exception as e:
            print("[usage]", e)
        return data["choices"][0]["message"]["content"]


def _parse_json(raw):
    """Достаём JSON из ответа модели (иногда обёрнут в текст/```json)."""
    if not raw:
        return None
    raw = raw.strip()
    m = re.search(r"\{.*\}", raw, re.S)
    candidate = m.group(0) if m else raw
    try:
        return json.loads(candidate)
    except Exception:
        return None


# ───────────────────────── ТРАНСКРИПЦИЯ (faster-whisper) ─────────────────────────
_whisper_model = None


def get_whisper():
    """Ленивый синглтон модели faster-whisper (единственный движок транскрипции)."""
    global _whisper_model
    if _whisper_model is None:
        from faster_whisper import WhisperModel
        _whisper_model = WhisperModel(
            CONFIG["whisper_model"],
            device=CONFIG["whisper_device"],
            compute_type=CONFIG["whisper_compute_type"],
        )
    return _whisper_model


# ═══════════════════════════════ /command ════════════════════════════
@app.post("/command")
async def command(request: Request):
    body = await request.json()
    text = body.get("text", "")
    provider = body.get("provider", CONFIG["provider"])
    url = body.get("url", "")
    scan = body.get("scan")
    # Карточка пациента: её присылает расширение, взяв с ЛОКАЛЬНОГО сервера врача.
    # Здесь она живёт только внутри промпта и никуда не сохраняется.
    patient = body.get("patient")
    # Класс активной вкладки ul.mh-navigation. У medicalHistory адрес не меняется
    # при переключении вкладок, так что это единственный способ понять, где врач.
    active_tab = body.get("active_tab")

    try:
        # OCR-запросы уходят по своему пути
        if isinstance(text, str) and text.strip().startswith("[OCR]"):
            return await ocr_template(request)

        # 1) ИИ-1 (роутер): на какой странице выполнять команду. Дёшево — он видит
        #    только имена и описания страниц. Нет карты для сайта — нет и вызова.
        page = None
        routes = router.load_routes(url, HERE)
        if routes:
            raw_route = await call_llm(
                router.ROUTER_SYSTEM_PROMPT,
                router.build_router_prompt(text, routes["pages"]),
                provider, endpoint="router")
            page = router.pick_page(_parse_json(raw_route), routes)

        # 2) элементы: страницы из карты, живого скана расширения или готового сканера
        elements = load_page_elements(page)
        if not elements and scan:
            elements = scan.get("elements") if isinstance(scan, dict) else scan
        if not elements:
            elements = get_ready_scanner(url)

        # 3) ИИ-2 (исполнитель): план действий по элементам выбранной страницы
        user = _build_user_prompt(text, url, elements, patient)
        raw = await call_llm(SYSTEM_PROMPT, user, provider, endpoint="command")
        parsed = _parse_json(raw)
        if parsed is None:
            return {"reply": "Не удалось разобрать ответ ИИ", "_raw": raw[:400]}

        # 4) нормализация -> расширение ждёт steps/одиночное действие/reply
        plan = _normalize_plan(parsed, url)

        # 5) шаги навигации приклеивает КОД, а не модель: так она не выдумает
        #    несуществующую вкладку. К текстовому ответу их приклеивать нечему.
        nav = router.navigation_steps(page, active_tab, url)
        if nav and plan.get("steps"):
            plan["steps"] = nav + plan["steps"]
        return plan
    except httpx.HTTPError as e:
        traceback.print_exc()
        return JSONResponse(status_code=502, content={"detail": f"LLM недоступен: {e}"})
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"command: {e}"})


def _normalize_plan(parsed, url):
    if isinstance(parsed, dict) and "reply" in parsed and "steps" not in parsed:
        return {"reply": parsed["reply"]}
    steps = None
    if isinstance(parsed, list):
        steps = parsed
    elif isinstance(parsed, dict):
        steps = parsed.get("steps")
        if steps is None and parsed.get("selector"):
            steps = [parsed]
    if not steps:
        return {"reply": "Нет действий для выполнения"}
    clean = []
    for st in steps:
        if not isinstance(st, dict):
            continue
        clean.append({
            "selector": st.get("selector", ""),
            "method": st.get("method", "click"),
            "type_write": st.get("type_write", "write"),
            "value": st.get("value", None),
            "address": st.get("address") or url,
        })
    return {"steps": clean}


# ═══════════════════════════════ /ocr-template ═══════════════════════
def load_templates_index():
    path = os.path.join(TEMPLATES_DIR, "templates.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else [data]
    except Exception as e:
        print("[templates.json]", e)
        return []


OCR_SYSTEM = """Ты классифицируешь медицинский документ. Тебе дают текст документа (после OCR,
возможны ошибки распознавания) и список доступных шаблонов [{id, example}].
Выбери ОДИН наиболее подходящий шаблон и, если нужно, аккуратно исправь мелкие орфографические
ошибки в тексте. Верни СТРОГИЙ JSON: {"id": <id шаблона>, "corrected": "<исправленный текст>"}.
Если ничего не подходит — {"id": null}."""


@app.post("/ocr-template")
async def ocr_template(request: Request):
    body = await request.json()
    text = body.get("text", "")
    provider = body.get("provider", CONFIG["provider"])
    clean_text = text.replace("[OCR]", "", 1).strip()

    try:
        templates = load_templates_index()
        user = "Текст документа:\n" + clean_text[:4000] + "\n\nШаблоны:\n" + json.dumps(
            [{"id": t.get("id"), "example": t.get("example")} for t in templates], ensure_ascii=False
        )
        raw = await call_llm(OCR_SYSTEM, user, provider, endpoint="ocr-template")
        parsed = _parse_json(raw) or {}
        tpl_id = parsed.get("id")
        corrected = parsed.get("corrected", clean_text)

        if tpl_id is None:
            return {"id": None, "reply": "Подходящий шаблон не найден", "corrected": corrected}

        # Грузим templates/<id>.json — там пример output + ссылка на наш декодер
        tpl_path = os.path.join(TEMPLATES_DIR, f"{tpl_id}.json")
        data = None
        if os.path.exists(tpl_path):
            with open(tpl_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        return {"id": tpl_id, "corrected": corrected, "data": data}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"ocr-template: {e}"})


# ═══════════════════════ /medical-record/plan ════════════════════════
# Страница editMedicalRecord делит запись на блоки. Расширение присылает их
# вместе с предыдущей мед. записью пациента; ИИ раскладывает текст по ПУСТЫМ
# блокам, medrecord.decode превращает ответ в строгий план шагов.
@app.post("/medical-record/plan")
async def medical_record_plan(request: Request):
    body = await request.json()
    blocks = body.get("blocks") or []
    history = body.get("history") or []
    url = body.get("url", "")
    provider = body.get("provider", CONFIG["provider"])

    try:
        # Три ранних отказа: каждый экономит вызов ИИ.
        if not blocks:
            return {"reply": "Блоки мед. записи не найдены"}
        if not any(b.get("empty") for b in blocks):
            return {"reply": "Все блоки уже заполнены"}
        if not history:
            return {"reply": "Нет предыдущих мед. записей пациента"}

        user = medrecord.build_user_prompt(blocks, history)
        raw = await call_llm(medrecord.SYSTEM_PROMPT, user, provider, endpoint="medical-record")
        parsed = _parse_json(raw)
        if parsed is None:
            return {"reply": "Не удалось разобрать ответ ИИ", "_raw": (raw or "")[:400]}

        steps = medrecord.decode(parsed.get("blocks") or {}, blocks, url)
        if not steps:
            return {"reply": "ИИ не нашёл, чем заполнить пустые блоки"}
        return {"steps": steps}
    except httpx.HTTPError as e:
        traceback.print_exc()
        return JSONResponse(status_code=502, content={"detail": f"LLM недоступен: {e}"})
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"medical-record/plan: {e}"})


# ═══════════════════════════════ /transcribe ══════════════════════════
@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...), provider: str = Form(None)):
    # provider не используется — faster-whisper единственный движок транскрипции,
    # параметр оставлен только для совместимости с клиентом.
    import tempfile

    suffix = os.path.splitext(file.filename or "")[1] or ".webm"
    tmp_path = None
    try:
        data = await file.read()
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(data)
            tmp_path = tmp.name

        model = get_whisper()
        segments, _info = model.transcribe(
            tmp_path,
            language=CONFIG.get("whisper_language") or None,
            vad_filter=True,
        )
        text = "".join(seg.text for seg in segments).strip()

        return {"text": text, "provider": "faster-whisper"}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"transcribe: {e}"})
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.remove(tmp_path)


# ═══════════════════════════════ /health ═════════════════════════════
@app.get("/health")
async def health():
    return {
        "ok": True,
        "provider": CONFIG["provider"],
        "ollama_model": CONFIG["ollama_model"],
        "openai_model": CONFIG["openai_model"],
        "deepseek_model": CONFIG["deepseek_model"],
        "deepseek_key": CONFIG["deepseek_api_key"],
        "whisper_model": CONFIG["whisper_model"],
        "scanners": len(load_scaner_index()),
        "templates": len(load_templates_index()),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=CONFIG["host"], port=int(CONFIG["port"]), log_level="info")
