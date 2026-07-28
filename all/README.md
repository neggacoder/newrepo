# Vox — голосовой ИИ-агент для врачей в Damumed

Продукт команды **Suerte**. Vox слушает голос врача и сам выполняет действия в медицинской
информационной системе **Damumed** (`hospital-akt.dmed.kz`): открывает нужные вкладки,
заполняет поля, переносит данные в мед. запись. Врач говорит — руки остаются свободными.

## Архитектура

Три компонента; разделение продиктовано тем, где разрешено находиться данным:

| Компонент | Где работает | За что отвечает |
|---|---|---|
| `extension/` | Chrome врача (MV3, «Suerte AI Agent») | Запись голоса (wake/sleep/stop-слова), панель-виджет, исполнение планов действий в DOM, автозаполнение мед. записи |
| `user_server/` | Windows-машина врача, `127.0.0.1:8000` (FastAPI) | Скан DOM (`/scan`, `/scan-dynamic`), макросы pyautogui, OCR (tesseract/PyMuPDF/docx). **Карточки пациентов хранятся только здесь** — медицинские ПДн не покидают машину врача |
| `server/` | Linux VPS, порт 8080 (FastAPI) | «Мозг»: вызовы LLM (Ollama qwen2.5-coder:14b / OpenAI / DeepSeek), строгие JSON-планы шагов, транскрипция (faster-whisper), учёт затрат LLM, админ-панель |

Ключевые принципы:

- **Корректность плана обеспечивается кодом, а не промптом** — LLM только выбирает,
  детерминированный код строит и валидирует шаги (`router.py`, `medrecord.py`).
- **Две ступени LLM**: дешёвый роутер выбирает страницу по `routes.json`, исполнитель видит
  элементы только выбранной страницы — экономия токенов.
- **Единый формат действия**: `{selector, method: click|write, type_write: changeInnerHTML|write|writeByClick, value, address}`.
- Карточка пациента попадает на главный сервер только внутрь промпта per-request и нигде не сохраняется.

## Запуск

```bash
# Главный сервер (Linux VPS; прод — systemd unit aqbobek.service)
cd server && uvicorn server:app --host 0.0.0.0 --port 8080

# Локальный сервер (Windows-машина врача)
python user_server/user_server.py

# Расширение: chrome://extensions → «Режим разработчика» → «Загрузить распакованное» → каталог extension/
```

Зависимости: `server/requirements.txt`, `user_server/requirements.txt`.
Конфигурация: приоритет — реальное окружение > `.env` > `config.json` > дефолты
(см. `.env.example` и `config.example.json` в каждом сервере).
Установка на машину врача — `install.bat` (Python + Tesseract + автозапуск).

## Тесты

```bash
# Python — каждый файл самодостаточен (или: pytest server/tests/ user_server/tests/)
python server/tests/test_router.py
python user_server/tests/test_patients.py

# Расширение — встроенный test runner Node, без npm
node --test "extension/tests/*.test.js"
```

Селекторы под Damumed тестируются на сохранённых страницах-фикстурах
(`file.html`, `file1.html`, `file2.html` в корне репозитория) — сам Damumed мы менять не можем.

## Важно

- Карточки пациентов — реальные медицинские ПДн: их хранение и логирование не переносить
  из `user_server/` на главный сервер.
- Не коммитить: `.env`, `config.json`, `usage.db`, `admin_secret.json`, каталог `patients/`.
