"""
Suerte / Aqbobek — Админ-панель (модуль главного сервера).
──────────────────────────────────────────────────────────────────────────
Безопасность (по требованию ТЗ — «не забивай на безопасность»):
  • Пароль и PIN НИКОГДА не хранятся в открытом виде — только argon2id-хеш.
  • Проверка пароля/PIN — на сервере (клиент шлёт их по HTTPS в теле запроса).
  • Сессия — HMAC-подписанный токен с истечением (itsdangerous), Bearer-заголовок.
  • Rate-limit + блокировка по IP после серии неудачных попыток.
  • Первый запуск: пароль/PIN задаёт админ сам (first-run setup) — в репозитории
    секретов НЕТ. Хеши и секрет сессии пишутся в admin_store (вне git).
  • Доступ к файлам «в тюрьме» (jail) в пределах проекта; запись — по allowlist.
  • systemctl restart/stop — фиксированные аргументы, только unit aqbobek.service.

Подключается в server.py:  app.include_router(admin.router)
"""

import os
import io
import csv
import json
import time
import secrets
import subprocess

from fastapi import APIRouter, Request, Header, HTTPException, Depends, Query
from fastapi.responses import FileResponse, JSONResponse, Response

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

# ───────────────────────────── ПУТИ / КОНФИГ ─────────────────────────────
HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.realpath(os.path.dirname(HERE))   # корень репозитория/проекта
SERVICE_UNIT = "aqbobek.service"

# Где хранить хеши и секрет сессии (вне git). На проде — /etc/aqbobek/admin.json
ADMIN_STORE = os.environ.get("ADMIN_STORE") or os.path.join(HERE, "admin_secret.json")

# Куда можно ПИСАТЬ (allowlist). Чтение — любой текст в пределах PROJECT_ROOT.
WRITABLE_FILES = {
    os.path.realpath(os.path.join(HERE, "config.json")),
    os.path.realpath(os.path.join(HERE, "scaner.json")),
    os.path.realpath(os.path.join(HERE, "dynamic.txt")),
}
WRITABLE_DIRS = [
    os.path.realpath(os.path.join(HERE, "Scaners")),
    os.path.realpath(os.path.join(HERE, "templates")),
]
WRITABLE_EXT = {".json", ".txt"}   # .py писать через панель нельзя (защита от RCE)

SESSION_TTL = 30 * 60              # 30 минут
MAX_FAILS = 5                      # неудачных попыток до блокировки
LOCKOUT_SEC = 15 * 60             # блокировка на 15 минут

ph = PasswordHasher()
router = APIRouter(prefix="/admin")

# ───────────────────────────── ХРАНИЛИЩЕ ─────────────────────────────
def _load_store():
    if not os.path.exists(ADMIN_STORE):
        return None
    try:
        with open(ADMIN_STORE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _save_store(store):
    os.makedirs(os.path.dirname(ADMIN_STORE), exist_ok=True)
    with open(ADMIN_STORE, "w", encoding="utf-8") as f:
        json.dump(store, f)
    try:
        os.chmod(ADMIN_STORE, 0o600)   # только владелец
    except OSError:
        pass


def _serializer():
    store = _load_store()
    secret = store.get("session_secret") if store else None
    if not secret:
        raise HTTPException(status_code=503, detail="Админка не настроена")
    return URLSafeTimedSerializer(secret, salt="aqbobek-admin")


# ───────────────────────── RATE LIMIT (в памяти) ─────────────────────────
_fails = {}   # ip -> {"n": int, "until": ts}


def _client_ip(request: Request):
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "?"


def _check_lock(ip):
    rec = _fails.get(ip)
    if rec and rec.get("until", 0) > time.time():
        wait = int(rec["until"] - time.time())
        raise HTTPException(status_code=429, detail=f"Слишком много попыток. Подождите {wait} с.")


def _register_fail(ip):
    rec = _fails.get(ip) or {"n": 0, "until": 0}
    rec["n"] += 1
    if rec["n"] >= MAX_FAILS:
        rec["until"] = time.time() + LOCKOUT_SEC
        rec["n"] = 0
    _fails[ip] = rec


def _clear_fail(ip):
    _fails.pop(ip, None)


# ───────────────────────── АУТЕНТИФИКАЦИЯ ─────────────────────────
def require_auth(authorization: str = Header(None)):
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Требуется вход")
    token = authorization.split(" ", 1)[1]
    try:
        _serializer().loads(token, max_age=SESSION_TTL)
    except SignatureExpired:
        raise HTTPException(status_code=401, detail="Сессия истекла")
    except BadSignature:
        raise HTTPException(status_code=401, detail="Недействительный токен")
    return True


# ═══════════════════════════ СТАТИКА / СТРАНИЦА ═══════════════════════════
@router.get("")
@router.get("/")
async def admin_page():
    return FileResponse(os.path.join(HERE, "admin.html"))


@router.get("/admin.js")
async def admin_js():
    return FileResponse(os.path.join(HERE, "admin.js"), media_type="application/javascript")


@router.get("/admin.css")
async def admin_css():
    return FileResponse(os.path.join(HERE, "admin.css"), media_type="text/css")


@router.get("/state")
async def state():
    return {"configured": _load_store() is not None}


# ═══════════════════════════ SETUP / LOGIN ═══════════════════════════
@router.post("/setup")
async def setup(request: Request):
    """First-run: задать пароль+PIN. Работает только пока админка не настроена."""
    if _load_store() is not None:
        raise HTTPException(status_code=409, detail="Админка уже настроена")
    body = await request.json()
    password = (body.get("password") or "").strip()
    pin = (body.get("pin") or "").strip()
    if len(password) < 8:
        raise HTTPException(status_code=400, detail="Пароль минимум 8 символов")
    if not (pin.isdigit() and 4 <= len(pin) <= 8):
        raise HTTPException(status_code=400, detail="PIN — 4–8 цифр")
    store = {
        "password_hash": ph.hash(password),
        "pin_hash": ph.hash(pin),
        "session_secret": secrets.token_urlsafe(48),
        "created_at": int(time.time()),
    }
    _save_store(store)
    return {"ok": True}


@router.post("/login")
async def login(request: Request):
    ip = _client_ip(request)
    _check_lock(ip)
    store = _load_store()
    if store is None:
        raise HTTPException(status_code=503, detail="Админка не настроена")
    body = await request.json()
    password = (body.get("password") or "").strip()
    pin = (body.get("pin") or "").strip()

    ok = True
    for hashed, value in ((store["password_hash"], password), (store["pin_hash"], pin)):
        try:
            ph.verify(hashed, value)
        except VerifyMismatchError:
            ok = False
        except Exception:
            ok = False
    if not ok:
        _register_fail(ip)
        raise HTTPException(status_code=401, detail="Неверный пароль или PIN")

    _clear_fail(ip)
    # обновим хеши при смене параметров argon2 (rehash), best-effort
    token = URLSafeTimedSerializer(store["session_secret"], salt="aqbobek-admin").dumps({"u": "admin", "t": int(time.time())})
    return {"ok": True, "token": token, "ttl": SESSION_TTL}


@router.post("/change-password")
async def change_password(request: Request, _auth: bool = Depends(require_auth)):
    store = _load_store()
    body = await request.json()
    old = (body.get("old_password") or "").strip()
    try:
        ph.verify(store["password_hash"], old)
    except Exception:
        raise HTTPException(status_code=401, detail="Старый пароль неверный")
    new = (body.get("new_password") or "").strip()
    if len(new) < 8:
        raise HTTPException(status_code=400, detail="Новый пароль минимум 8 символов")
    store["password_hash"] = ph.hash(new)
    if body.get("new_pin"):
        pin = str(body["new_pin"]).strip()
        if not (pin.isdigit() and 4 <= len(pin) <= 8):
            raise HTTPException(status_code=400, detail="PIN — 4–8 цифр")
        store["pin_hash"] = ph.hash(pin)
    _save_store(store)
    return {"ok": True}


# ═══════════════════════════ СЛУЖБА / ЛОГИ ═══════════════════════════
@router.get("/status")
async def svc_status(_auth: bool = Depends(require_auth)):
    try:
        out = subprocess.run(
            ["systemctl", "is-active", SERVICE_UNIT],
            capture_output=True, text=True, timeout=10
        )
        active = out.stdout.strip()
    except Exception as e:
        active = f"unknown ({e})"
    return {"unit": SERVICE_UNIT, "active": active}


@router.post("/service")
async def svc_control(request: Request, _auth: bool = Depends(require_auth)):
    body = await request.json()
    action = (body.get("action") or "").strip()
    if action not in ("restart", "stop", "start"):
        raise HTTPException(status_code=400, detail="Действие: restart|stop|start")
    cmd = ["sudo", "systemctl", action, SERVICE_UNIT]
    try:
        if action == "restart":
            # restart убьёт текущий процесс — запускаем в фоне и сразу отвечаем
            subprocess.Popen(cmd)
            return {"ok": True, "action": action, "note": "Перезапуск инициирован"}
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        if out.returncode != 0:
            raise HTTPException(status_code=500, detail=out.stderr.strip() or "systemctl error")
        return {"ok": True, "action": action}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ═══════════════════════════ ПРОВАЙДЕР / МОДЕЛИ ИИ ═══════════════════════════
CONFIG_PATH = os.path.join(HERE, "config.json")
KNOWN_PROVIDERS = ("qwen", "openai", "deepseek")


def _mask_key(key):
    """Никогда не отдаём ключ целиком в UI — только признак наличия + маску."""
    key = key or ""
    if not key:
        return ""
    if len(key) <= 8:
        return "•" * len(key)
    return key[:4] + "…" + key[-4:]


def _merge_config(updates):
    """Применить настройки сразу (в памяти) и слить их в config.json на диске."""
    import server
    server.CONFIG.update(updates)

    on_disk = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                on_disk = json.load(f)
        except Exception:
            on_disk = {}
    on_disk.update(updates)
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(on_disk, f, ensure_ascii=False, indent=2)
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail="Настройки применены в памяти, но не удалось сохранить config.json: {}".format(e),
        )


@router.get("/ai-settings")
async def get_ai_settings(_auth: bool = Depends(require_auth)):
    """Текущие настройки провайдера/моделей (ключи API отдаём только в замаскированном виде)."""
    try:
        import server
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Модуль server.py недоступен: {e}")
    cfg = server.CONFIG
    return {
        "provider": cfg.get("provider", "qwen"),
        "ollama_url": cfg.get("ollama_url", ""),
        "ollama_model": cfg.get("ollama_model", ""),
        "openai_model": cfg.get("openai_model", ""),
        "openai_api_key_set": bool(cfg.get("openai_api_key")),
        "openai_api_key_masked": _mask_key(cfg.get("openai_api_key")),
        "deepseek_model": cfg.get("deepseek_model", ""),
        "deepseek_api_key_set": bool(cfg.get("deepseek_api_key")),
        "deepseek_api_key_masked": _mask_key(cfg.get("deepseek_api_key")),
        "request_timeout": cfg.get("request_timeout", 120),
        "openai_prices": cfg.get("openai_prices"),
        "deepseek_prices": cfg.get("deepseek_prices"),
    }


@router.post("/ai-settings")
async def set_ai_settings(request: Request, _auth: bool = Depends(require_auth)):
    """Обновить провайдер/модели/ключи. Применяется СРАЗУ (в памяти) и сохраняется в config.json.
    Поля API-ключей: пустая строка/отсутствие поля = "не менять" (чтобы фронт не мог случайно
    затереть ключ пустым значением, если админ просто не тронул это поле)."""
    try:
        import server
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Модуль server.py недоступен: {e}")

    body = await request.json()
    updates = {}

    if "provider" in body:
        provider = str(body["provider"]).strip().lower()
        if provider not in KNOWN_PROVIDERS:
            raise HTTPException(status_code=400, detail=f"provider должен быть одним из: {', '.join(KNOWN_PROVIDERS)}")
        updates["provider"] = provider

    for field in ("ollama_url", "ollama_model", "openai_model", "deepseek_model"):
        if field in body:
            val = str(body[field]).strip()
            if val:
                updates[field] = val

    # Ключи меняем ТОЛЬКО если реально прислали непустое новое значение
    if str(body.get("openai_api_key") or "").strip():
        updates["openai_api_key"] = str(body["openai_api_key"]).strip()
    if str(body.get("deepseek_api_key") or "").strip():
        updates["deepseek_api_key"] = str(body["deepseek_api_key"]).strip()

    if body.get("request_timeout") not in (None, ""):
        try:
            timeout = int(body["request_timeout"])
        except Exception:
            raise HTTPException(status_code=400, detail="request_timeout должен быть целым числом секунд")
        if not (5 <= timeout <= 600):
            raise HTTPException(status_code=400, detail="request_timeout: 5–600 секунд")
        updates["request_timeout"] = timeout

    for field in ("openai_prices", "deepseek_prices"):
        if field in body and isinstance(body[field], dict):
            updates[field] = body[field]

    if not updates:
        raise HTTPException(status_code=400, detail="Нет изменений для сохранения")

    # применяем немедленно (без перезапуска службы) и сохраняем в config.json
    _merge_config(updates)

    return {"ok": True, "updated": sorted(updates.keys())}


# ═══════════════════════════ ЗАТРАТЫ НА LLM ═══════════════════════════
def _usage_module():
    try:
        import usage
        return usage
    except Exception as e:
        raise HTTPException(status_code=500, detail="Модуль usage.py недоступен: {}".format(e))


def _budget_limit():
    """Месячный лимит в $ из config.json. 0 или отсутствие ключа = лимит не задан."""
    try:
        import server
        return float(server.CONFIG.get("monthly_budget_usd") or 0)
    except Exception:
        return 0.0


@router.get("/usage/summary")
async def usage_summary(_auth: bool = Depends(require_auth), days: int = 30):
    """KPI, бюджет, разбивка по дням/моделям/провайдерам. days=0 — за всё время."""
    days = 0 if int(days) == 0 else max(1, min(365, int(days)))
    usage = _usage_module()
    try:
        data = usage.summary(days)
        data["db"] = usage.db_info()
    except Exception as e:
        raise HTTPException(status_code=500, detail="База затрат недоступна: {}".format(e))

    limit = _budget_limit()
    spent = data["month"]["cost_usd"]
    data["budget"] = {
        "limit_usd": limit,
        "spent_usd": round(spent, 6),
        "pct": round(spent / limit * 100, 1) if limit else None,
    }
    return data


@router.get("/usage/calls")
async def usage_calls(
    _auth: bool = Depends(require_auth),
    limit: int = 50,
    offset: int = 0,
    provider: str = None,
    model: str = None,
    q: str = None,
    date_from: str = Query(None, alias="from"),
    date_to: str = Query(None, alias="to"),
):
    """Страница журнала вызовов с фильтрами."""
    usage = _usage_module()
    try:
        return usage.calls(limit=max(1, min(500, int(limit))), offset=offset, provider=provider,
                           model=model, q=q, date_from=date_from, date_to=date_to)
    except Exception as e:
        raise HTTPException(status_code=500, detail="База затрат недоступна: {}".format(e))


@router.get("/usage/calls.csv")
async def usage_calls_csv(
    _auth: bool = Depends(require_auth),
    provider: str = None,
    model: str = None,
    q: str = None,
    date_from: str = Query(None, alias="from"),
    date_to: str = Query(None, alias="to"),
):
    """Выгрузка отфильтрованного журнала целиком (limit=0 — без ограничения строк)."""
    usage = _usage_module()
    try:
        res = usage.calls(limit=0, offset=0, provider=provider, model=model, q=q,
                          date_from=date_from, date_to=date_to)
    except Exception as e:
        raise HTTPException(status_code=500, detail="База затрат недоступна: {}".format(e))

    buf = io.StringIO()
    # Точка с запятой + BOM: так Excel с русской локалью открывает файл без плясок.
    w = csv.writer(buf, delimiter=";", lineterminator="\n")
    w.writerow(["Время", "Провайдер", "Модель", "Источник", "Prompt", "Completion",
                "Всего", "Стоимость USD", "Есть цена"])
    for r in res["rows"]:
        w.writerow([r["ts"], r["provider"], r["model"], r["endpoint"] or "",
                    r["prompt_tokens"], r["completion_tokens"], r["total_tokens"],
                    "{:.6f}".format(r["cost_usd"]), "да" if r["priced"] else "нет"])

    return Response(
        content="\ufeff" + buf.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="token_usage.csv"'},
    )


@router.post("/usage/budget")
async def set_budget(request: Request, _auth: bool = Depends(require_auth)):
    """Месячный лимит в $. Только индикация — запросы к LLM не блокируются."""
    body = await request.json()
    try:
        limit = float(body.get("monthly_budget_usd") or 0)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="monthly_budget_usd должен быть числом")
    if limit < 0 or limit > 1_000_000:
        raise HTTPException(status_code=400, detail="Лимит вне диапазона 0…1000000")

    _merge_config({"monthly_budget_usd": limit})
    return {"ok": True, "monthly_budget_usd": limit}


@router.get("/logs")
async def logs(_auth: bool = Depends(require_auth), lines: int = 200):
    lines = max(10, min(2000, int(lines)))
    try:
        out = subprocess.run(
            ["sudo", "journalctl", "-u", SERVICE_UNIT, "-n", str(lines), "--no-pager", "-o", "short-iso"],
            capture_output=True, text=True, timeout=20
        )
        text = out.stdout or out.stderr
    except Exception as e:
        text = f"Не удалось получить логи: {e}"
    return {"unit": SERVICE_UNIT, "text": text}


# ═══════════════════════════ ФАЙЛЫ (jail) ═══════════════════════════
def _safe(rel):
    p = os.path.realpath(os.path.join(PROJECT_ROOT, rel or ""))
    if p != PROJECT_ROOT and not p.startswith(PROJECT_ROOT + os.sep):
        raise HTTPException(status_code=403, detail="Путь вне проекта запрещён")
    return p


def _is_writable(path):
    rp = os.path.realpath(path)
    if rp in WRITABLE_FILES:
        return True
    if os.path.splitext(rp)[1].lower() not in WRITABLE_EXT:
        return False
    return any(rp == d or rp.startswith(d + os.sep) for d in WRITABLE_DIRS)


@router.get("/files")
async def list_files(_auth: bool = Depends(require_auth), path: str = ""):
    target = _safe(path)
    if not os.path.isdir(target):
        raise HTTPException(status_code=400, detail="Не папка")
    items = []
    for name in sorted(os.listdir(target)):
        if name in (".git", "venv", "node_modules", "__pycache__", "admin_secret.json"):
            continue
        full = os.path.join(target, name)
        items.append({
            "name": name,
            "dir": os.path.isdir(full),
            "size": os.path.getsize(full) if os.path.isfile(full) else None,
            "writable": os.path.isfile(full) and _is_writable(full),
        })
    rel = os.path.relpath(target, PROJECT_ROOT)
    return {"path": "" if rel == "." else rel.replace("\\", "/"), "items": items}


@router.get("/file")
async def read_file(_auth: bool = Depends(require_auth), path: str = ""):
    target = _safe(path)
    if not os.path.isfile(target):
        raise HTTPException(status_code=404, detail="Файл не найден")
    if os.path.getsize(target) > 2 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Файл слишком большой для просмотра")
    try:
        with open(target, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"path": os.path.relpath(target, PROJECT_ROOT).replace("\\", "/"),
            "content": content, "writable": _is_writable(target)}


@router.post("/file")
async def write_file(request: Request, _auth: bool = Depends(require_auth)):
    body = await request.json()
    target = _safe(body.get("path", ""))
    if not _is_writable(target):
        raise HTTPException(status_code=403, detail="Этот файл недоступен для записи через панель")
    content = body.get("content", "")
    # если .json — проверим валидность перед записью
    if target.lower().endswith(".json"):
        try:
            json.loads(content)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"Невалидный JSON: {e}")
    try:
        with open(target, "w", encoding="utf-8") as f:
            f.write(content)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    return {"ok": True, "path": os.path.relpath(target, PROJECT_ROOT).replace("\\", "/")}
