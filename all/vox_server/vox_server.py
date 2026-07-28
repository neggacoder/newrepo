"""
Suerte / Vox — ЕДИНЫЙ сервер (машина врача).
──────────────────────────────────────────────────────────────────────────
Раньше серверов было два: «мозг» на Linux VPS (порт 8080) и локальный сервер
на машине врача (порт 8000). Здесь они объединены в одно приложение на одном
порту. Расширение знает ровно один адрес.

Почему объединение безопасно с точки зрения ПДн: карточки пациентов и раньше
жили ТОЛЬКО на машине врача, а на VPS уезжали лишь внутри промпта. Теперь и
промпт собирается здесь же — медицинские данные вообще не покидают машину
врача, если провайдер тоже локальный (Ollama). При provider=openai/deepseek
текст запроса по-прежнему уходит внешнему API — это осознанный выбор в
config.json, а не свойство архитектуры.

Что умеет сервер:
    «Мозг» (бывший server/, Linux VPS)
    POST /command              — {text, provider, url, scan, patient} -> {steps:[...]} | {reply}
    POST /ocr-template         — {text, provider} -> {id, data}  (text начинается с [OCR])
    POST /medical-record/plan  — {blocks, history, url} -> {steps:[...]} | {reply}
    POST /transcribe           — аудио -> текст (Whisper от OpenAI)
    GET  /health               — статус
    админ-панель (admin.py) + учёт затрат на токены (usage.py -> usage.db)

    Машина врача (бывший user_server/)
    POST /ping                 — проверка живости
    POST /scan, /scan-dynamic  — HTML страницы -> элементы-кандидаты
    POST /macro                — набрать текст / нажать клавиши (pyAutoGui)
    POST /ocr                  — PDF / DOCX / картинка -> текст
    POST /patient/get, /patient/save   — карточки пациентов (медицинские ПДн)
    POST /ids/save                     — журнал id пациентов
    POST /template/save, /list, /delete — шаблоны режима «Обучение»

/command работает в две ступени, когда для сайта есть карта (routes.json):
    ИИ-1 (роутер)      -> какая страница нужна (видит только имена/описания)
    ИИ-2 (исполнитель) -> план действий по элементам ЭТОЙ страницы
Шаги перехода между вкладками приклеивает код, а не модель (см. router.py).

Формат одного действия (совпадает с исполнителем в расширении):
    {selector, method: click|write, type_write: changeInnerHTML|write|writeByClick,
     value: <str|null>, address: <url>}

Тяжёлые зависимости (playwright, pyautogui, tesseract, fitz) импортируются
лениво: сервер поднимается, даже если что-то из них не стоит.

Запуск:   python vox_server.py
          uvicorn vox_server:app --host 127.0.0.1 --port 8000
"""

import io
import os
import re
import json
import glob
import base64
import tempfile
import traceback

import httpx
import router
import medrecord
from fastapi import FastAPI, Request, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import uvicorn

import patients         # карточки пациентов; тяжёлых зависимостей не тянет
import ids_log          # журнал id пациентов (ids.jsonl); тоже без зависимостей
import templates_store  # шаблоны, записанные в режиме «Обучение»
import skills           # шаблон как голосовой навык; чистая логика, без сети
import atlas            # карта страниц, накопленная наблюдением; 0 токенов
import types_store      # каталог голосовых фраз (types.json); чистый модуль

# ───────────────────────────── КОНФИГ ─────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")

# Данные «мозга»: карта сайта и готовые сканы страниц.
SCANERS_DIR = os.path.join(HERE, "Scaners")
SCANER_INDEX = os.path.join(HERE, "scaner.json")

# ВНИМАНИЕ: два разных вида «шаблонов», раньше жившие в двух каталогах с
# одинаковым именем templates/ (по одному на сервер). При объединении их
# пришлось развести, иначе они затирали бы друг друга:
#   OCR_TEMPLATES_DIR — шаблоны распознавания документов (/ocr-template),
#                       бывший server/templates;
#   TEMPLATES_DIR     — последовательности шагов, записанные врачом в режиме
#                       «Обучение» (/template/*), бывший user_server/templates.
OCR_TEMPLATES_DIR = os.environ.get("OCR_TEMPLATES_DIR") or os.path.join(HERE, "ocr_templates")
TEMPLATES_DIR = os.environ.get("TEMPLATES_DIR") or os.path.join(HERE, "templates")
# Атлас страниц (atlas.json). Рядом с сервером, а не в patients/: значения
# параметров туда не попадают, ПДн в нём нет — см. шапку atlas.py.
ATLAS_DIR = os.environ.get("ATLAS_DIR") or HERE
# Каталог голосовых типов (types.json). Рядом с atlas.json: он описывает
# набор шаблонов целиком, а не отдельный шаблон.
TYPES_DIR = os.environ.get("TYPES_DIR") or HERE

# Каталог карточек пациентов. Переопределяется через PATIENTS_DIR — этим
# пользуются тесты, чтобы не писать в рабочий каталог врача.
PATIENTS_DIR = os.environ.get("PATIENTS_DIR") or os.path.join(HERE, "patients")

DEFAULT_CONFIG = {
    # Сервер теперь один и слушает машину врача. 8000 — порт, который
    # расширение уже знало как локальный.
    "host": "127.0.0.1",
    "port": 8000,

    # ─ ИИ ─
    "provider": "qwen",
    "openai_api_key": "",
    "openai_model": "gpt-4o",
    "deepseek_api_key": "",
    "deepseek_model": "deepseek-chat",
    "deepseek_prices": None,
    "ollama_url": "http://127.0.0.1:11434",
    "ollama_model": "qwen2.5-coder:14b",
    "request_timeout": 120,

    # ─ Транскрипция (Whisper от OpenAI; ключ — общий openai_api_key выше) ─
    # whisper-1 — базовая модель распознавания речи OpenAI.
    "whisper_model": "whisper-1",
    "whisper_language": "ru",     # пусто = автоопределение языка

    # ─ Машина врача ─
    "ocr_langs": "kaz+rus+eng",
    "tesseract_cmd": "",       # напр. C:\\Program Files\\Tesseract-OCR\\tesseract.exe
    "macro_paste": True,       # True: вставка из буфера (unicode); False: посимвольный ввод
}

# Ключи, которые разрешено задавать через окружение/.env. Слева имя переменной,
# справа — поле конфига.
ENV_KEYS = {
    "OPENAI_API_KEY": "openai_api_key",
    "DEEPSEEK_API_KEY": "deepseek_api_key",
    "TESSERACT_CMD": "tesseract_cmd",
}


def load_env_files(paths=None):
    """Читает .env-файлы в os.environ, НЕ затирая уже заданные переменные.

    Обещанный в .env.example приоритет:
        реальное окружение (systemd/shell) > .env > config.json > дефолты
    Первый файл в списке важнее последующих (vox_server/.env перебивает
    корневой .env), поэтому уже установленную переменную не трогаем.
    Отсутствующий или битый файл — не ошибка: конфиг просто останется без него.
    """
    if paths is None:
        paths = [os.path.join(HERE, ".env"),
                 os.path.join(os.path.dirname(HERE), ".env")]
    for path in paths:
        try:
            if not os.path.exists(path):
                continue
            with open(path, "r", encoding="utf-8") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    name, _, value = line.partition("=")
                    name = name.strip()
                    # export FOO=bar — тоже валидная строка .env
                    if name.startswith("export "):
                        name = name[len("export "):].strip()
                    value = value.strip().strip('"').strip("'")
                    if name and name not in os.environ:
                        os.environ[name] = value
        except Exception as e:
            print("[.env] не прочитан {}: {}".format(path, e))


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception as e:
            print("[config] ошибка чтения config.json:", e)
    # Окружение (в т.ч. подхваченное из .env) перекрывает config.json.
    for env_name, cfg_key in ENV_KEYS.items():
        if os.environ.get(env_name):
            cfg[cfg_key] = os.environ[env_name]
    return cfg


load_env_files()
CONFIG = load_config()

app = FastAPI(title="Suerte Vox Server", version="12.0.0")
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
except Exception as _e:  # чтобы отсутствие argon2/itsdangerous не роняло сервер
    print("[admin] панель не подключена:", _e)

# База учёта затрат: применяем схему и, при первом запуске, переливаем в неё
# старый token_usage.txt. Падение здесь не должно ронять сервер — учёт затрат
# не критичен для работы помощника.
try:
    import usage
    usage.init_db()
except Exception as _e:
    print("[usage] база затрат не инициализирована:", _e)

# ══════════════════════════════════════════════════════════════════════
#  ЧАСТЬ 1 — «МОЗГ»: ИИ-планировщик, OCR-шаблоны, транскрипция
#  (бывший server/server.py, Linux VPS, порт 8080)
# ══════════════════════════════════════════════════════════════════════

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
    только читается и никуда не пишется: карточку сюда даёт /patient/get этого
    же сервера. Служебные поля (key, updated_at, aliases) в промпт не попадают:
    модели они не нужны, а токены стоят денег.
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


# ───────────────────────── ТРАНСКРИПЦИЯ (Whisper от OpenAI) ─────────────────────────
# Раньше речь распознавалась локально (faster-whisper): модель качалась на
# машину врача и считала на его CPU. Теперь аудио уходит в OpenAI — сервер
# только проксирует файл, никакой модели локально не держит.
#
# ВАЖНО ПРО ПДн: врач диктует, в том числе, сведения о пациенте, поэтому теперь
# запись голоса покидает машину врача и попадает в OpenAI. Локального варианта
# в проекте больше нет — при работе с медицинскими данными это надо учитывать.
OPENAI_TRANSCRIBE_URL = "https://api.openai.com/v1/audio/transcriptions"


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

        # 0) АТЛАС учится молча и бесплатно: раз врач сейчас здесь, значит такая
        #    страница существует и он ею пользуется. Ни одного токена.
        try:
            atlas.learn(url, ATLAS_DIR, title=body.get("title"), tab=active_tab)
        except Exception:
            traceback.print_exc()   # карта — удобство, команду ронять из-за неё нельзя

        # 1) ПАЦИЕНТ ПО ИМЕНИ: «открой историю болезни Амантая» — адрес строится
        #    кодом из ids.jsonl, без ИИ вообще. Заодно это единственный надёжный
        #    способ попасть к КОНКРЕТНОМУ пациенту: клик по строке грида
        #    позиционный и открывает того, кто сейчас первый в списке.
        plan = patient_goto_plan(text, url)
        if plan is not None:
            return plan

        # 2) НАВЫКИ: команда могла совпасть с уже записанным шаблоном. Тогда план
        #    сочинять нечем — он записан врачом и один раз уже отработал в его
        #    Damumed. Это снимает самый дорогой вызов ниже (исполнитель видит
        #    ~120 элементов страницы). Не совпало — идём прежним путём.
        plan = await try_skill_plan(text, provider, url)
        if plan is not None:
            # Назван пациент — приклеиваем переход к нему и срезаем «дорогу»,
            # которую шаблон проделывал кликами по гриду.
            return with_patient_prefix(plan, text, url)

        # 3) СТРАНИЦА ПО КАРТЕ: «открой мои задачи». Шаблона на это нет, но
        #    страница уже посещалась — значит адрес известен, и кликать по
        #    меню незачем. Обычно тоже без вызовов ИИ.
        plan = await atlas_goto_plan(text, url, provider)
        if plan is not None:
            return plan

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


# ═══════════════════════ ПРЯМАЯ НАВИГАЦИЯ ПО АДРЕСУ ════════════════════════
# Damumed открывает страницы кликами через меню, но почти у всех есть прямой
# адрес. Пройти по нему — один шаг вместо четырёх кликов, и он переживает
# перестановку кнопок на сайте.
#
# Оба перехода ниже включаются ТОЛЬКО на явной команде «иди туда». Без этого
# «заполни дневник Амантаю» превратилось бы в «просто перейди к Амантаю и
# ничего не делай» — то есть в тихую потерю половины команды.
_NAV_INTENT = ("откр", "перейд", "покаж", "зайд", "карточк", "истори",
               "выбер", "найд", "верн")


def _wants_navigation(text):
    low = str(text or "").lower()
    return any(w in low for w in _NAV_INTENT)


def _same_page(url_a, url_b):
    a, b = atlas.split(url_a), atlas.split(url_b)
    return bool(a and b and a[0] == b[0] and a[1] == b[1])


def patient_goto_plan(text, url):
    """«Открой историю болезни Амантая» -> шаг перехода. НОЛЬ вызовов ИИ.

    Адрес собирается кодом из ids.jsonl. Это единственный надёжный способ
    попасть к КОНКРЕТНОМУ пациенту: клик по строке грида позиционный
    (tr:nth-child(1)) и открывает того, кто сейчас первый в списке, а список
    сам пересортировывается каждые 5 минут.
    """
    try:
        if not _wants_navigation(text):
            return None
        parts = atlas.split(url)
        if not parts:
            return None
        row = ids_log.find_by_name(text, ids_log.load_all(PATIENTS_DIR))
        if not row or not row.get("medicalHistory"):
            return None
        dest = atlas.build_url(parts[0], "/medicalHistory/medicalHistory",
                               {"id": row["medicalHistory"]})
        # Сравнение ЦЕЛИКОМ, а не по пути: карточки двух пациентов отличаются
        # ровно значением ?id=, и сравнение по пути молча отменило бы переход
        # от одного пациента к другому.
        if atlas.same_target(url, dest):
            return None      # уже на карточке этого пациента
        name = str(row.get("name") or "").strip()
        return {
            "steps": [atlas.goto_step(dest, "карточка пациента" + (": " + name if name else ""))],
            "_nav": {"kind": "patient", "name": name, "url": dest},
        }
    except Exception:
        traceback.print_exc()
        return None


async def atlas_goto_plan(text, url, provider):
    """«Открой мои задачи» -> шаг перехода по накопленной карте.

    Сначала локально по заголовкам страниц (0 токенов), при ничьей — один
    крошечный вызов, видящий только пути и заголовки. Страницы с параметрами
    в кандидаты не берём: без значения id адрес всё равно не собрать, а
    угадывать значения нельзя (см. patient_goto_plan — там они берутся из
    журнала, а не сочиняются).
    """
    try:
        if not _wants_navigation(text):
            return None
        parts = atlas.split(url)
        if not parts:
            return None
        rows = [p for p in atlas.pages(ATLAS_DIR) if not p.get("params")]
        if not rows:
            return None

        cards = [{"id": i, "name": p["title"], "triggers": []} for i, p in enumerate(rows)]
        m = skills.match(text, cards)
        idx = m["id"] if m["confident"] else None
        if idx is None and m["candidates"]:
            raw = await call_llm(
                skills.TIEBREAK_SYSTEM_PROMPT,
                skills.build_tiebreak_prompt(text, m["candidates"]),
                provider, endpoint="atlas-goto")
            idx = skills.pick_tiebreak(_parse_json(raw), m["candidates"])
        if idx is None or not (0 <= idx < len(rows)):
            return None

        dest = atlas.build_url(parts[0], rows[idx]["path"])
        if _same_page(url, dest):
            return None
        return {
            "steps": [atlas.goto_step(dest, rows[idx]["title"])],
            "_nav": {"kind": "page", "name": rows[idx]["title"], "url": dest},
        }
    except Exception:
        traceback.print_exc()
        return None


def with_patient_prefix(plan, text, url):
    """«Создай выписной эпикриз Амантаю» = переход к пациенту + сам шаблон.

    Шаблон записан от кабинета врача, и его первые шаги — это «дорога»: клик
    «Выбрать» в гриде открывает того, кто СЕЙЧАС первый в списке. Назвали
    пациента — идём к нему по адресу и отрезаем у шаблона ту часть, которая
    только и делала, что до этой страницы добиралась (atlas.splice_from режет
    исключительно клики, чтобы не потерять шаг ввода).

    Имя пациента здесь — само по себе достаточный признак; слова «открой» не
    требуем, иначе самая полезная формулировка команды и не сработала бы.
    Не нашли пациента или резать нечего — план возвращается как есть.
    """
    try:
        steps = (plan or {}).get("steps") or []
        parts = atlas.split(url)
        if not steps or not parts:
            return plan
        row = ids_log.find_by_name(text, ids_log.load_all(PATIENTS_DIR))
        if not row or not row.get("medicalHistory"):
            return plan
        dest = atlas.build_url(parts[0], "/medicalHistory/medicalHistory",
                               {"id": row["medicalHistory"]})
        spliced, cut = atlas.splice_from(steps, dest)
        if not cut:
            return plan      # шаблон не начинается с дороги к пациенту

        prefix = [] if atlas.same_target(url, dest) else [
            atlas.goto_step(dest, "карточка пациента: " + str(row.get("name") or ""))
        ]
        out = dict(plan)
        out["steps"] = prefix + spliced
        out["_nav"] = {"kind": "patient", "name": str(row.get("name") or ""),
                       "url": dest, "cut": cut}
        return out
    except Exception:
        traceback.print_exc()
        return plan


def _catalog_entry(tpl_id):
    """Запись каталога по шаблону с диска. None — шаблона нет."""
    tpl = templates_store.get(tpl_id, TEMPLATES_DIR)
    if not tpl:
        return None
    return types_store.entry_from_template({
        "id": tpl.get("id"),
        "name": tpl.get("name"),
        "steps": (tpl.get("example_output") or {}).get("steps") or [],
        "skill": tpl.get("skill"),
    })


async def try_skill_plan(text, provider, url):
    """Команда -> план из записанного шаблона, либо None (тогда обычный путь).

    Три ступени по возрастанию цены (см. skills.py):
      1. локальное сопоставление — 0 токенов, покрывает типичный случай;
      2. арбитр при ничьей — видит только {id, name, triggers} 5 кандидатов;
      3. заполнение слотов — только если в шаблоне есть меняющийся текст.
    Шаблон без слотов исполняется вообще без единого вызова ИИ.

    Любая ошибка здесь — не повод ронять команду: возвращаем None и отдаём
    работу обычному пути, который работал и до навыков.
    """
    if not isinstance(text, str) or not text.strip():
        return None
    try:
        tpls = templates_store.list_all(TEMPLATES_DIR)
        cand_cards = skills.cards(tpls, types_store.load(TYPES_DIR).get("types"))
        if not cand_cards:
            return None

        m = skills.match(text, cand_cards)
        tpl_id = m["id"] if m["confident"] else None
        if tpl_id is None and m["candidates"]:
            raw = await call_llm(
                skills.TIEBREAK_SYSTEM_PROMPT,
                skills.build_tiebreak_prompt(text, m["candidates"]),
                provider, endpoint="skill-match")
            tpl_id = skills.pick_tiebreak(_parse_json(raw), m["candidates"])
        if tpl_id is None:
            return None

        tpl = next((t for t in tpls if t.get("id") == tpl_id), None)
        if not tpl or not tpl.get("steps"):
            return None

        # Слоты достраивает код: у шаблонов, записанных до этого правила,
        # skill.slots пуст, и без ensure_slots их текст остался бы навсегда
        # тем, что врач напечатал при записи.
        skill = skills.ensure_slots(tpl["steps"], tpl.get("skill") or {})
        values = {}
        if skill.get("slots"):
            raw = await call_llm(
                skills.SLOTS_SYSTEM_PROMPT,
                skills.build_slots_prompt(text, skill),
                provider, endpoint="skill-slots")
            values = skills.decode_slots(_parse_json(raw), skill)

        steps = skills.apply_slots(tpl["steps"], skill, values)
        if not steps:
            return None
        # _skill — для панели: врач должен ВИДЕТЬ, какой сценарий сработал и
        # сколько полей реально продиктовано. Незаполненное поле сохраняет текст
        # из записи — то есть текст ПРОШЛОГО пациента, и молчать об этом нельзя.
        return {
            "steps": steps,
            "_skill": {"id": tpl_id, "name": tpl.get("name") or "",
                       "score": m["score"], "slots": len(values),
                       "slots_total": len(skill.get("slots") or [])},
        }
    except Exception:
        traceback.print_exc()
        return None


async def enrich_template(tpl_id, name, steps, provider):
    """Один вызов ИИ при сохранении шаблона: имя + фразы-триггеры + слоты.

    Best-effort: шаблон уже лежит на диске, и упавшее обогащение не должно его
    терять — врач потратил на запись время, а без навыка шаблон просто
    останется «кнопочным».
    """
    try:
        raw = await call_llm(
            skills.ENRICH_SYSTEM_PROMPT,
            skills.build_enrich_prompt(name, steps),
            provider, endpoint="template-enrich")
        skill = skills.decode_skill(_parse_json(raw), steps)
        if not skill:
            return None
        templates_store.set_skill(tpl_id, skill, TEMPLATES_DIR, name=skill.get("name"))
        return skill
    except Exception:
        traceback.print_exc()
        return None


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
        method = st.get("method", "click")
        item = {
            "selector": st.get("selector", ""),
            "method": method,
            "type_write": st.get("type_write", "write"),
            "value": st.get("value", None),
            # У goto адрес — это КУДА идём (лежит в value), а исполняется шаг на
            # текущей странице. Подставить сюда url значило бы заставить
            # исполнитель ждать страницу, на которую он и должен перейти.
            "address": None if method == "goto" else (st.get("address") or url),
        }
        if st.get("navigates") is True:
            item["navigates"] = True
        clean.append(item)
    return {"steps": clean}


# ═══════════════════════════════ /ocr-template ═══════════════════════
def load_templates_index():
    path = os.path.join(OCR_TEMPLATES_DIR, "templates.json")
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
        tpl_path = os.path.join(OCR_TEMPLATES_DIR, f"{tpl_id}.json")
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
    # provider не используется: транскрипция всегда идёт в OpenAI, независимо от
    # того, какой провайдер выбран для LLM. Параметр оставлен для совместимости
    # с расширением, которое его по-прежнему присылает.
    key = CONFIG.get("openai_api_key")
    if not key:
        # Отдельным сообщением, а не «HTTP 401 от OpenAI»: без ключа микрофон
        # просто не работает, и врач должен понимать, почему.
        return JSONResponse(status_code=503, content={
            "detail": "openai_api_key не задан — распознавание речи недоступно"
        })

    try:
        data = await file.read()
        if not data:
            return JSONResponse(status_code=400, content={"detail": "transcribe: пустой файл"})

        # Файл шлём прямо из памяти: временный .webm с голосом врача на диске
        # не нужен, а лишний след с ПДн — тем более.
        files = {"file": (file.filename or "command.webm",
                          data,
                          file.content_type or "audio/webm")}
        form = {"model": CONFIG["whisper_model"], "response_format": "json"}
        # Явный язык заметно повышает точность и убирает случайные переключения
        # на другой язык. Пустое значение = автоопределение.
        if CONFIG.get("whisper_language"):
            form["language"] = CONFIG["whisper_language"]

        async with httpx.AsyncClient(timeout=CONFIG["request_timeout"]) as client:
            r = await client.post(OPENAI_TRANSCRIBE_URL,
                                  headers={"Authorization": f"Bearer {key}"},
                                  data=form, files=files)
            r.raise_for_status()
            payload = r.json()

        return {"text": (payload.get("text") or "").strip(),
                "provider": "openai",
                "model": CONFIG["whisper_model"]}
    except httpx.HTTPStatusError as e:
        traceback.print_exc()
        detail = ""
        try:
            detail = (e.response.json().get("error") or {}).get("message") or ""
        except Exception:
            detail = (e.response.text or "")[:300]
        return JSONResponse(status_code=502, content={
            "detail": f"OpenAI отклонил запрос ({e.response.status_code}): {detail}"
        })
    except httpx.HTTPError as e:
        traceback.print_exc()
        return JSONResponse(status_code=502, content={"detail": f"OpenAI недоступен: {e}"})
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"transcribe: {e}"})


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

# ══════════════════════════════════════════════════════════════════════
#  ЧАСТЬ 2 — МАШИНА ВРАЧА: сканеры, макросы, OCR, карточки пациентов
#  (бывший user_server/user_server.py, порт 8000)
# ══════════════════════════════════════════════════════════════════════

# ═══════════════════════════════ /ping ═══════════════════════════════
@app.post("/ping")
@app.get("/ping")
async def ping():
    return {"ok": True, "service": "suerte-vox", "version": app.version}


# ═══════════════════════ /patient/get, /patient/save ═════════════════
# Карточка пациента: ФИО, заметки врача, последние мед. записи. Ключ —
# patientAdmissionRegisterID; по medicalHistoryID карточка находится через
# index.json (подробности — в docstring patients.py).
@app.post("/patient/get")
async def patient_get(request: Request):
    body = await request.json()
    ids = body.get("ids") or {}
    try:
        key = patients.resolve_key(ids, patients.load_index(PATIENTS_DIR))
        if not key:
            return {"found": False, "patient": None}
        card = patients.load_card(key, PATIENTS_DIR)
        if card is None:
            return {"found": False, "patient": None}
        return {"found": True, "patient": card}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"patient/get: {e}"})


@app.post("/patient/save")
async def patient_save(request: Request):
    body = await request.json()
    ids = body.get("ids") or {}
    try:
        key = patients.resolve_key(ids, patients.load_index(PATIENTS_DIR))
        if not key:
            # Ни patientAdmissionRegisterID, ни известного алиаса — писать некуда.
            return {"ok": False, "reason": "нет идентификаторов пациента"}

        old = patients.load_card(key, PATIENTS_DIR)
        # Всё, что знаем об этом пациенте, идёт в алиасы: так карточка потом
        # найдётся и со страницы, где в URL другой идентификатор.
        aliases = {name: value for name, value in ids.items()
                   if name != "patientAdmissionRegisterID" and value}
        card = patients.merge_card(old, {
            "key": key,
            "aliases": aliases,
            "full_name": body.get("full_name"),
            "any_information": body.get("any_information"),
            "records": body.get("records"),
        })
        patients.save_card(card, ids, PATIENTS_DIR)
        return {"ok": True, "key": key}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"patient/save: {e}"})


# ═══════════════════════════ /ids/save ═══════════════════════════════
# Расширение само извлекает id из живого DOM (patient-ids.js) на странице
# medicalHistory с активной вкладкой записей и присылает готовую запись.
@app.post("/ids/save")
async def ids_save(request: Request):
    body = await request.json()
    entry = body.get("entry") or {}
    try:
        if not ids_log.has_anchor(entry):
            return {"ok": False, "reason": "нет идентификаторов пациента"}
        changed = ids_log.remember(entry, PATIENTS_DIR)
        return {"ok": True, "changed": changed}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"ids/save: {e}"})


# ═══════════ /template/save, /template/list, /template/delete ════════
# Шаблон — записанная в режиме «Обучение» на расширении последовательность
# шагов UI (клик/ввод по селектору). Формат файла — см. templates_store.py
# и ocr_templates/20.json. Сами шаблоны лежат в templates/ — не путать с
# ocr_templates/ (шаблоны распознавания документов, см. /ocr-template).
@app.post("/template/save")
async def template_save(request: Request):
    body = await request.json()
    name = body.get("name")
    steps = body.get("steps")
    provider = body.get("provider", CONFIG["provider"])
    try:
        if not steps:
            return {"ok": False, "reason": "нет шагов"}
        rec = templates_store.save(name or "Без имени", steps, TEMPLATES_DIR)
        # Каждый address в записи — реально пройденная врачом страница. Так
        # карта наполняется сразу после «Обучения», а не ждёт, пока врач
        # обойдёт систему заново уже с голосом.
        try:
            atlas.learn_steps(steps, ATLAS_DIR)
        except Exception:
            traceback.print_exc()
        # Обогащение — здесь и один раз за шаблон: дальше голосовой запуск
        # обходится без ИИ (или почти без него), см. skills.py.
        skill = await enrich_template(rec["id"], rec["name"], steps, provider)
        # Запись в каталоге создаём, но существующую не трогаем: ручные
        # формулировки врача принадлежат ему (см. types_store).
        try:
            entry = _catalog_entry(rec["id"])
            if entry:
                types_store.upsert(entry, TYPES_DIR)
        except Exception:
            traceback.print_exc()
        out = {"ok": True, "id": rec["id"], "name": rec["name"]}
        if skill:
            out["name"] = skill.get("name") or rec["name"]
            out["skill"] = skill
        return out
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"template/save: {e}"})


@app.post("/template/reenrich")
async def template_reenrich(request: Request):
    """Пересобрать навык у УЖЕ записанного шаблона (кнопка «↻» в панели).

    Нужно тем шаблонам, что записаны раньше: код и так достроит им слоты на
    лету, но подписи у таких слотов нейтральные («поле ввода 1»), а skeleton
    пуст. Один вызов ИИ даёт человеческие подписи и обезличенный образец —
    без повторной записи шаблона руками.
    """
    body = await request.json()
    provider = body.get("provider", CONFIG["provider"])
    try:
        tpl = templates_store.get(int(body["id"]), TEMPLATES_DIR)
        if not tpl:
            return {"ok": False, "reason": "шаблон не найден"}
        steps = (tpl.get("example_output") or {}).get("steps") or []
        if not steps:
            return {"ok": False, "reason": "в шаблоне нет шагов"}
        skill = await enrich_template(tpl["id"], tpl.get("name") or "", steps, provider)
        if not skill:
            return {"ok": False, "reason": "ИИ не вернул навык"}
        # «↻» значит «переделай заново» — здесь ручные фразы затираются
        # намеренно, это единственное такое место.
        try:
            entry = _catalog_entry(tpl["id"])
            if entry:
                types_store.put(entry, TYPES_DIR)
        except Exception:
            traceback.print_exc()
        return {"ok": True, "id": tpl["id"], "name": skill.get("name") or tpl.get("name"),
                "skill": skill}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"template/reenrich: {e}"})


@app.post("/template/list")
async def template_list(request: Request):
    try:
        tpls = templates_store.list_all(TEMPLATES_DIR)
        # Панель открылась — досинхронизируем каталог. Так шаблоны, записанные
        # до появления types.json, получают записи сами, без отдельной команды.
        try:
            types_store.sync(tpls, TYPES_DIR)
        except Exception:
            traceback.print_exc()
        return {"ok": True, "templates": tpls}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"template/list: {e}"})


@app.post("/template/delete")
async def template_delete(request: Request):
    body = await request.json()
    try:
        tpl_id = int(body["id"])
        deleted = templates_store.delete(tpl_id, TEMPLATES_DIR)
        try:
            types_store.remove(tpl_id, TYPES_DIR)
        except Exception:
            traceback.print_exc()
        return {"ok": True, "deleted": deleted}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"template/delete: {e}"})


# ═══════════════════════════════ /scan ═══════════════════════════════
# «Шаблонный» сканер: разбирает HTML и возвращает список элементов-кандидатов
# в формате действий ИИ-планировщика + текущее value. Особые эвристики под
# конкретные сайты добавляются в SPECIAL_RULES (место оставлено намеренно).

SPECIAL_RULES = [
    # Пример правила (заполняется под конкретный сайт Damumed):
    # {"match": "akt.dmed.kz", "selector": "#patient-search", "description": "Поиск пациента",
    #  "method": "write", "type_write": "write"},
]


def _remember_patient_ids(html, url):
    """Тихо журналируем id пациента со страницы (ids.jsonl, см. ids_log.py):
    журнал — побочный эффект скана и ломать его не должен."""
    try:
        entry = ids_log.extract_ids(html, url)
        if entry:
            ids_log.remember(entry, PATIENTS_DIR)
    except Exception:
        traceback.print_exc()


def _remember_page(html, url):
    """Тихо пополняем атлас страниц. Скан — единственное место, где сервер
    видит <title>, то есть человеческое название страницы; без него в карте
    остаётся голый путь, по которому модель ничего не выберет."""
    try:
        atlas.learn(url, ATLAS_DIR, title=atlas.title_from_html(html))
    except Exception:
        traceback.print_exc()


@app.post("/scan")
async def scan(request: Request):
    body = await request.json()
    html = body.get("html", "")
    values = body.get("values", {}) or {}
    url = body.get("url", "")
    _remember_patient_ids(html, url)
    _remember_page(html, url)
    try:
        elements = _scan_html(html, values, url)
        # спец-правила для этого url
        for rule in SPECIAL_RULES:
            if rule.get("match") and rule["match"] in url:
                elements.insert(0, {
                    "description": rule.get("description", ""),
                    "selector": rule.get("selector", ""),
                    "method": rule.get("method", "click"),
                    "type_write": rule.get("type_write", "write"),
                    "value": values.get(rule.get("selector", ""), None),
                    "address": url,
                })
        return {"url": url, "count": len(elements), "elements": elements}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"scan: {e}"})


def _clean_text(s):
    """Схлопывает пробелы/переносы строк (в т.ч. из вложенных <span>/<svg>) в одну строку."""
    import re
    return re.sub(r"\s+", " ", (s or "")).strip()


def _scan_html(html, values, url):
    import copy
    from bs4 import BeautifulSoup
    soup = BeautifulSoup(html, "html.parser")
    out = []
    seen = set()

    def css_path(tag):
        if tag.get("id"):
            return "#" + tag.get("id")
        parts = []
        cur = tag
        depth = 0
        while cur is not None and getattr(cur, "name", None) and depth < 6:
            name = cur.name
            parent = cur.parent
            if parent and getattr(parent, "find_all", None):
                sibs = [c for c in parent.find_all(name, recursive=False)]
                if len(sibs) > 1:
                    idx = sibs.index(cur) + 1
                    name += f":nth-of-type({idx})"
            parts.insert(0, name)
            if cur.get("id"):
                parts[0] = "#" + cur.get("id")
                break
            cur = parent
            depth += 1
        return " > ".join(parts)

    def onclick_selector(tag):
        """Для кликабельных нон-семантических тегов (div/li/span с onclick, как
        nav-item в сайдбаре) пробуем селектор по точному значению onclick — он
        читаемее и устойчивее к перестановке соседних элементов, чем nth-of-type.
        Используем, только если он однозначно указывает на один элемент."""
        onclick = tag.get("onclick")
        if not onclick:
            return None
        # onclick обычно в одинарных кавычках ('appointments') — оборачиваем
        # селектор в двойные; если внутри всё же встретятся двойные (редко),
        # используем одинарные и экранируем их внутри значения.
        if '"' in onclick and "'" not in onclick:
            quote = "'"
            value = onclick.replace("'", "\\'")
        else:
            quote = '"'
            value = onclick.replace('"', '\\"')
        try:
            sel = f'{tag.name}[onclick={quote}{value}{quote}]'
            if len(soup.select(sel)) == 1:
                return sel
        except Exception:
            pass
        return None

    def build_selector(tag):
        if tag.get("id"):
            return "#" + tag.get("id")
        return onclick_selector(tag) or css_path(tag)

    # [onclick] — ловит кликабельные div/li/span и т.п. (например, пункты меню
    # вида <div class="nav-item" onclick="showTab('appointments')">...</div>),
    # которые не входят ни в одну из семантических категорий выше.
    selectors = "input, textarea, select, button, a[href], [role=button], [contenteditable=true], [onclick]"
    for tag in soup.select(selectors):
        name = tag.name
        typ = name
        if name == "input":
            typ = tag.get("type", "text")

        # метод и способ ввода
        if name in ("button", "a") or tag.get("role") == "button" or tag.has_attr("onclick"):
            method, type_write = "click", "write"
        elif tag.get("contenteditable") == "true":
            method, type_write = "write", "writeByClick"   # div, слушающий клавиатуру
        elif name == "select":
            method, type_write = "click", "write"
        else:
            method, type_write = "write", "write"

        sel = build_selector(tag)
        if not sel or sel in seen:
            continue
        seen.add(sel)

        # Текст кнопки без служебных «бейджей»-счётчиков (например, <span
        # class="nav-badge">3</span>) — их выносим в описание отдельно, чтобы
        # не путать текст пункта меню со счётчиком уведомлений/задач.
        badge_text = None
        text_source = tag
        badge_el = tag.find(class_=lambda c: c and "badge" in c)
        if badge_el is not None:
            text_source = copy.copy(tag)
            badge_el2 = text_source.find(class_=lambda c: c and "badge" in c)
            if badge_el2 is not None:
                badge_text = _clean_text(badge_el2.get_text())
                badge_el2.decompose()

        label = (
            tag.get("placeholder")
            or tag.get("aria-label")
            or tag.get("title")
            or tag.get("name")
            or _clean_text(text_source.get_text())
        )
        label = (label or name)[:80]
        if badge_text:
            label = f"{label} ({badge_text})"
        value = values.get(sel)
        if value is None and tag.has_attr("value"):
            value = tag.get("value")

        out.append({
            "description": label,
            "selector": sel,
            "method": method,
            "type_write": type_write,
            "value": value,
            "address": url,
        })
    return out


# ═══════════════════════════ /scan-dynamic ═══════════════════════════
# Тот же вход и тот же формат ответа, что и у /scan, но для «известных»
# страниц (например, doctor Damumed) подключается специализированный сканер
# из first_scan.py: он разбирает блоки по ФИО и пишет в description, чья это
# кнопка, с уникальным селектором. Сканер выбирается по URL (first_scan.pick).
# Если спец-сканер не подошёл или упал (нет Playwright/Chromium, таймаут) —
# деградируем на общий _scan_html, то есть ведём себя ровно как /scan.
#
# first_scan импортируется лениво (и только модуль — Playwright он тянет ещё
# позже, внутри самого сканера), чтобы сервер поднимался даже без Playwright.

def _load_first_scan():
    """Импорт first_scan независимо от способа запуска сервера:
    `python vox_server.py` (cwd=vox_server/) или
    `uvicorn vox_server.vox_server:app` (cwd=корень репо). HERE — папка с
    этим файлом, там же лежит first_scan.py, поэтому кладём её в sys.path."""
    import sys
    import importlib
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    return importlib.import_module("first_scan")


async def _call_scanner(fn, html, url, values, iframe_html):
    """Вызывает спец-сканер из first_scan.py, передавая iframe_html только
    тем сканерам, чья сигнатура его принимает (сейчас — scan_diary; старые
    scan_doctor/scan_medical_records/scan_assignments его не знают, им шлём
    как раньше html/url/values, чтобы не сломать TypeError-ом на лишний
    kwarg)."""
    import inspect
    try:
        params = inspect.signature(fn).parameters
    except (TypeError, ValueError):
        params = {}
    if "iframe_html" in params:
        return await fn(html, url, values, iframe_html=iframe_html)
    return await fn(html, url, values)


@app.post("/scan-dynamic")
async def scan_dynamic(request: Request):
    body = await request.json()
    html = body.get("html", "")
    values = body.get("values", {}) or {}
    url = body.get("url", "")
    # HTML фрейма (напр. iframe#editor_0 на странице дневниковой записи) —
    # физически внешний документ, расширение снимает его отдельно и присылает
    # тут. Пока не все спец-сканеры это используют (см. _call_scanner ниже).
    iframe_html = body.get("iframe_html")
    _remember_patient_ids(html, url)
    _remember_page(html, url)

    scanner = None
    warning = None
    try:
        # выбираем специализированный сканер по URL
        entry = None
        try:
            first_scan = _load_first_scan()
            entry = first_scan.pick(html, url)
        except Exception as e:
            traceback.print_exc()
            warning = f"first_scan недоступен, общий разбор: {e}"

        if entry is not None:
            try:
                elements = await _call_scanner(entry["fn"], html, url, values, iframe_html)
                scanner = entry.get("name")
            except Exception as e:
                # Playwright/Chromium не установлен, таймаут set_content и т.п.
                traceback.print_exc()
                warning = (f"спец-сканер '{entry.get('name')}' упал, "
                           f"откат на общий разбор: {e}")
                elements = _scan_html(html, values, url)
        else:
            # неизвестная страница — ведём себя как /scan
            elements = _scan_html(html, values, url)

        # спец-правила из /scan применяем и здесь — единый вход/выход с /scan
        for rule in SPECIAL_RULES:
            if rule.get("match") and rule["match"] in url:
                elements.insert(0, {
                    "description": rule.get("description", ""),
                    "selector": rule.get("selector", ""),
                    "method": rule.get("method", "click"),
                    "type_write": rule.get("type_write", "write"),
                    "value": values.get(rule.get("selector", ""), None),
                    "address": url,
                })

        resp = {"url": url, "count": len(elements), "elements": elements,
                "scanner": scanner}
        if warning:
            resp["warning"] = warning
        return resp
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"scan-dynamic: {e}"})


# ═══════════════════════════════ /macro ══════════════════════════════
# Для type_write=writeByClick: расширение уже сфокусировало элемент кликом,
# сюда приходит value — набираем его на клавиатуре. Для unicode (рус/каз)
# используем вставку из буфера (Ctrl+V). Опционально keys для спец-клавиш.

@app.post("/macro")
async def macro(request: Request):
    body = await request.json()
    value = body.get("value", "")
    keys = body.get("keys")   # напр. "enter" | "tab" | ["ctrl","s"]
    try:
        import pyautogui
        pyautogui.PAUSE = 0.02
        if keys:
            if isinstance(keys, list):
                pyautogui.hotkey(*keys)
            else:
                pyautogui.press(str(keys))
            return {"ok": True, "action": "keys", "keys": keys}

        if CONFIG.get("macro_paste", True):
            import pyperclip
            prev = None
            try:
                prev = pyperclip.paste()
            except Exception:
                pass
            pyperclip.copy(value)
            pyautogui.hotkey("ctrl", "v")
            # вернуть прежний буфер не обязательно; оставим значение
        else:
            pyautogui.typewrite(value, interval=0.01)
        return {"ok": True, "action": "type", "len": len(value)}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"macro: {e}"})


# ═══════════════════════════════ /ocr ════════════════════════════════
@app.post("/ocr")
async def ocr(file: UploadFile = File(...), langs: str = Form(None)):
    langs = langs or CONFIG["ocr_langs"]
    data = await file.read()
    name = (file.filename or "document").lower()
    try:
        if name.endswith(".pdf"):
            text = _ocr_pdf(data, langs)
        elif name.endswith(".docx"):
            text = _ocr_docx(data)
        else:
            text = _ocr_image(data, langs)
        return {"text": (text or "").strip(), "file": file.filename}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"detail": f"ocr: {e}"})


def _tess_configure():
    if CONFIG.get("tesseract_cmd"):
        import pytesseract
        pytesseract.pytesseract.tesseract_cmd = CONFIG["tesseract_cmd"]


def _ocr_image(data, langs):
    _tess_configure()
    import pytesseract
    from PIL import Image
    img = Image.open(io.BytesIO(data))
    return pytesseract.image_to_string(img, lang=langs)


def _ocr_docx(data):
    import docx  # python-docx
    doc = docx.Document(io.BytesIO(data))
    return "\n".join(p.text for p in doc.paragraphs)


def _ocr_pdf(data, langs):
    """Сначала пытаемся достать текстовый слой; если пусто — рендерим страницы
    в картинки и прогоняем через tesseract."""
    import fitz  # PyMuPDF
    doc = fitz.open(stream=data, filetype="pdf")
    text_parts = []
    for page in doc:
        text_parts.append(page.get_text())
    joined = "\n".join(text_parts).strip()
    if len(joined) >= 20:
        return joined

    # текстового слоя нет — OCR по изображениям
    _tess_configure()
    import pytesseract
    from PIL import Image
    ocr_parts = []
    for page in doc:
        pix = page.get_pixmap(dpi=200)
        img = Image.open(io.BytesIO(pix.tobytes("png")))
        ocr_parts.append(pytesseract.image_to_string(img, lang=langs))
    return "\n".join(ocr_parts)

# ═══════════════════════════════ MAIN ════════════════════════════════
if __name__ == "__main__":
    print("Suerte Vox server → http://{}:{}".format(CONFIG["host"], CONFIG["port"]))
    print("  provider={}  ocr={}".format(CONFIG["provider"], CONFIG["ocr_langs"]))
    uvicorn.run(app, host=CONFIG["host"], port=int(CONFIG["port"]), log_level="info")
