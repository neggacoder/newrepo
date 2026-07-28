-- Suerte / Aqbobek — схема учёта затрат на LLM.
-- Применяется автоматически при первом обращении к базе (usage.init_db),
-- либо вручную:  sqlite3 server/usage.db < server/schema.sql
-- Все выражения идемпотентны, повторное применение безопасно.

CREATE TABLE IF NOT EXISTS llm_calls (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  ts                TEXT    NOT NULL,              -- '2026-07-10 14:22:31', локальное время сервера
  day               TEXT    NOT NULL,              -- '2026-07-10', для группировки по дням
  provider          TEXT    NOT NULL,              -- openai | deepseek
  model             TEXT    NOT NULL,
  prompt_tokens     INTEGER NOT NULL DEFAULT 0,
  completion_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens      INTEGER NOT NULL DEFAULT 0,
  cost_usd          REAL    NOT NULL DEFAULT 0,
  priced            INTEGER NOT NULL DEFAULT 1,    -- 0, если цены для модели не нашлось
  endpoint          TEXT                           -- 'command' | 'ocr-template' | NULL
);

CREATE INDEX IF NOT EXISTS idx_calls_day      ON llm_calls(day);
CREATE INDEX IF NOT EXISTS idx_calls_ts       ON llm_calls(ts DESC);
CREATE INDEX IF NOT EXISTS idx_calls_prov_mod ON llm_calls(provider, model);

-- Служебные отметки: версия схемы, признак выполненного бэкфилла.
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
