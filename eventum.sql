-- =====================================================================================
--  EVENTUM — база данных общественного фонда «Urpaq Inclusive» (Актобе, Казахстан)
--  Полная серверная часть портала персонала (staff-portal.html) и публичного сайта
--  (index.html / foundation.html).
--
--  СУБД:      PostgreSQL 14 и выше
--  Кодировка: UTF-8
--  Файл:      eventum.sql   (один файл, выполняется сверху вниз)
--  Версия:    1.2
--
-- -------------------------------------------------------------------------------------
--  ЗАЧЕМ ЭТОТ ФАЙЛ
-- -------------------------------------------------------------------------------------
--  В README.txt проекта прямо сказано, что портал персонала — это интерфейсный прототип
--  с вымышленными данными в браузере, и что для реальной конфиденциальной системы нужны:
--
--      «защищённый сервер, база данных, серверная авторизация, разграничение прав,
--       шифрование, журналирование и резервное копирование»
--
--  Этот файл закрывает всё, что относится к базе данных, каждым своим разделом:
--
--      база данных             → разделы 03–10  (схемы и таблицы)
--      серверная авторизация   → разделы 05, 11 (sec.*, вход, пароли, сессии)
--      разграничение прав      → разделы 14, 16  (RLS-политики и GRANT по ролям)
--      шифрование              → раздел 05.9    (pgcrypto, хеширование, шифрование полей)
--      журналирование          → раздел 04 + 12 (schema audit, append-only, триггеры)
--      резервное копирование   → раздел 15      (роль backup, регламент, обслуживание)
--
-- -------------------------------------------------------------------------------------
--  ЧТО ЗДЕСЬ ХРАНИТСЯ — ЭТО ЧУВСТВИТЕЛЬНЫЕ ДАННЫЕ
-- -------------------------------------------------------------------------------------
--  Это данные о несовершеннолетних детях с особенностями развития: имена, даты рождения,
--  сведения о развитии и поведении, записи специалистов, медицинские документы, переписка
--  команды. Это специальная категория персональных данных.
--
--  ОБЯЗАТЕЛЬНО при внедрении:
--    * согласия семей фиксируются в eventum.consents ДО обработки и публикации;
--    * доступ строго по RLS-политикам (раздел 12), «по умолчанию — запрещено»;
--    * все обращения к данным ребёнка пишутся в audit.data_access_log;
--    * соединение только по TLS (sslmode=verify-full), диск — с шифрованием (LUKS/dm-crypt);
--    * закон РК «О персональных данных и их защите» № 94-V — требования по локализации
--      базы на территории РК и уведомлению уполномоченного органа необходимо подтвердить
--      с юристом фонда. Схема к этому готова (согласия, срок хранения, удаление, журнал),
--      но юридическую квалификацию должен дать специалист.
--
-- -------------------------------------------------------------------------------------
--  КАРТА СООТВЕТСТВИЯ: экран портала  →  объекты базы
-- -------------------------------------------------------------------------------------
--   loginScreen        → sec.authenticate(), sec.begin_request(), sec.auth_sessions
--   view-dashboard     → eventum.v_dashboard_metrics, v_today_schedule, v_recent_logs
--   view-children      → eventum.children, eventum.v_children_overview
--   childDrawer        → eventum.goals, child_tasks, progress_logs, chat_messages, documents
--   childChat          → eventum.post_chat_message(), chat_threads, chat_mentions
--   logForm / logModal → eventum.add_progress_log(), eventum.log_types
--   view-sessions      → eventum.therapy_sessions, eventum.schedule_session()
--   view-approvals     → eventum.change_requests, eventum.v_pending_change_requests
--   view-users         → sec.users, sec.roles, sec.v_user_directory
--   view-centers       → eventum.centers, eventum.v_center_load
--   view-audit         → audit.activity_log, audit.v_recent_activity
--   notificationPanel  → eventum.notifications, eventum.v_my_notifications
--   documentDrop       → eventum.upload_document(), document_chunks (файлы в самой базе)
--   documentGrid       → eventum.v_child_documents
--   скачивание файла   → eventum.document_download() + audit.data_access_log
--   requestAccess      → eventum.access_requests
--   contactForm        → site.submit_contact_request() → site.contact_requests
--   joinForm           → site.submit_join_request()    → site.join_requests
--   donationForm       → site.create_donation() / site.confirm_donation() → site.donations
--   секция «Отчётность»→ site.v_public_donors, site.v_donation_progress, site.public_reports
--
-- -------------------------------------------------------------------------------------
--  ЧТО РАНЬШЕ ЖИЛО В БРАУЗЕРЕ — И ГДЕ ЖИВЁТ ТЕПЕРЬ
-- -------------------------------------------------------------------------------------
--  Прототип хранит всё на стороне пользователя. Это значит: данные видны любому, кто сел
--  за этот компьютер; чистка кеша стирает их без следа; на другом устройстве их просто нет
--  (портал честно пишет «Файл недоступен в этом браузере»); резервной копии не существует.
--  Ниже — полный перечень того, что было в браузере, и таблица, которая это заменяет.
--
--   localStorage «urpaq-staff-demo»
--     .users          → sec.users, sec.roles, sec.role_permissions
--     .children       → eventum.children, child_guardians, guardians, child_team_members
--     .children[].tasks     → eventum.child_tasks
--     .children[].messages  → eventum.chat_threads, chat_messages, chat_mentions
--     .children[].participants → eventum.child_team_members (ссылки на sec.users, не строки)
--     .logs           → eventum.progress_logs, eventum.log_types
--     .sessions       → eventum.therapy_sessions, session_attendees, session_staff
--     .documents      → eventum.documents (метаданные)
--     .notifications  → eventum.notifications
--     .approvals      → eventum.change_requests, eventum.access_requests
--     .audit          → audit.activity_log, audit.security_events, audit.data_access_log
--   localStorage «urpaq-staff-lang»              → sec.user_preferences.locale
--   localStorage «urpaq-staff-sidebar-width»     → sec.user_preferences.sidebar_width
--   localStorage «urpaq-staff-sidebar-collapsed» → sec.user_preferences.sidebar_collapsed
--   IndexedDB «urpaq-staff-files» (сами файлы)   → eventum.document_chunks (см. раздел 09)
--
--   Зашитое в JavaScript на публичном сайте:
--     locales.ru/kk/en (все подписи)  → site.ui_strings + site.import_ui_strings()
--     programs, centers              → eventum.programs, eventum.centers + переводы
--     team                           → site.team_members + переводы
--     projects, news, blog, faq      → site.projects, news_posts, blog_posts, faq_items
--     training, calendar             → site.training_programs, training_events
--     trust, standards, joinOptions,
--     opportunities, topics          → site.content_blocks
--     legal (политика, оферта)       → site.legal_documents (с версиями)
--     needs (направления сбора)      → site.donation_directions
--     stats (счётчики)               → site.stat_counters
--     IMAGES (base64 в скрипте)      → eventum.documents + ссылки photo_document_id,
--                                      cover_document_id, file_document_id
--     window.URPAQ_CONFIG            → site.settings
--     формы, открывающие WhatsApp    → site.contact_requests, join_requests, donations
--
--  Единственное, что остаётся на стороне клиента, — токен сессии в защищённой cookie.
--  Ни персональных данных, ни файлов, ни настроек в браузере больше не хранится.
--
-- -------------------------------------------------------------------------------------
--  КАК ЗАПУСКАТЬ
-- -------------------------------------------------------------------------------------
--    psql -h <host> -U postgres -f eventum.sql
--
--  Файл использует мета-команды psql (\gexec, \connect, \echo), поэтому запускать нужно
--  именно через psql, а не через GUI-клиент. Скрипт идемпотентен: повторный запуск не
--  ломает существующую базу (IF NOT EXISTS / CREATE OR REPLACE везде, где это возможно).
-- =====================================================================================

\set ON_ERROR_STOP on
\timing off

-- =====================================================================================
--  РАЗДЕЛ 01. СОЗДАНИЕ БАЗЫ ДАННЫХ
-- =====================================================================================
--  Имя базы пишется в двойных кавычках: без них PostgreSQL приведёт EVENTUM к eventum.
--  CREATE DATABASE нельзя выполнять внутри транзакции, поэтому используется \gexec.

\echo '>>> [01] Создание базы данных "EVENTUM"...'

SELECT format(
         'CREATE DATABASE %I WITH ENCODING = ''UTF8'' LC_COLLATE = ''C'' LC_CTYPE = ''C'' TEMPLATE = template0',
         'EVENTUM')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'EVENTUM')
\gexec

\connect "EVENTUM"

-- =====================================================================================
--  РАЗДЕЛ 02. РОЛИ БАЗЫ ДАННЫХ (разграничение прав на уровне СУБД)
-- =====================================================================================
--  eventum_owner    — владелец объектов. Только миграции. Без права входа.
--  eventum_secdef   — владелец SECURITY DEFINER-функций. BYPASSRLS: служебные проверки
--                     доступа должны видеть все строки, иначе политики зациклятся.
--  eventum_app      — рабочая роль приложения. НЕ владелец, НЕ BYPASSRLS → на неё
--                     действуют все RLS-политики. Именно ею подключается бекенд.
--  eventum_readonly — аналитика/отчётность, только чтение обезличенных представлений.
--  eventum_auditor  — служба безопасности: читает только журналы.
--  eventum_backup   — резервное копирование (pg_dump / pg_basebackup).
--
--  ВНИМАНИЕ: пароли ниже — заглушки. Заменить перед установкой и хранить в секрет-
--  менеджере (Vault / AWS Secrets Manager / Doppler), а не в файле и не в git.
-- =====================================================================================

\echo '>>> [02] Создание ролей...'

DO $roles$
DECLARE
    v_is_superuser boolean;
BEGIN
    SELECT rolsuper INTO v_is_superuser FROM pg_roles WHERE rolname = current_user;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_owner') THEN
        CREATE ROLE eventum_owner NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_secdef') THEN
        IF v_is_superuser THEN
            CREATE ROLE eventum_secdef NOLOGIN BYPASSRLS;
        ELSE
            CREATE ROLE eventum_secdef NOLOGIN;
            RAISE WARNING 'Роль eventum_secdef создана без BYPASSRLS (нужен суперпользователь). Выполните: ALTER ROLE eventum_secdef BYPASSRLS;';
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_app') THEN
        CREATE ROLE eventum_app LOGIN PASSWORD 'CHANGE_ME_app_password' CONNECTION LIMIT 100;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_readonly') THEN
        CREATE ROLE eventum_readonly LOGIN PASSWORD 'CHANGE_ME_readonly_password' CONNECTION LIMIT 10;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_auditor') THEN
        CREATE ROLE eventum_auditor LOGIN PASSWORD 'CHANGE_ME_auditor_password' CONNECTION LIMIT 5;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_backup') THEN
        IF v_is_superuser THEN
            CREATE ROLE eventum_backup LOGIN REPLICATION PASSWORD 'CHANGE_ME_backup_password' CONNECTION LIMIT 5;
        ELSE
            CREATE ROLE eventum_backup LOGIN PASSWORD 'CHANGE_ME_backup_password' CONNECTION LIMIT 5;
        END IF;
    END IF;

    -- Текущий установщик должен уметь передавать владение этим ролям.
    IF NOT pg_has_role(current_user, 'eventum_owner',  'MEMBER') THEN
        EXECUTE format('GRANT eventum_owner TO %I',  current_user);
    END IF;
    IF NOT pg_has_role(current_user, 'eventum_secdef', 'MEMBER') THEN
        EXECUTE format('GRANT eventum_secdef TO %I', current_user);
    END IF;
END
$roles$;

-- Никто, кроме владельца, не должен создавать объекты в базе и в схеме public.
REVOKE ALL   ON DATABASE "EVENTUM" FROM PUBLIC;
GRANT  CONNECT ON DATABASE "EVENTUM" TO eventum_app, eventum_readonly, eventum_auditor, eventum_backup;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- =====================================================================================
--  РАЗДЕЛ 03. РАСШИРЕНИЯ И СХЕМЫ
-- =====================================================================================
--  Схемы:
--    core    — общие типы, домены и утилиты
--    sec     — идентификация, пароли, сессии, права (security)
--    eventum — рабочая часть: дети, центры, занятия, записи, документы, чат
--    site    — публичный сайт: заявки, пожертвования, контент на 3 языках
--    audit   — журналы (только добавление записей)
-- =====================================================================================

\echo '>>> [03] Расширения и схемы...'

CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- crypt(), gen_salt(), digest(), pgp_sym_*
CREATE EXTENSION IF NOT EXISTS citext;        -- регистронезависимые логины и e-mail
CREATE EXTENSION IF NOT EXISTS pg_trgm;       -- быстрый поиск по подстроке (globalSearch)
CREATE EXTENSION IF NOT EXISTS btree_gist;    -- защита от двойного бронирования специалиста
CREATE EXTENSION IF NOT EXISTS unaccent;      -- поиск без диакритики

CREATE SCHEMA IF NOT EXISTS core    AUTHORIZATION eventum_owner;
CREATE SCHEMA IF NOT EXISTS sec     AUTHORIZATION eventum_owner;
CREATE SCHEMA IF NOT EXISTS eventum AUTHORIZATION eventum_owner;
CREATE SCHEMA IF NOT EXISTS site    AUTHORIZATION eventum_owner;
CREATE SCHEMA IF NOT EXISTS audit   AUTHORIZATION eventum_owner;

COMMENT ON SCHEMA core    IS 'Общие типы, домены и служебные функции';
COMMENT ON SCHEMA sec     IS 'Безопасность: пользователи, пароли, сессии, роли и права';
COMMENT ON SCHEMA eventum IS 'Рабочая часть: дети, семьи, центры, занятия, записи, документы';
COMMENT ON SCHEMA site    IS 'Публичный сайт: заявки, пожертвования, многоязычный контент';
COMMENT ON SCHEMA audit   IS 'Журналирование: неизменяемые логи действий и событий безопасности';

SET search_path = core, sec, eventum, site, audit, public;

-- =====================================================================================
--  РАЗДЕЛ 03.1. ПЕРЕЧИСЛИМЫЕ ТИПЫ И ДОМЕНЫ
-- =====================================================================================

\echo '>>> [03.1] Типы и домены...'

DO $types$
BEGIN
    -- Языки сайта и портала: русский, казахский, английский
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'locale_code' AND n.nspname = 'core') THEN
        CREATE TYPE core.locale_code AS ENUM ('ru', 'kk', 'en');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'child_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.child_status AS ENUM ('waitlist', 'active', 'paused', 'graduated', 'archived');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'session_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.session_status AS ENUM ('planned', 'confirmed', 'in_progress', 'completed', 'cancelled', 'no_show');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'session_format' AND n.nspname = 'core') THEN
        CREATE TYPE core.session_format AS ENUM ('individual', 'group', 'online', 'home_visit', 'consultation', 'diagnostics');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'attendance_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.attendance_status AS ENUM ('unknown', 'present', 'late', 'absent', 'excused');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'goal_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.goal_status AS ENUM ('planned', 'in_progress', 'achieved', 'paused', 'cancelled');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'request_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.request_status AS ENUM ('pending', 'approved', 'rejected', 'cancelled');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'visibility_scope' AND n.nspname = 'core') THEN
        CREATE TYPE core.visibility_scope AS ENUM ('admin_only', 'team', 'parents', 'public');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'consent_purpose' AND n.nspname = 'core') THEN
        CREATE TYPE core.consent_purpose AS ENUM (
            'data_processing',      -- обработка персональных данных
            'medical_data',         -- обработка данных о здоровье
            'photo_publication',    -- публикация фотографий
            'video_publication',    -- публикация видео
            'name_publication',     -- публикация имени (в т.ч. имени донора)
            'third_party_sharing',  -- передача третьим лицам (партнёры, гос. органы)
            'newsletter',           -- рассылки
            'research'              -- участие в исследованиях, обезличенная статистика
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'document_category' AND n.nspname = 'core') THEN
        CREATE TYPE core.document_category AS ENUM (
            'consent', 'medical', 'assessment', 'individual_plan', 'progress_report',
            'legal', 'contract', 'photo', 'video', 'invoice', 'annual_report', 'other'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'password_algo' AND n.nspname = 'core') THEN
        CREATE TYPE core.password_algo AS ENUM ('bcrypt', 'argon2id', 'scrypt');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'notification_channel' AND n.nspname = 'core') THEN
        CREATE TYPE core.notification_channel AS ENUM ('in_app', 'email', 'sms', 'whatsapp', 'push');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'lead_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.lead_status AS ENUM ('new', 'in_progress', 'scheduled', 'done', 'rejected', 'spam', 'duplicate');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'donation_status' AND n.nspname = 'core') THEN
        CREATE TYPE core.donation_status AS ENUM ('created', 'pending', 'succeeded', 'failed', 'refunded', 'chargeback', 'cancelled');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'donor_visibility' AND n.nspname = 'core') THEN
        CREATE TYPE core.donor_visibility AS ENUM ('public', 'anonymous');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'join_kind' AND n.nspname = 'core') THEN
        CREATE TYPE core.join_kind AS ENUM ('sponsor', 'partner', 'media_partner', 'volunteer', 'internship', 'other');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'security_event_kind' AND n.nspname = 'core') THEN
        CREATE TYPE core.security_event_kind AS ENUM (
            'login_success', 'login_failed', 'account_locked', 'account_unlocked',
            'logout', 'session_revoked', 'password_changed', 'password_reset_requested',
            'password_reset_completed', 'password_policy_violation', 'permission_denied',
            'role_changed', 'user_deactivated', 'user_activated', 'mfa_enabled',
            'mfa_disabled', 'mfa_failed', 'data_export', 'suspicious_activity'
        );
    END IF;
END
$types$;

-- Домены с проверками на уровне базы: невалидные данные не запишутся даже в обход API.
DO $domains$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'email' AND n.nspname = 'core') THEN
        CREATE DOMAIN core.email AS citext
            CHECK (VALUE IS NULL OR VALUE ~ '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'phone' AND n.nspname = 'core') THEN
        -- Казахстанские и международные номера: +7 777 750 44 66, 87767504466 и т.п.
        CREATE DOMAIN core.phone AS text
            CHECK (VALUE IS NULL OR VALUE ~ '^\+?[0-9][0-9 ()\-]{4,29}$');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'percent' AND n.nspname = 'core') THEN
        CREATE DOMAIN core.percent AS smallint CHECK (VALUE IS NULL OR (VALUE >= 0 AND VALUE <= 100));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'slug' AND n.nspname = 'core') THEN
        CREATE DOMAIN core.slug AS text CHECK (VALUE ~ '^[a-z0-9]+(-[a-z0-9]+)*$');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'money_amount' AND n.nspname = 'core') THEN
        -- numeric, а не float: деньги нельзя хранить в плавающей точке.
        CREATE DOMAIN core.money_amount AS numeric(14, 2) CHECK (VALUE >= 0);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'currency_code' AND n.nspname = 'core') THEN
        CREATE DOMAIN core.currency_code AS char(3) CHECK (VALUE ~ '^[A-Z]{3}$');
    END IF;
END
$domains$;

-- =====================================================================================
--  РАЗДЕЛ 03.2. ОБЩИЕ СЛУЖЕБНЫЕ ФУНКЦИИ
-- =====================================================================================

-- Автоматическое обновление updated_at при любом UPDATE.
CREATE OR REPLACE FUNCTION core.tg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION core.tg_set_updated_at() IS 'Триггер: проставляет updated_at при UPDATE';

-- Запрет физического удаления там, где допускается только «мягкое» (deleted_at).
CREATE OR REPLACE FUNCTION core.tg_forbid_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'Физическое удаление из таблицы %.% запрещено. Используйте мягкое удаление (deleted_at) или функцию анонимизации.',
        TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = '42501';
END;
$$;

-- Нормализация строк поиска: нижний регистр без диакритики.
CREATE OR REPLACE FUNCTION core.normalize_search(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT lower(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g'));
$$;

-- Возраст ребёнка на дату (для отчётов и подбора программы).
CREATE OR REPLACE FUNCTION core.age_years(p_birth_date date, p_at date DEFAULT NULL)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
             WHEN p_birth_date IS NULL THEN NULL
             ELSE extract(year FROM age(coalesce(p_at, current_date), p_birth_date))::int
           END;
$$;

-- =====================================================================================
--  РАЗДЕЛ 04. ЖУРНАЛИРОВАНИЕ (schema audit) — только добавление записей
-- =====================================================================================
--  Три журнала:
--    audit.activity_log     — изменения данных (кто, что, когда, было/стало)
--    audit.security_events  — события безопасности (входы, пароли, блокировки, отказы)
--    audit.data_access_log  — чтение персональных и медицинских данных (кто открывал карту)
--
--  Журналы намеренно НЕ имеют внешних ключей на sec.users: запись в журнале должна
--  пережить удаление пользователя. Логин и роль дублируются текстом на момент события.
--
--  activity_log секционирован по месяцам: журнал растёт быстрее всех остальных таблиц,
--  а секции позволяют удалять и архивировать старое одним DROP TABLE, без VACUUM-боли.
-- =====================================================================================

\echo '>>> [04] Журналы аудита...'

CREATE TABLE IF NOT EXISTS audit.activity_log (
    id              bigint       GENERATED BY DEFAULT AS IDENTITY,
    occurred_at     timestamptz  NOT NULL DEFAULT clock_timestamp(),

    -- Кто
    actor_user_id   uuid,
    actor_username  text,
    actor_role      text,
    actor_ip        inet,
    actor_user_agent text,
    session_id      uuid,
    request_id      text,                    -- сквозной идентификатор HTTP-запроса

    -- Что
    action          text         NOT NULL,   -- insert | update | delete | login | export | ...
    entity_schema   text,
    entity_table    text,
    entity_id       text,
    entity_label    text,                    -- человекочитаемое имя объекта («Санжар М.»)

    -- Как именно изменилось
    old_data        jsonb,
    new_data        jsonb,
    changed_fields  jsonb,

    success         boolean      NOT NULL DEFAULT true,
    details         text,

    CONSTRAINT activity_log_pkey PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE  audit.activity_log IS 'Журнал изменений данных. Только вставка: UPDATE и DELETE заблокированы триггером и правами.';
COMMENT ON COLUMN audit.activity_log.changed_fields IS 'Только изменившиеся поля — быстрее читать, чем сравнивать old_data и new_data';

-- Секция «на всё остальное»: скрипт не упадёт, даже если помесячные секции не заведены.
CREATE TABLE IF NOT EXISTS audit.activity_log_default PARTITION OF audit.activity_log DEFAULT;

-- Создание помесячных секций (вызывать из планировщика раз в месяц).
CREATE OR REPLACE FUNCTION audit.create_monthly_partitions(p_from date DEFAULT date_trunc('month', current_date)::date,
                                                           p_months integer DEFAULT 12)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_start  date;
    v_end    date;
    v_name   text;
    v_count  integer := 0;
    i        integer;
BEGIN
    FOR i IN 0 .. GREATEST(p_months - 1, 0) LOOP
        v_start := (date_trunc('month', p_from) + make_interval(months => i))::date;
        v_end   := (v_start + interval '1 month')::date;
        v_name  := 'activity_log_' || to_char(v_start, 'YYYY_MM');

        IF NOT EXISTS (SELECT 1 FROM pg_class c
                       JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'audit' AND c.relname = v_name) THEN
            EXECUTE format(
                'CREATE TABLE audit.%I PARTITION OF audit.activity_log FOR VALUES FROM (%L) TO (%L)',
                v_name, v_start, v_end);
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION audit.create_monthly_partitions(date, integer)
    IS 'Заводит помесячные секции журнала. Ставится в cron: SELECT audit.create_monthly_partitions();';

--  Секции создаются СРАЗУ, до первых записей. Если строки успеют попасть в секцию
--  по умолчанию, PostgreSQL откажется создавать помесячную секцию на тот же период:
--  ему пришлось бы перепроверять и переносить уже записанные строки.
SELECT audit.create_monthly_partitions(
         (date_trunc('month', current_date) - interval '1 month')::date, 15) AS created_partitions;

CREATE TABLE IF NOT EXISTS audit.security_events (
    id             bigint       GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    occurred_at    timestamptz  NOT NULL DEFAULT clock_timestamp(),
    kind           core.security_event_kind NOT NULL,
    severity       text         NOT NULL DEFAULT 'info'
                                CHECK (severity IN ('info', 'notice', 'warning', 'critical')),
    actor_user_id  uuid,
    actor_username text,
    target_user_id uuid,
    ip             inet,
    user_agent     text,
    session_id     uuid,
    succeeded      boolean      NOT NULL DEFAULT true,
    reason         text,
    context        jsonb        NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE audit.security_events IS 'События безопасности: входы, смены паролей, блокировки, отказы в доступе';

CREATE TABLE IF NOT EXISTS audit.data_access_log (
    id            bigint      GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    occurred_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_user_id uuid,
    actor_role    text,
    subject_type  text        NOT NULL CHECK (subject_type IN ('child', 'guardian', 'document', 'progress_log', 'chat_thread', 'user')),
    subject_id    uuid        NOT NULL,
    subject_label text,
    access_kind   text        NOT NULL CHECK (access_kind IN ('view', 'list', 'download', 'print', 'export', 'search')),
    legal_basis   text,       -- согласие / договор / законная обязанность
    ip            inet,
    request_id    text
);

COMMENT ON TABLE audit.data_access_log
    IS 'Кто и когда открывал персональные и медицинские данные. Обязателен для данных о здоровье детей.';

-- ---- Защита журналов от изменения --------------------------------------------------
CREATE OR REPLACE FUNCTION audit.tg_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Журнал %.% доступен только для добавления записей (append-only). Операция % запрещена.',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS trg_activity_log_append_only    ON audit.activity_log;
DROP TRIGGER IF EXISTS trg_security_events_append_only ON audit.security_events;
DROP TRIGGER IF EXISTS trg_data_access_append_only     ON audit.data_access_log;

CREATE TRIGGER trg_activity_log_append_only
    BEFORE UPDATE OR DELETE ON audit.activity_log
    FOR EACH ROW EXECUTE FUNCTION audit.tg_append_only();

CREATE TRIGGER trg_security_events_append_only
    BEFORE UPDATE OR DELETE ON audit.security_events
    FOR EACH ROW EXECUTE FUNCTION audit.tg_append_only();

CREATE TRIGGER trg_data_access_append_only
    BEFORE UPDATE OR DELETE ON audit.data_access_log
    FOR EACH ROW EXECUTE FUNCTION audit.tg_append_only();

CREATE INDEX IF NOT EXISTS ix_activity_log_actor    ON audit.activity_log (actor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_activity_log_entity   ON audit.activity_log (entity_table, entity_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_activity_log_time     ON audit.activity_log (occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_security_events_kind  ON audit.security_events (kind, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_security_events_actor ON audit.security_events (actor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_security_events_ip    ON audit.security_events (ip, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_data_access_subject   ON audit.data_access_log (subject_type, subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_data_access_actor     ON audit.data_access_log (actor_user_id, occurred_at DESC);

-- =====================================================================================
--  РАЗДЕЛ 05. БЕЗОПАСНОСТЬ И АВТОРИЗАЦИЯ (schema sec)
-- =====================================================================================
--  Здесь живёт всё, что относится к «серверной авторизации» из README:
--    05.1 роли и права приложения
--    05.2 пользователи
--    05.3 история паролей (запрет повторного использования)
--    05.4 токены восстановления пароля (хранится ХЕШ токена, не сам токен)
--    05.5 сессии входа
--    05.6 попытки входа и защита от перебора
--    05.7 двухфакторная аутентификация
--    05.8 политика паролей (настраиваемая, одна строка)
--    05.9 функции хеширования и шифрования
-- =====================================================================================

\echo '>>> [05] Схема безопасности...'

-- ---- 05.8 Политика паролей (создаётся первой: на неё ссылаются проверки) ------------
CREATE TABLE IF NOT EXISTS sec.password_policy (
    id                        smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    min_length                smallint    NOT NULL DEFAULT 12  CHECK (min_length BETWEEN 8 AND 128),
    max_length                smallint    NOT NULL DEFAULT 72  CHECK (max_length BETWEEN 16 AND 1024),
    require_uppercase         boolean     NOT NULL DEFAULT true,
    require_lowercase         boolean     NOT NULL DEFAULT true,
    require_digit             boolean     NOT NULL DEFAULT true,
    require_special           boolean     NOT NULL DEFAULT true,
    forbid_username_in_password boolean   NOT NULL DEFAULT true,
    history_depth             smallint    NOT NULL DEFAULT 5   CHECK (history_depth BETWEEN 0 AND 24),
    max_age_days              smallint    NOT NULL DEFAULT 180 CHECK (max_age_days >= 0),
    min_age_hours             smallint    NOT NULL DEFAULT 1,  -- защита от «прокрутки» истории
    max_failed_attempts       smallint    NOT NULL DEFAULT 5   CHECK (max_failed_attempts BETWEEN 3 AND 20),
    lockout_minutes           smallint    NOT NULL DEFAULT 15  CHECK (lockout_minutes >= 1),
    session_ttl_minutes       integer     NOT NULL DEFAULT 480 CHECK (session_ttl_minutes >= 5),
    idle_timeout_minutes      integer     NOT NULL DEFAULT 30  CHECK (idle_timeout_minutes >= 5),
    reset_token_ttl_minutes   integer     NOT NULL DEFAULT 30  CHECK (reset_token_ttl_minutes BETWEEN 5 AND 1440),
    bcrypt_cost               smallint    NOT NULL DEFAULT 12  CHECK (bcrypt_cost BETWEEN 10 AND 16),
    require_mfa_for_admin     boolean     NOT NULL DEFAULT true,
    updated_at                timestamptz NOT NULL DEFAULT now(),
    updated_by                uuid
);

COMMENT ON TABLE  sec.password_policy IS 'Единственная строка настроек парольной политики. Меняется только администратором.';
COMMENT ON COLUMN sec.password_policy.max_length IS '72 — жёсткий предел bcrypt в БАЙТАХ. Кириллица занимает 2 байта на символ, поэтому проверка идёт по octet_length.';
COMMENT ON COLUMN sec.password_policy.min_age_hours IS 'Минимальный срок жизни пароля: не даёт быстро сменить пароль N раз, чтобы вернуть старый.';

-- ---- 05.1 Роли и права приложения --------------------------------------------------
CREATE TABLE IF NOT EXISTS sec.roles (
    code           text        PRIMARY KEY CHECK (code ~ '^[a-z_]{3,32}$'),
    name_ru        text        NOT NULL,
    name_kk        text        NOT NULL,
    name_en        text        NOT NULL,
    description    text,
    rank           smallint    NOT NULL DEFAULT 100,   -- чем меньше, тем выше полномочия
    is_staff       boolean     NOT NULL DEFAULT true,  -- false = внешний пользователь (родитель)
    can_see_all_centers boolean NOT NULL DEFAULT false,
    is_system      boolean     NOT NULL DEFAULT false, -- системную роль нельзя удалить
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE sec.roles IS 'Роли портала. Заменяет строковое поле role в прототипе staff-portal.html.';

CREATE TABLE IF NOT EXISTS sec.permissions (
    code        text        PRIMARY KEY CHECK (code ~ '^[a-z_]+\.[a-z_]+$'),
    name_ru     text        NOT NULL,
    description text,
    category    text        NOT NULL DEFAULT 'general',
    is_sensitive boolean    NOT NULL DEFAULT false   -- требует явного журналирования
);

COMMENT ON TABLE sec.permissions IS 'Атомарные права: children.view, children.edit, audit.view, users.manage и т.д.';

CREATE TABLE IF NOT EXISTS sec.role_permissions (
    role_code       text        NOT NULL REFERENCES sec.roles(code)       ON DELETE CASCADE,
    permission_code text        NOT NULL REFERENCES sec.permissions(code) ON DELETE CASCADE,
    granted_at      timestamptz NOT NULL DEFAULT now(),
    granted_by      uuid,
    PRIMARY KEY (role_code, permission_code)
);

-- ---- 05.2 Пользователи --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec.users (
    id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Идентификация
    username              citext      NOT NULL UNIQUE CHECK (length(username) BETWEEN 3 AND 64
                                                             AND username ~ '^[A-Za-z0-9._\-]+$'),
    email                 core.email  UNIQUE,
    phone                 core.phone,
    email_verified_at     timestamptz,
    phone_verified_at     timestamptz,

    -- Персональные данные
    last_name             text        NOT NULL CHECK (length(btrim(last_name))  > 0),
    first_name            text        NOT NULL CHECK (length(btrim(first_name)) > 0),
    middle_name           text,
    full_name             text        GENERATED ALWAYS AS (
                                          btrim(coalesce(last_name, '') || ' ' ||
                                                coalesce(first_name, '') || ' ' ||
                                                coalesce(middle_name, ''))
                                      ) STORED,
    display_name          text,       -- как показывать в интерфейсе: «Куратор Ержан»
    job_title             text,       -- «Логопед», «Нейропсихолог», «Куратор Junior»
    avatar_url            text,
    locale                core.locale_code NOT NULL DEFAULT 'ru',
    timezone              text        NOT NULL DEFAULT 'Asia/Aqtobe',

    -- Доступ
    role_code             text        NOT NULL REFERENCES sec.roles(code) ON UPDATE CASCADE,
    primary_center_id     uuid,       -- FK добавляется после создания eventum.centers
    has_all_centers_access boolean    NOT NULL DEFAULT false,   -- вместо строки «Все центры»
    is_active             boolean     NOT NULL DEFAULT true,
    deactivated_at        timestamptz,
    deactivation_reason   text,

    -- Пароль (см. раздел 05.9 — задаётся только через sec.set_password)
    password_hash         text,       -- NULL = пароль не задан, вход невозможен
    password_algo         core.password_algo NOT NULL DEFAULT 'bcrypt',
    password_changed_at   timestamptz,
    password_expires_at   timestamptz,
    must_change_password  boolean     NOT NULL DEFAULT true,

    -- Защита от перебора
    failed_login_attempts smallint    NOT NULL DEFAULT 0 CHECK (failed_login_attempts >= 0),
    locked_until          timestamptz,
    last_login_at         timestamptz,
    last_login_ip         inet,
    last_seen_at          timestamptz,

    -- Двухфакторная аутентификация
    mfa_enabled           boolean     NOT NULL DEFAULT false,
    mfa_secret_encrypted  bytea,      -- зашифровано pgp_sym_encrypt, ключ вне базы
    mfa_confirmed_at      timestamptz,

    -- Согласия и служебное
    accepted_terms_at     timestamptz,
    accepted_privacy_at   timestamptz,
    notes                 text,

    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid,
    deleted_at            timestamptz,   -- мягкое удаление: журналы должны остаться связными

    CONSTRAINT users_password_hash_format CHECK (
        password_hash IS NULL
        OR (password_algo = 'bcrypt'   AND password_hash ~ '^\$2[aby]?\$[0-9]{2}\$.{53}$')
        OR (password_algo = 'argon2id' AND password_hash ~ '^\$argon2id\$')
        OR (password_algo = 'scrypt'   AND password_hash ~ '^\$scrypt\$')
    ),
    CONSTRAINT users_deactivated_consistency CHECK (
        (is_active AND deactivated_at IS NULL) OR (NOT is_active)
    ),
    CONSTRAINT users_mfa_consistency CHECK (
        NOT mfa_enabled OR mfa_secret_encrypted IS NOT NULL
    )
);

COMMENT ON TABLE  sec.users IS 'Пользователи портала: администраторы, кураторы, специалисты, родители';
COMMENT ON COLUMN sec.users.password_hash IS 'Только хеш (bcrypt по умолчанию). Открытый пароль в базу не попадает никогда.';
COMMENT ON COLUMN sec.users.has_all_centers_access IS 'Заменяет магическую строку «Все центры» из прототипа';
COMMENT ON COLUMN sec.users.deleted_at IS 'Мягкое удаление. Полное стирание — через sec.erase_user() с сохранением записи в журнале.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_username_alive ON sec.users (username) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_users_role        ON sec.users (role_code) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_users_center      ON sec.users (primary_center_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_users_active      ON sec.users (is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_users_fullname_trgm ON sec.users USING gin (core.normalize_search(full_name) gin_trgm_ops);

-- ---- 05.3 История паролей -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec.password_history (
    id             bigint      GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    user_id        uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    password_hash  text        NOT NULL,
    password_algo  core.password_algo NOT NULL DEFAULT 'bcrypt',
    changed_at     timestamptz NOT NULL DEFAULT now(),
    changed_by     uuid,
    change_reason  text        NOT NULL DEFAULT 'user_change'
                               CHECK (change_reason IN ('initial', 'user_change', 'admin_reset',
                                                        'forced_expiry', 'self_service_reset', 'breach_response')),
    changed_ip     inet
);

COMMENT ON TABLE sec.password_history
    IS 'Хеши прежних паролей. Нужны только для запрета повторного использования (history_depth).';

CREATE INDEX IF NOT EXISTS ix_password_history_user ON sec.password_history (user_id, changed_at DESC);

-- ---- 05.4 Токены восстановления пароля ---------------------------------------------
CREATE TABLE IF NOT EXISTS sec.password_reset_tokens (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    token_hash    bytea       NOT NULL UNIQUE,   -- sha256 от токена; сам токен есть только у пользователя
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    consumed_at   timestamptz,                   -- одноразовость
    invalidated_at timestamptz,
    requested_ip  inet,
    requested_user_agent text,
    used_ip       inet,
    CONSTRAINT reset_token_ttl_valid CHECK (expires_at > created_at)
);

COMMENT ON TABLE sec.password_reset_tokens
    IS 'Одноразовые токены сброса пароля. В базе только SHA-256 от токена: утечка таблицы не даёт войти.';

CREATE INDEX IF NOT EXISTS ix_reset_tokens_user  ON sec.password_reset_tokens (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_reset_tokens_alive ON sec.password_reset_tokens (expires_at)
    WHERE consumed_at IS NULL AND invalidated_at IS NULL;

-- ---- 05.5 Сессии входа --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec.auth_sessions (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    token_hash         bytea       NOT NULL UNIQUE,   -- sha256 от токена сессии
    refresh_token_hash bytea       UNIQUE,
    issued_at          timestamptz NOT NULL DEFAULT now(),
    expires_at         timestamptz NOT NULL,
    last_seen_at       timestamptz NOT NULL DEFAULT now(),
    revoked_at         timestamptz,
    revoked_reason     text        CHECK (revoked_reason IS NULL OR revoked_reason IN
                                          ('logout', 'password_changed', 'admin_revoked', 'expired',
                                           'idle_timeout', 'suspicious_activity', 'user_deactivated')),
    ip                 inet,
    user_agent         text,
    device_label       text,
    mfa_passed         boolean     NOT NULL DEFAULT false,
    CONSTRAINT auth_session_ttl_valid CHECK (expires_at > issued_at)
);

COMMENT ON TABLE sec.auth_sessions IS 'Активные сессии. Хранится хеш токена — в базе нет ничего, чем можно войти.';

CREATE INDEX IF NOT EXISTS ix_auth_sessions_user  ON sec.auth_sessions (user_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS ix_auth_sessions_alive ON sec.auth_sessions (expires_at)
    WHERE revoked_at IS NULL;

-- ---- 05.6 Попытки входа -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec.login_attempts (
    id                 bigint      GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    attempted_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
    username_attempted citext,
    user_id            uuid,          -- без FK: логин мог быть несуществующим
    succeeded          boolean       NOT NULL,
    failure_reason     text          CHECK (failure_reason IS NULL OR failure_reason IN
                                            ('user_not_found', 'bad_password', 'account_locked',
                                             'account_inactive', 'password_not_set', 'mfa_required',
                                             'mfa_failed', 'password_expired')),
    ip                 inet,
    user_agent         text
);

COMMENT ON TABLE sec.login_attempts IS 'Все попытки входа: основа для блокировки перебора и разбора инцидентов';

CREATE INDEX IF NOT EXISTS ix_login_attempts_user ON sec.login_attempts (username_attempted, attempted_at DESC);
CREATE INDEX IF NOT EXISTS ix_login_attempts_ip   ON sec.login_attempts (ip, attempted_at DESC);

-- ---- 05.7 Резервные коды 2FA --------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec.mfa_recovery_codes (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    code_hash  text        NOT NULL,     -- bcrypt-хеш кода
    created_at timestamptz NOT NULL DEFAULT now(),
    used_at    timestamptz,
    used_ip    inet
);

COMMENT ON TABLE sec.mfa_recovery_codes IS 'Одноразовые резервные коды 2FA. Хранятся только хеши.';

CREATE INDEX IF NOT EXISTS ix_mfa_codes_user ON sec.mfa_recovery_codes (user_id) WHERE used_at IS NULL;

-- ---- Персональные права поверх роли (точечные исключения) --------------------------
CREATE TABLE IF NOT EXISTS sec.user_permission_overrides (
    user_id         uuid    NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    permission_code text    NOT NULL REFERENCES sec.permissions(code) ON DELETE CASCADE,
    is_granted      boolean NOT NULL,       -- true = выдать сверх роли, false = отобрать
    reason          text    NOT NULL,
    granted_by      uuid    REFERENCES sec.users(id),
    granted_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz,
    PRIMARY KEY (user_id, permission_code)
);

COMMENT ON TABLE sec.user_permission_overrides
    IS 'Точечные отклонения от роли — всегда с причиной и, желательно, со сроком действия';

-- ---- Настройки интерфейса пользователя ---------------------------------------------------
--  Прототип держит их в localStorage: urpaq-staff-lang, urpaq-staff-sidebar-width,
--  urpaq-staff-sidebar-collapsed. Из-за этого сотрудник, севший за другой компьютер в
--  центре, получает чужие или сброшенные настройки. Здесь они привязаны к человеку.
CREATE TABLE IF NOT EXISTS sec.user_preferences (
    user_id          uuid        PRIMARY KEY REFERENCES sec.users(id) ON DELETE CASCADE,
    locale           core.locale_code NOT NULL DEFAULT 'ru',
    theme            text        NOT NULL DEFAULT 'system' CHECK (theme IN ('system', 'light', 'dark')),
    sidebar_width    smallint    NOT NULL DEFAULT 255 CHECK (sidebar_width BETWEEN 220 AND 360),
    sidebar_collapsed boolean    NOT NULL DEFAULT false,
    reduced_motion   boolean     NOT NULL DEFAULT false,
    notifications_email boolean  NOT NULL DEFAULT true,
    notifications_push  boolean  NOT NULL DEFAULT false,
    default_center_id uuid,      -- внешний ключ добавляется после создания eventum.centers
    extra            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE sec.user_preferences
    IS 'Язык, тема и ширина боковой панели. Раньше жили в localStorage браузера — теперь ходят за пользователем.';

-- =====================================================================================
--  РАЗДЕЛ 05.9. ХЕШИРОВАНИЕ ПАРОЛЕЙ И ШИФРОВАНИЕ
-- =====================================================================================
--  КАК ЭТО РАБОТАЕТ
--    * Открытый пароль в таблицы не пишется НИКОГДА и НИГДЕ.
--    * Хеш — bcrypt (pgcrypto: crypt + gen_salt('bf', cost)). Соль своя у каждого пароля
--      и хранится внутри самого хеша. Cost настраивается в sec.password_policy.
--    * Проверка пароля — сравнение crypt(введённый, сохранённый_хеш) = сохранённый_хеш.
--      Это сравнение постоянного времени внутри pgcrypto.
--
--  ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ ПРО ЛОГИ POSTGRESQL
--    При хешировании на стороне базы открытый пароль оказывается в тексте SQL-запроса и
--    может попасть в log_statement / pg_stat_statements / pgAudit. Поэтому:
--      1) функции хеширования объявлены SECURITY DEFINER и закрыты от PUBLIC;
--      2) на проде обязательно log_statement = 'ddl' (не 'all') и отключённый
--         pg_stat_statements.track = all для этих функций;
--      3) РЕКОМЕНДУЕМЫЙ вариант для продакшена — хешировать Argon2id в приложении
--         (Node: argon2 / bcrypt), а в базу передавать уже готовый хеш через
--         sec.set_password_hash(). Схема поддерживает оба пути: password_algo.
--
--  ПРО ДЛИНУ ПАРОЛЯ
--    bcrypt молча обрезает вход на 72 БАЙТАХ. Кириллический символ в UTF-8 — 2 байта,
--    значит «Пароль123!» это 16 байт, а 40 русских букв — уже 80 и хвост потеряется.
--    Поэтому проверка идёт по octet_length(), а не по length().
-- =====================================================================================

\echo '>>> [05.9] Функции паролей и шифрования...'

-- ---- Текущий пользователь запроса ---------------------------------------------------
--  Приложение перед каждым запросом вызывает sec.begin_request(<токен сессии>).
--  Все RLS-политики опираются на эти две функции.

CREATE OR REPLACE FUNCTION sec.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_user_id', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION sec.current_role_code()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_role_code', true), '');
$$;

CREATE OR REPLACE FUNCTION sec.current_session_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_session_id', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION sec.current_ip()
RETURNS inet
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.current_ip', true), '')::inet;
$$;

CREATE OR REPLACE FUNCTION sec.current_request_id()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT nullif(current_setting('app.request_id', true), '');
$$;

CREATE OR REPLACE FUNCTION sec.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(sec.current_role_code() IN ('admin', 'director'), false);
$$;

COMMENT ON FUNCTION sec.current_user_id() IS 'Идентификатор пользователя текущего запроса; берётся из GUC app.current_user_id';

-- ---- Хеширование ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sec.hash_password(p_plain text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, pg_catalog, public
AS $$
DECLARE
    v_cost smallint;
BEGIN
    IF p_plain IS NULL OR length(p_plain) = 0 THEN
        RAISE EXCEPTION 'Пароль не может быть пустым' USING ERRCODE = '22023';
    END IF;

    SELECT bcrypt_cost INTO v_cost FROM sec.password_policy WHERE id = 1;
    v_cost := coalesce(v_cost, 12);

    RETURN crypt(p_plain, gen_salt('bf', v_cost));
END;
$$;

COMMENT ON FUNCTION sec.hash_password(text)
    IS 'bcrypt-хеш пароля. SECURITY DEFINER + закрыта от PUBLIC, чтобы открытый пароль не гулял по правам.';

CREATE OR REPLACE FUNCTION sec.verify_password(p_plain text, p_hash text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, pg_catalog, public
AS $$
BEGIN
    IF p_plain IS NULL OR p_hash IS NULL THEN
        RETURN false;
    END IF;
    -- Сравнение выполняется внутри crypt(): результат зависит от соли в самом хеше.
    RETURN p_hash = crypt(p_plain, p_hash);
END;
$$;

-- ---- Проверка стойкости пароля -------------------------------------------------------
CREATE OR REPLACE FUNCTION sec.validate_password_strength(p_plain text, p_username text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    p sec.password_policy%ROWTYPE;
    v_lower text := lower(coalesce(p_plain, ''));
BEGIN
    SELECT * INTO p FROM sec.password_policy WHERE id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Не настроена парольная политика (sec.password_policy)' USING ERRCODE = '55000';
    END IF;

    IF p_plain IS NULL OR length(p_plain) < p.min_length THEN
        RAISE EXCEPTION 'Пароль слишком короткий: минимум % символов', p.min_length USING ERRCODE = '22023';
    END IF;

    -- Проверяем БАЙТЫ: предел bcrypt — 72 байта, кириллица занимает по 2.
    IF octet_length(p_plain) > p.max_length THEN
        RAISE EXCEPTION 'Пароль слишком длинный: максимум % байт (кириллическая буква = 2 байта)', p.max_length
            USING ERRCODE = '22023';
    END IF;

    IF p.require_uppercase AND p_plain !~ '[A-ZА-ЯЁӘҒҚҢӨҰҮҺІ]' THEN
        RAISE EXCEPTION 'Пароль должен содержать хотя бы одну заглавную букву' USING ERRCODE = '22023';
    END IF;

    IF p.require_lowercase AND p_plain !~ '[a-zа-яёәғқңөұүһі]' THEN
        RAISE EXCEPTION 'Пароль должен содержать хотя бы одну строчную букву' USING ERRCODE = '22023';
    END IF;

    IF p.require_digit AND p_plain !~ '[0-9]' THEN
        RAISE EXCEPTION 'Пароль должен содержать хотя бы одну цифру' USING ERRCODE = '22023';
    END IF;

    IF p.require_special AND p_plain !~ '[^A-Za-zА-Яа-яЁё0-9]' THEN
        RAISE EXCEPTION 'Пароль должен содержать хотя бы один специальный символ' USING ERRCODE = '22023';
    END IF;

    IF p.forbid_username_in_password AND p_username IS NOT NULL
       AND length(p_username) >= 3 AND position(lower(p_username) in v_lower) > 0 THEN
        RAISE EXCEPTION 'Пароль не должен содержать логин' USING ERRCODE = '22023';
    END IF;

    -- Простейший стоп-лист. На проде подключается полноценный словарь утечек
    -- (HaveIBeenPwned k-anonymity) на стороне приложения — в базе держать 900 млн хешей незачем.
    IF v_lower = ANY (ARRAY['password', 'qwerty123456', '123456789012', 'passw0rd1234',
                            'admin1234567', 'urpaq2026!', 'eventum2026!', 'qwertyuiop12']) THEN
        RAISE EXCEPTION 'Этот пароль есть в списке скомпрометированных. Выберите другой.' USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION sec.validate_password_strength(text, text)
    IS 'Проверка пароля по sec.password_policy. Бросает исключение с понятным текстом для интерфейса.';

-- ---- Установка пароля (администратором или при первичной выдаче) ---------------------
CREATE OR REPLACE FUNCTION sec.set_password(
    p_user_id     uuid,
    p_new_password text,
    p_actor_id    uuid DEFAULT NULL,
    p_reason      text DEFAULT 'admin_reset',
    p_ip          inet DEFAULT NULL,
    p_force_change boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_user      sec.users%ROWTYPE;
    p           sec.password_policy%ROWTYPE;
    v_new_hash  text;
    v_old_hash  text;
    v_reused    boolean := false;
BEGIN
    SELECT * INTO v_user FROM sec.users WHERE id = p_user_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пользователь не найден' USING ERRCODE = 'P0002';
    END IF;

    SELECT * INTO p FROM sec.password_policy WHERE id = 1;

    PERFORM sec.validate_password_strength(p_new_password, v_user.username::text);

    -- Запрет повторного использования последних N паролей.
    IF p.history_depth > 0 THEN
        FOR v_old_hash IN
            SELECT password_hash
            FROM (
                SELECT password_hash, changed_at FROM sec.password_history WHERE user_id = p_user_id
                UNION ALL
                SELECT v_user.password_hash, coalesce(v_user.password_changed_at, '-infinity'::timestamptz)
                WHERE v_user.password_hash IS NOT NULL
            ) h
            ORDER BY changed_at DESC
            LIMIT p.history_depth
        LOOP
            IF v_old_hash = crypt(p_new_password, v_old_hash) THEN
                v_reused := true;
                EXIT;
            END IF;
        END LOOP;

        IF v_reused THEN
            INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, ip, succeeded, reason)
            VALUES ('password_policy_violation', 'notice', coalesce(p_actor_id, p_user_id), p_user_id, p_ip, false,
                    'Попытка повторно использовать один из последних паролей');
            RAISE EXCEPTION 'Нельзя повторно использовать один из последних % паролей', p.history_depth
                USING ERRCODE = '22023';
        END IF;
    END IF;

    v_new_hash := sec.hash_password(p_new_password);

    -- Прежний пароль уходит в историю.
    IF v_user.password_hash IS NOT NULL THEN
        INSERT INTO sec.password_history (user_id, password_hash, password_algo, changed_by, change_reason, changed_ip)
        VALUES (p_user_id, v_user.password_hash, v_user.password_algo, p_actor_id, p_reason, p_ip);
    END IF;

    UPDATE sec.users
       SET password_hash        = v_new_hash,
           password_algo        = 'bcrypt',
           password_changed_at  = now(),
           password_expires_at  = CASE WHEN p.max_age_days > 0
                                       THEN now() + make_interval(days => p.max_age_days) END,
           must_change_password = p_force_change,
           failed_login_attempts = 0,
           locked_until         = NULL,
           updated_at           = now(),
           updated_by           = p_actor_id
     WHERE id = p_user_id;

    -- Смена пароля обнуляет все активные сессии: украденный токен перестаёт работать.
    UPDATE sec.auth_sessions
       SET revoked_at = now(), revoked_reason = 'password_changed'
     WHERE user_id = p_user_id AND revoked_at IS NULL;

    -- Неиспользованные ссылки восстановления тоже гасим.
    UPDATE sec.password_reset_tokens
       SET invalidated_at = now()
     WHERE user_id = p_user_id AND consumed_at IS NULL AND invalidated_at IS NULL;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, actor_username, target_user_id, ip, succeeded, reason, context)
    VALUES ('password_changed', 'notice', p_actor_id, NULL, p_user_id, p_ip, true, p_reason,
            jsonb_build_object('force_change', p_force_change));
END;
$$;

COMMENT ON FUNCTION sec.set_password(uuid, text, uuid, text, inet, boolean)
    IS 'Единственный разрешённый способ задать пароль: проверка политики, история, отзыв сессий, запись в журнал';

-- ---- Приём готового хеша из приложения (Argon2id) ------------------------------------
CREATE OR REPLACE FUNCTION sec.set_password_hash(
    p_user_id  uuid,
    p_hash     text,
    p_algo     core.password_algo,
    p_actor_id uuid DEFAULT NULL,
    p_reason   text DEFAULT 'user_change'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_user sec.users%ROWTYPE;
    p      sec.password_policy%ROWTYPE;
BEGIN
    SELECT * INTO v_user FROM sec.users WHERE id = p_user_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пользователь не найден' USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO p FROM sec.password_policy WHERE id = 1;

    IF v_user.password_hash IS NOT NULL THEN
        INSERT INTO sec.password_history (user_id, password_hash, password_algo, changed_by, change_reason)
        VALUES (p_user_id, v_user.password_hash, v_user.password_algo, p_actor_id, p_reason);
    END IF;

    UPDATE sec.users
       SET password_hash        = p_hash,
           password_algo        = p_algo,
           password_changed_at  = now(),
           password_expires_at  = CASE WHEN p.max_age_days > 0 THEN now() + make_interval(days => p.max_age_days) END,
           must_change_password = false,
           failed_login_attempts = 0,
           locked_until         = NULL,
           updated_at           = now(),
           updated_by           = p_actor_id
     WHERE id = p_user_id;

    UPDATE sec.auth_sessions SET revoked_at = now(), revoked_reason = 'password_changed'
     WHERE user_id = p_user_id AND revoked_at IS NULL;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason)
    VALUES ('password_changed', 'notice', p_actor_id, p_user_id, true, p_reason || ' (hash from application)');
END;
$$;

COMMENT ON FUNCTION sec.set_password_hash(uuid, text, core.password_algo, uuid, text)
    IS 'Для варианта, когда Argon2id считается в приложении: база получает только готовый хеш';

-- ---- Смена собственного пароля --------------------------------------------------------
CREATE OR REPLACE FUNCTION sec.change_own_password(
    p_user_id      uuid,
    p_old_password text,
    p_new_password text,
    p_ip           inet DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_user sec.users%ROWTYPE;
    p      sec.password_policy%ROWTYPE;
BEGIN
    SELECT * INTO v_user FROM sec.users WHERE id = p_user_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пользователь не найден' USING ERRCODE = 'P0002';
    END IF;

    IF NOT sec.verify_password(p_old_password, v_user.password_hash) THEN
        INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, ip, succeeded, reason)
        VALUES ('password_changed', 'warning', p_user_id, p_user_id, p_ip, false, 'Неверный текущий пароль');
        RAISE EXCEPTION 'Текущий пароль указан неверно' USING ERRCODE = '28P01';
    END IF;

    IF p_old_password = p_new_password THEN
        RAISE EXCEPTION 'Новый пароль должен отличаться от текущего' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO p FROM sec.password_policy WHERE id = 1;
    IF p.min_age_hours > 0 AND v_user.password_changed_at IS NOT NULL
       AND v_user.password_changed_at > now() - make_interval(hours => p.min_age_hours)
       AND NOT v_user.must_change_password THEN
        RAISE EXCEPTION 'Пароль можно менять не чаще, чем раз в % ч.', p.min_age_hours USING ERRCODE = '22023';
    END IF;

    PERFORM sec.set_password(p_user_id, p_new_password, p_user_id, 'user_change', p_ip, false);
END;
$$;

-- ---- Восстановление пароля по одноразовой ссылке --------------------------------------
CREATE OR REPLACE FUNCTION sec.request_password_reset(
    p_login      text,
    p_ip         inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_user  sec.users%ROWTYPE;
    p       sec.password_policy%ROWTYPE;
    v_token text;
BEGIN
    SELECT * INTO p FROM sec.password_policy WHERE id = 1;

    -- Сравниваем через citext, а не приводим ввод к домену core.email: пользователь
    -- вводит либо логин, либо почту, и «admin» не должен падать на проверке формата.
    SELECT * INTO v_user
      FROM sec.users
     WHERE deleted_at IS NULL
       AND is_active
       AND (username = p_login::citext OR email::citext = p_login::citext);

    -- Пользователь не найден — возвращаем NULL. Приложение в ЛЮБОМ случае показывает
    -- одинаковое сообщение «если такой аккаунт есть, мы отправили письмо»: иначе форма
    -- превращается в инструмент перебора логинов.
    IF NOT FOUND THEN
        INSERT INTO audit.security_events (kind, severity, ip, user_agent, succeeded, reason, context)
        VALUES ('password_reset_requested', 'notice', p_ip, p_user_agent, false,
                'Запрос для несуществующего аккаунта', jsonb_build_object('login', left(p_login, 64)));
        RETURN NULL;
    END IF;

    -- Прежние неиспользованные ссылки гасим: активна только последняя.
    UPDATE sec.password_reset_tokens
       SET invalidated_at = now()
     WHERE user_id = v_user.id AND consumed_at IS NULL AND invalidated_at IS NULL;

    v_token := encode(gen_random_bytes(32), 'hex');   -- 256 бит энтропии

    INSERT INTO sec.password_reset_tokens (user_id, token_hash, expires_at, requested_ip, requested_user_agent)
    VALUES (v_user.id,
            digest(v_token, 'sha256'),
            now() + make_interval(mins => p.reset_token_ttl_minutes),
            p_ip, p_user_agent);

    INSERT INTO audit.security_events (kind, severity, target_user_id, ip, user_agent, succeeded, reason)
    VALUES ('password_reset_requested', 'notice', v_user.id, p_ip, p_user_agent, true, 'Выдана одноразовая ссылка');

    -- Открытый токен возвращается ровно один раз и только для отправки письма.
    RETURN v_token;
END;
$$;

CREATE OR REPLACE FUNCTION sec.reset_password_with_token(
    p_token        text,
    p_new_password text,
    p_ip           inet DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_row sec.password_reset_tokens%ROWTYPE;
BEGIN
    SELECT * INTO v_row
      FROM sec.password_reset_tokens
     WHERE token_hash = digest(p_token, 'sha256')
       AND consumed_at IS NULL
       AND invalidated_at IS NULL
       AND expires_at > now()
     FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO audit.security_events (kind, severity, ip, succeeded, reason)
        VALUES ('password_reset_completed', 'warning', p_ip, false, 'Недействительная, использованная или истёкшая ссылка');
        RETURN false;
    END IF;

    PERFORM sec.set_password(v_row.user_id, p_new_password, v_row.user_id, 'self_service_reset', p_ip, false);

    UPDATE sec.password_reset_tokens
       SET consumed_at = now(), used_ip = p_ip
     WHERE id = v_row.id;

    INSERT INTO audit.security_events (kind, severity, target_user_id, ip, succeeded, reason)
    VALUES ('password_reset_completed', 'notice', v_row.user_id, p_ip, true, 'Пароль восстановлен по ссылке');

    RETURN true;
END;
$$;

-- ---- Шифрование отдельных полей -------------------------------------------------------
--  Ключ НИКОГДА не хранится в базе. Приложение подаёт его в сессию:
--      SET LOCAL app.encryption_key = '<ключ из Vault/KMS>';
--  Так ключ живёт только внутри транзакции и не попадает ни в дамп, ни в реплику.

CREATE OR REPLACE FUNCTION sec.encrypt_field(p_plain text)
RETURNS bytea
LANGUAGE plpgsql
AS $$
DECLARE
    v_key text := nullif(current_setting('app.encryption_key', true), '');
BEGIN
    IF p_plain IS NULL THEN RETURN NULL; END IF;
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'Ключ шифрования не задан. Выполните: SET LOCAL app.encryption_key = ...'
            USING ERRCODE = '55000';
    END IF;
    RETURN pgp_sym_encrypt(p_plain, v_key, 'cipher-algo=aes256, compress-algo=1');
END;
$$;

CREATE OR REPLACE FUNCTION sec.decrypt_field(p_cipher bytea)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_key text := nullif(current_setting('app.encryption_key', true), '');
BEGIN
    IF p_cipher IS NULL THEN RETURN NULL; END IF;
    IF v_key IS NULL THEN
        RAISE EXCEPTION 'Ключ шифрования не задан' USING ERRCODE = '55000';
    END IF;
    RETURN pgp_sym_decrypt(p_cipher, v_key);
END;
$$;

COMMENT ON FUNCTION sec.encrypt_field(text)
    IS 'AES-256 для особо чувствительных полей (секрет 2FA, реквизиты). Ключ подаётся через SET LOCAL, в базе не хранится.';

-- =====================================================================================
--  РАЗДЕЛ 06. РАБОЧАЯ ЧАСТЬ: ЦЕНТРЫ, ПРОГРАММЫ (schema eventum)
-- =====================================================================================

\echo '>>> [06] Центры и программы...'

CREATE TABLE IF NOT EXISTS eventum.centers (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code          core.slug   NOT NULL UNIQUE,          -- kids | junior | group | eventum
    name          text        NOT NULL,
    legal_name    text,
    city          text        NOT NULL DEFAULT 'Актобе',
    address       text        NOT NULL,
    map_query     text,                                  -- строка для ссылки на карту
    latitude      numeric(9, 6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude     numeric(9, 6) CHECK (longitude BETWEEN -180 AND 180),
    phone         core.phone,
    email         core.email,
    age_from      smallint    CHECK (age_from >= 0),
    age_to        smallint    CHECK (age_to   >= 0),
    capacity      integer     CHECK (capacity > 0),      -- сколько детей центр ведёт одновременно
    working_hours jsonb       NOT NULL DEFAULT '{}'::jsonb,
    is_active     boolean     NOT NULL DEFAULT true,
    is_public     boolean     NOT NULL DEFAULT true,     -- показывать на сайте
    sort_order    smallint    NOT NULL DEFAULT 100,
    opened_on     date,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT centers_age_range CHECK (age_from IS NULL OR age_to IS NULL OR age_to >= age_from)
);

COMMENT ON TABLE eventum.centers IS 'Четыре центра фонда в Актобе: Kids, Junior, Group, Eventum';

-- Многоязычные названия и описания (сайт работает на ru / kk / en).
CREATE TABLE IF NOT EXISTS eventum.center_translations (
    center_id   uuid             NOT NULL REFERENCES eventum.centers(id) ON DELETE CASCADE,
    locale      core.locale_code NOT NULL,
    name        text             NOT NULL,
    address     text,
    format      text,             -- «Ерте қолдау және негізгі дағдылар · 2–8 жас»
    description text,
    PRIMARY KEY (center_id, locale)
);

-- Теперь можно связать пользователей с центрами.
DO $fk$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_primary_center_fk') THEN
        ALTER TABLE sec.users
            ADD CONSTRAINT users_primary_center_fk
            FOREIGN KEY (primary_center_id) REFERENCES eventum.centers(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_prefs_center_fk') THEN
        ALTER TABLE sec.user_preferences
            ADD CONSTRAINT user_prefs_center_fk
            FOREIGN KEY (default_center_id) REFERENCES eventum.centers(id) ON DELETE SET NULL;
    END IF;
END
$fk$;

-- Доступ сотрудника сразу к нескольким центрам (кроме основного).
CREATE TABLE IF NOT EXISTS eventum.user_centers (
    user_id     uuid        NOT NULL REFERENCES sec.users(id)      ON DELETE CASCADE,
    center_id   uuid        NOT NULL REFERENCES eventum.centers(id) ON DELETE CASCADE,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid        REFERENCES sec.users(id),
    PRIMARY KEY (user_id, center_id)
);

COMMENT ON TABLE eventum.user_centers IS 'Дополнительные центры сотрудника. Основной — sec.users.primary_center_id.';

-- Направления помощи: ABA, логопедия, сенсорная интеграция, нейропсихология и т.д.
CREATE TABLE IF NOT EXISTS eventum.programs (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code        core.slug   NOT NULL UNIQUE,
    icon        text,                       -- имя svg-иконки с сайта: brain, spark, message...
    color       text        CHECK (color IS NULL OR color ~ '^#[0-9A-Fa-f]{6}$'),
    default_duration_minutes smallint NOT NULL DEFAULT 45 CHECK (default_duration_minutes BETWEEN 10 AND 480),
    is_active   boolean     NOT NULL DEFAULT true,
    is_public   boolean     NOT NULL DEFAULT true,
    sort_order  smallint    NOT NULL DEFAULT 100,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS eventum.program_translations (
    program_id  uuid             NOT NULL REFERENCES eventum.programs(id) ON DELETE CASCADE,
    locale      core.locale_code NOT NULL,
    title       text             NOT NULL,
    summary     text,
    description text,
    PRIMARY KEY (program_id, locale)
);

COMMENT ON TABLE eventum.programs IS 'Направления работы (секция programs на сайте и профиль занятия в портале)';

-- Какие программы ведёт специалист (квалификация).
CREATE TABLE IF NOT EXISTS eventum.user_programs (
    user_id       uuid        NOT NULL REFERENCES sec.users(id)         ON DELETE CASCADE,
    program_id    uuid        NOT NULL REFERENCES eventum.programs(id)  ON DELETE CASCADE,
    qualification text,
    certified_at  date,
    expires_on    date,
    PRIMARY KEY (user_id, program_id)
);

-- =====================================================================================
--  РАЗДЕЛ 07. ДЕТИ, СЕМЬИ, КОМАНДЫ И СОГЛАСИЯ
-- =====================================================================================
--  Ключевое отличие от прототипа: там куратор и участники команды были просто строками
--  с именами («Куратор Ержан»). Здесь это внешние ключи на sec.users — переименование
--  сотрудника больше не рвёт связи, а права считаются по идентификаторам.
-- =====================================================================================

\echo '>>> [07] Дети, семьи, команды, согласия...'

CREATE TABLE IF NOT EXISTS eventum.children (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    public_code    text        NOT NULL UNIQUE,   -- «EV-0042»: для писем и печати вместо имени

    -- Персональные данные
    last_name      text        NOT NULL CHECK (length(btrim(last_name))  > 0),
    first_name     text        NOT NULL CHECK (length(btrim(first_name)) > 0),
    middle_name    text,
    display_name   text        NOT NULL,          -- «Айсулу К.» — как показывать в интерфейсе
    birth_date     date        CHECK (birth_date IS NULL OR birth_date > date '1990-01-01'),
    birth_year     smallint    CHECK (birth_year IS NULL OR birth_year BETWEEN 1990 AND 2100),
    gender         text        CHECK (gender IS NULL OR gender IN ('male', 'female', 'not_stated')),
    iin_hash       bytea,      -- ИИН НЕ хранится открыто: только SHA-256 для сверки дублей
    citizenship    text,
    home_address   text,
    preferred_locale core.locale_code NOT NULL DEFAULT 'ru',

    -- Маршрут в фонде
    center_id      uuid        REFERENCES eventum.centers(id) ON DELETE SET NULL,
    curator_id     uuid        REFERENCES sec.users(id)       ON DELETE SET NULL,
    status         core.child_status NOT NULL DEFAULT 'active',
    enrolled_on    date        NOT NULL DEFAULT current_date,
    graduated_on   date,
    archived_at    timestamptz,

    -- Клиническая информация (специальная категория данных!)
    primary_diagnosis   text,
    diagnosis_notes     text,
    medical_notes       text,
    allergies           text,
    medications         text,
    special_needs       text,
    communication_notes text,     -- как ребёнок общается: речь, карточки PECS, жесты
    sensory_profile     text,
    behavior_plan       text,

    -- Экстренный контакт
    emergency_contact_name  text,
    emergency_contact_phone core.phone,

    progress_override core.percent,   -- ручная корректировка; обычно прогресс считается по целям
    notes             text,

    -- Хранение и удаление
    retention_until timestamptz,      -- до какой даты фонд вправе хранить данные
    anonymized_at   timestamptz,      -- когда данные были обезличены

    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid        REFERENCES sec.users(id),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid        REFERENCES sec.users(id),
    deleted_at     timestamptz,

    CONSTRAINT children_graduation_after_enrollment CHECK (graduated_on IS NULL OR graduated_on >= enrolled_on)
);

COMMENT ON TABLE  eventum.children IS 'Дети и подростки в программах фонда. Специальная категория персональных данных.';
COMMENT ON COLUMN eventum.children.public_code IS 'Псевдоним для внешних коммуникаций: имя ребёнка не должно попадать в письма и печатные формы';
COMMENT ON COLUMN eventum.children.iin_hash IS 'Хеш ИИН для поиска дублей. Сам ИИН в базе не хранится.';
COMMENT ON COLUMN eventum.children.retention_until IS 'Срок хранения. По его истечении eventum.apply_retention_policy() обезличивает карту.';

CREATE INDEX IF NOT EXISTS ix_children_center   ON eventum.children (center_id)  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_children_curator  ON eventum.children (curator_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_children_status   ON eventum.children (status)     WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_children_search   ON eventum.children
    USING gin (core.normalize_search(display_name || ' ' || last_name || ' ' || first_name) gin_trgm_ops);

-- ---- Законные представители и родственники -------------------------------------------
CREATE TABLE IF NOT EXISTS eventum.guardians (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        REFERENCES sec.users(id) ON DELETE SET NULL,  -- если есть доступ в портал
    last_name     text        NOT NULL,
    first_name    text        NOT NULL,
    middle_name   text,
    full_name     text        GENERATED ALWAYS AS (
                                  btrim(coalesce(last_name, '') || ' ' ||
                                        coalesce(first_name, '') || ' ' ||
                                        coalesce(middle_name, ''))
                              ) STORED,
    phone         core.phone,
    email         core.email,
    whatsapp      core.phone,
    preferred_locale core.locale_code NOT NULL DEFAULT 'ru',
    preferred_channel core.notification_channel NOT NULL DEFAULT 'whatsapp',
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz
);

COMMENT ON TABLE eventum.guardians IS 'Родители и законные представители. Отдельно от sec.users: не у каждого родителя есть вход в портал.';

-- Связь «многие ко многим»: у ребёнка бывает двое родителей, у родителя — несколько детей.
CREATE TABLE IF NOT EXISTS eventum.child_guardians (
    child_id                uuid    NOT NULL REFERENCES eventum.children(id)  ON DELETE CASCADE,
    guardian_id             uuid    NOT NULL REFERENCES eventum.guardians(id) ON DELETE CASCADE,
    relation                text    NOT NULL CHECK (relation IN ('mother', 'father', 'grandmother', 'grandfather',
                                                                 'guardian', 'foster_parent', 'sibling', 'other')),
    is_legal_representative boolean NOT NULL DEFAULT false,
    is_primary_contact      boolean NOT NULL DEFAULT false,
    can_pick_up             boolean NOT NULL DEFAULT true,
    can_view_reports        boolean NOT NULL DEFAULT true,
    can_view_chat           boolean NOT NULL DEFAULT true,
    valid_from              date    NOT NULL DEFAULT current_date,
    valid_until             date,
    created_at              timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (child_id, guardian_id)
);

COMMENT ON TABLE eventum.child_guardians IS 'Связь ребёнок ↔ представитель с объёмом прав. Основа RLS-политики для роли parent.';

CREATE INDEX IF NOT EXISTS ix_child_guardians_guardian ON eventum.child_guardians (guardian_id);

-- ---- Междисциплинарная команда ребёнка -------------------------------------------------
CREATE TABLE IF NOT EXISTS eventum.child_team_members (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id      uuid        NOT NULL REFERENCES eventum.children(id) ON DELETE CASCADE,
    user_id       uuid        NOT NULL REFERENCES sec.users(id)        ON DELETE CASCADE,
    role_in_team  text        NOT NULL DEFAULT 'specialist'
                              CHECK (role_in_team IN ('curator', 'specialist', 'speech_therapist',
                                                      'neuropsychologist', 'aba_therapist', 'occupational_therapist',
                                                      'sensory_specialist', 'physical_education', 'observer')),
    program_id    uuid        REFERENCES eventum.programs(id) ON DELETE SET NULL,
    assigned_at   timestamptz NOT NULL DEFAULT now(),
    assigned_by   uuid        REFERENCES sec.users(id),
    unassigned_at timestamptz,
    unassign_reason text
);

COMMENT ON TABLE eventum.child_team_members
    IS 'Кто работает с ребёнком. Заменяет массив строк participants из прототипа и определяет доступ к карте.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_child_team_active
    ON eventum.child_team_members (child_id, user_id) WHERE unassigned_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_child_team_user ON eventum.child_team_members (user_id) WHERE unassigned_at IS NULL;

-- ---- Согласия семьи ---------------------------------------------------------------------
--  Сайт фонда прямо обещает: «Публикуем события только с соблюдением согласий семей»
--  и «Публикация документов и имён доноров ведётся только на основании выбранного
--  согласия». Эта таблица — техническая опора этого обещания.

CREATE TABLE IF NOT EXISTS eventum.consents (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id       uuid        REFERENCES eventum.children(id)  ON DELETE CASCADE,
    guardian_id    uuid        REFERENCES eventum.guardians(id) ON DELETE SET NULL,
    subject_user_id uuid       REFERENCES sec.users(id)         ON DELETE CASCADE,  -- согласие сотрудника
    purpose        core.consent_purpose NOT NULL,
    scope          text,                       -- уточнение: «фото только со спины», «без имени»
    is_granted     boolean     NOT NULL DEFAULT true,
    granted_at     timestamptz NOT NULL DEFAULT now(),
    valid_until    timestamptz,
    revoked_at     timestamptz,
    revoke_reason  text,
    collection_method text     NOT NULL DEFAULT 'written'
                               CHECK (collection_method IN ('written', 'electronic', 'verbal_recorded')),
    document_id    uuid,                       -- скан подписанного согласия (FK ниже)
    locale         core.locale_code NOT NULL DEFAULT 'ru',
    wording_version text,                      -- версия текста согласия, которую подписали
    recorded_by    uuid        REFERENCES sec.users(id),
    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT consent_has_subject CHECK (
        num_nonnulls(child_id, subject_user_id) >= 1
    ),
    CONSTRAINT consent_revoked_consistency CHECK (
        revoked_at IS NULL OR revoked_at >= granted_at
    )
);

COMMENT ON TABLE eventum.consents
    IS 'Согласия на обработку и публикацию. Проверяются функцией eventum.has_consent() перед любой публикацией.';

CREATE INDEX IF NOT EXISTS ix_consents_child   ON eventum.consents (child_id, purpose);
CREATE INDEX IF NOT EXISTS ix_consents_active  ON eventum.consents (purpose)
    WHERE is_granted AND revoked_at IS NULL;

-- =====================================================================================
--  РАЗДЕЛ 08. ЗАНЯТИЯ, ЦЕЛИ, ЗАДАЧИ, ЗАПИСИ О ПРОГРЕССЕ
-- =====================================================================================
--  Внимание на именование: в прототипе sessions — это ЗАНЯТИЯ (расписание), а не сессии
--  входа. Здесь это разные сущности: eventum.therapy_sessions и sec.auth_sessions.
-- =====================================================================================

\echo '>>> [08] Занятия, цели, записи...'

CREATE TABLE IF NOT EXISTS eventum.therapy_sessions (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    center_id        uuid        NOT NULL REFERENCES eventum.centers(id)  ON DELETE RESTRICT,
    program_id       uuid        REFERENCES eventum.programs(id)          ON DELETE SET NULL,
    specialist_id    uuid        NOT NULL REFERENCES sec.users(id)        ON DELETE RESTRICT,
    primary_child_id uuid        REFERENCES eventum.children(id)          ON DELETE CASCADE,

    scheduled_at     timestamptz NOT NULL,
    duration_minutes smallint    NOT NULL DEFAULT 45 CHECK (duration_minutes BETWEEN 10 AND 480),
    -- Время окончания хранится отдельной колонкой, а не считается на лету: оператор
    -- «timestamptz + interval» помечен как STABLE (результат зависит от часового пояса),
    -- а в индексном выражении допустимы только IMMUTABLE-функции. Значение проставляет
    -- триггер trg_session_ends_at — вручную заполнять не нужно.
    ends_at          timestamptz NOT NULL,
    format           core.session_format NOT NULL DEFAULT 'individual',
    status           core.session_status NOT NULL DEFAULT 'planned',
    room             text,

    actual_start_at  timestamptz,
    actual_end_at    timestamptz,
    summary          text,                    -- краткий итог занятия
    homework         text,                    -- что делать дома
    cancel_reason    text,
    cancelled_by     uuid        REFERENCES sec.users(id),
    cancelled_at     timestamptz,

    is_billable      boolean     NOT NULL DEFAULT true,
    price            core.money_amount,
    currency         core.currency_code NOT NULL DEFAULT 'KZT',

    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid        REFERENCES sec.users(id),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid        REFERENCES sec.users(id),

    CONSTRAINT session_individual_needs_child CHECK (
        format <> 'individual' OR primary_child_id IS NOT NULL
    ),
    CONSTRAINT session_actual_time_valid CHECK (
        actual_end_at IS NULL OR actual_start_at IS NULL OR actual_end_at >= actual_start_at
    ),
    CONSTRAINT session_cancel_consistency CHECK (
        status <> 'cancelled' OR cancel_reason IS NOT NULL
    ),

    -- Один специалист не может вести два занятия одновременно.
    -- Проверяет сама база: ошибка в интерфейсе или гонка запросов расписание не сломает.
    CONSTRAINT session_ends_after_start CHECK (ends_at > scheduled_at),
    CONSTRAINT session_no_specialist_overlap EXCLUDE USING gist (
        specialist_id WITH =,
        tstzrange(scheduled_at, ends_at) WITH &&
    ) WHERE (status IN ('planned', 'confirmed', 'in_progress'))
);

COMMENT ON TABLE  eventum.therapy_sessions IS 'Расписание занятий (view-sessions и todaySchedule в портале)';
COMMENT ON CONSTRAINT session_no_specialist_overlap ON eventum.therapy_sessions
    IS 'Защита от двойного бронирования специалиста на уровне СУБД';

CREATE INDEX IF NOT EXISTS ix_sessions_day        ON eventum.therapy_sessions (scheduled_at);
CREATE INDEX IF NOT EXISTS ix_sessions_child      ON eventum.therapy_sessions (primary_child_id, scheduled_at DESC);
CREATE INDEX IF NOT EXISTS ix_sessions_specialist ON eventum.therapy_sessions (specialist_id, scheduled_at DESC);
CREATE INDEX IF NOT EXISTS ix_sessions_center_day ON eventum.therapy_sessions (center_id, scheduled_at);

-- Групповой формат: несколько детей на одном занятии + отметка посещаемости.
CREATE TABLE IF NOT EXISTS eventum.session_attendees (
    session_id  uuid        NOT NULL REFERENCES eventum.therapy_sessions(id) ON DELETE CASCADE,
    child_id    uuid        NOT NULL REFERENCES eventum.children(id)         ON DELETE CASCADE,
    attendance  core.attendance_status NOT NULL DEFAULT 'unknown',
    arrived_at  timestamptz,
    note        text,
    PRIMARY KEY (session_id, child_id)
);

CREATE INDEX IF NOT EXISTS ix_session_attendees_child ON eventum.session_attendees (child_id);

-- Кто ещё участвовал в занятии (со-терапевт, стажёр, родитель).
CREATE TABLE IF NOT EXISTS eventum.session_staff (
    session_id uuid NOT NULL REFERENCES eventum.therapy_sessions(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES sec.users(id)                ON DELETE CASCADE,
    role       text NOT NULL DEFAULT 'assistant'
                    CHECK (role IN ('lead', 'assistant', 'observer', 'intern', 'supervisor')),
    PRIMARY KEY (session_id, user_id)
);

-- ---- Цели индивидуального плана ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS eventum.goals (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id        uuid        NOT NULL REFERENCES eventum.children(id) ON DELETE CASCADE,
    program_id      uuid        REFERENCES eventum.programs(id) ON DELETE SET NULL,
    title           text        NOT NULL CHECK (length(btrim(title)) > 0),
    description     text,
    domain          text        CHECK (domain IS NULL OR domain IN ('communication', 'behavior', 'daily_living',
                                                                    'academic', 'motor', 'social', 'sensory',
                                                                    'independence', 'vocational')),
    baseline        text,                   -- что ребёнок умеет на старте
    target_criteria text,                   -- критерий достижения: «4 из 5 попыток, 3 дня подряд»
    status          core.goal_status NOT NULL DEFAULT 'planned',
    priority        smallint    NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    progress_percent core.percent NOT NULL DEFAULT 0,
    started_on      date,
    due_on          date,
    achieved_at     timestamptz,
    created_by      uuid        REFERENCES sec.users(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid        REFERENCES sec.users(id),
    deleted_at      timestamptz,
    CONSTRAINT goal_achieved_consistency CHECK (status <> 'achieved' OR achieved_at IS NOT NULL)
);

COMMENT ON TABLE eventum.goals IS 'Цели индивидуального маршрута. Прогресс ребёнка считается по ним, а не вводится вручную.';

CREATE INDEX IF NOT EXISTS ix_goals_child ON eventum.goals (child_id, status) WHERE deleted_at IS NULL;

-- Замеры по цели: реальная динамика, а не «ощущение специалиста».
CREATE TABLE IF NOT EXISTS eventum.goal_measurements (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    goal_id     uuid        NOT NULL REFERENCES eventum.goals(id) ON DELETE CASCADE,
    session_id  uuid        REFERENCES eventum.therapy_sessions(id) ON DELETE SET NULL,
    measured_at timestamptz NOT NULL DEFAULT now(),
    value       numeric(10, 2) NOT NULL,
    unit        text        NOT NULL DEFAULT 'percent'
                            CHECK (unit IN ('percent', 'count', 'seconds', 'minutes', 'trials', 'prompts', 'score')),
    trials_total   smallint,
    trials_success smallint,
    prompt_level   text     CHECK (prompt_level IS NULL OR prompt_level IN
                                   ('independent', 'verbal', 'gestural', 'model', 'partial_physical', 'full_physical')),
    note        text,
    recorded_by uuid        REFERENCES sec.users(id),
    CONSTRAINT measurement_trials_consistency CHECK (
        trials_total IS NULL OR trials_success IS NULL OR trials_success <= trials_total
    )
);

CREATE INDEX IF NOT EXISTS ix_measurements_goal ON eventum.goal_measurements (goal_id, measured_at DESC);

-- ---- Текущие задачи ребёнка (childTasks в прототипе) -------------------------------------
CREATE TABLE IF NOT EXISTS eventum.child_tasks (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id   uuid        NOT NULL REFERENCES eventum.children(id) ON DELETE CASCADE,
    goal_id    uuid        REFERENCES eventum.goals(id) ON DELETE SET NULL,
    text       text        NOT NULL CHECK (length(btrim(text)) > 0),
    is_done    boolean     NOT NULL DEFAULT false,
    done_at    timestamptz,
    done_by    uuid        REFERENCES sec.users(id),
    due_on     date,
    sort_order smallint    NOT NULL DEFAULT 100,
    created_by uuid        REFERENCES sec.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT task_done_consistency CHECK ((NOT is_done AND done_at IS NULL) OR (is_done AND done_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS ix_child_tasks_child ON eventum.child_tasks (child_id, is_done, sort_order);

-- ---- Записи о прогрессе (logs в прототипе) ------------------------------------------------
CREATE TABLE IF NOT EXISTS eventum.log_types (
    code       core.slug   PRIMARY KEY,
    name_ru    text        NOT NULL,
    name_kk    text        NOT NULL,
    name_en    text        NOT NULL,
    icon       text,
    sort_order smallint    NOT NULL DEFAULT 100,
    is_active  boolean     NOT NULL DEFAULT true
);

COMMENT ON TABLE eventum.log_types IS 'Типы записей: новый навык, коммуникация, бытовой навык, самостоятельность, инцидент';

CREATE TABLE IF NOT EXISTS eventum.progress_logs (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id     uuid        NOT NULL REFERENCES eventum.children(id)         ON DELETE CASCADE,
    session_id   uuid        REFERENCES eventum.therapy_sessions(id)          ON DELETE SET NULL,
    goal_id      uuid        REFERENCES eventum.goals(id)                     ON DELETE SET NULL,
    author_id    uuid        NOT NULL REFERENCES sec.users(id)                ON DELETE RESTRICT,
    type_code    core.slug   NOT NULL REFERENCES eventum.log_types(code)      ON UPDATE CASCADE,
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    body         text        NOT NULL CHECK (length(btrim(body)) > 0),
    next_step    text,                       -- поле «Следующий шаг» / goal в прототипе
    visibility   core.visibility_scope NOT NULL DEFAULT 'team',
    is_incident  boolean     NOT NULL DEFAULT false,
    incident_severity text   CHECK (incident_severity IS NULL OR incident_severity IN ('low', 'medium', 'high')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    edited_at    timestamptz,
    edited_by    uuid        REFERENCES sec.users(id),
    deleted_at   timestamptz,
    deleted_by   uuid        REFERENCES sec.users(id),
    CONSTRAINT log_incident_consistency CHECK (NOT is_incident OR incident_severity IS NOT NULL)
);

COMMENT ON TABLE  eventum.progress_logs IS 'Дневник наблюдений специалистов — сердце рабочей части портала';
COMMENT ON COLUMN eventum.progress_logs.visibility IS 'team — только команда; parents — видно родителю; admin_only — служебная запись';

CREATE INDEX IF NOT EXISTS ix_logs_child   ON eventum.progress_logs (child_id, occurred_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_logs_author  ON eventum.progress_logs (author_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS ix_logs_body_ft ON eventum.progress_logs USING gin (core.normalize_search(body) gin_trgm_ops);

-- =====================================================================================
--  РАЗДЕЛ 09. ДОКУМЕНТЫ, ЧАТ, УВЕДОМЛЕНИЯ, СОГЛАСОВАНИЯ
-- =====================================================================================

\echo '>>> [09] Документы, чат, уведомления, согласования...'

-- ---- Документы -------------------------------------------------------------------------
--  ДВА СПОСОБА ХРАНЕНИЯ ФАЙЛА, оба поддержаны схемой (колонка storage_kind):
--
--    'database'       — содержимое лежит в самой базе, в таблице eventum.document_chunks.
--                       Ничего дополнительно поднимать не нужно: загрузили файл из панели —
--                       он сохранён. Плюс: резервная копия базы содержит и файлы, права и
--                       журнал доступа работают ровно так же, как для остальных данных.
--                       Минус: дамп растёт вместе с файлами. Это рабочий вариант для фонда
--                       с четырьмя центрами, и он выбран по умолчанию.
--
--    'object_storage' — содержимое в S3/MinIO, в базе только ключ и контрольная сумма.
--                       Правильный выбор, когда файлов становятся десятки гигабайт
--                       (видео занятий). Переключение — сменой storage_kind, схему
--                       переделывать не придётся.
--
--  В обоих случаях в базе есть SHA-256: подмену файла видно сразу.

CREATE TABLE IF NOT EXISTS eventum.documents (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id         uuid        REFERENCES eventum.children(id) ON DELETE CASCADE,
    center_id        uuid        REFERENCES eventum.centers(id)  ON DELETE SET NULL,
    session_id       uuid        REFERENCES eventum.therapy_sessions(id) ON DELETE SET NULL,

    title            text        NOT NULL CHECK (length(btrim(title)) > 0),
    description      text,
    category         core.document_category NOT NULL DEFAULT 'other',

    -- Где лежит содержимое
    storage_kind     text        NOT NULL DEFAULT 'database'
                                 CHECK (storage_kind IN ('database', 'object_storage')),
    storage_bucket   text,                            -- только для object_storage
    storage_key      text,                            -- путь в объектном хранилище

    original_filename text       NOT NULL CHECK (length(btrim(original_filename)) > 0),
    mime_type        text        NOT NULL,
    size_bytes       bigint      CHECK (size_bytes IS NULL OR (size_bytes > 0 AND size_bytes <= 104857600)),
    checksum_sha256  bytea,                           -- целостность: файл не подменили

    -- Пока файл не долит до конца, он не показывается и не отдаётся
    upload_status    text        NOT NULL DEFAULT 'pending'
                                 CHECK (upload_status IN ('pending', 'stored', 'failed', 'quarantined')),
    uploaded_bytes   bigint      NOT NULL DEFAULT 0 CHECK (uploaded_bytes >= 0),

    is_encrypted     boolean     NOT NULL DEFAULT false,
    encryption_key_id text,                          -- идентификатор ключа в KMS
    visibility       core.visibility_scope NOT NULL DEFAULT 'team',

    virus_scan_status text       NOT NULL DEFAULT 'pending'
                                 CHECK (virus_scan_status IN ('pending', 'clean', 'infected', 'failed', 'skipped')),
    virus_scanned_at timestamptz,
    virus_scan_note  text,

    -- Версионность: новый файл не затирает прежний, а становится следующей версией
    version              integer NOT NULL DEFAULT 1 CHECK (version > 0),
    replaces_document_id uuid    REFERENCES eventum.documents(id) ON DELETE SET NULL,

    download_count   integer     NOT NULL DEFAULT 0 CHECK (download_count >= 0),
    last_downloaded_at timestamptz,

    valid_until      date,
    retention_until  timestamptz,

    uploaded_by      uuid        NOT NULL REFERENCES sec.users(id) ON DELETE RESTRICT,
    uploaded_at      timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at       timestamptz,
    deleted_by       uuid        REFERENCES sec.users(id),
    delete_reason    text,

    CONSTRAINT documents_mime_allowed CHECK (
        mime_type IN ('application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic',
                      'image/gif', 'image/svg+xml',
                      'video/mp4', 'video/quicktime', 'video/webm',
                      'audio/mpeg', 'audio/mp4', 'audio/ogg',
                      'text/plain', 'text/csv',
                      'application/zip',
                      'application/msword',
                      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                      'application/vnd.ms-excel',
                      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                      'application/vnd.ms-powerpoint',
                      'application/vnd.openxmlformats-officedocument.presentationml.presentation')
    ),
    CONSTRAINT documents_object_storage_needs_key CHECK (
        storage_kind <> 'object_storage' OR (storage_bucket IS NOT NULL AND storage_key IS NOT NULL)
    ),
    CONSTRAINT documents_stored_needs_checksum CHECK (
        upload_status <> 'stored' OR (checksum_sha256 IS NOT NULL AND size_bytes IS NOT NULL)
    )
);

COMMENT ON TABLE  eventum.documents IS 'Файлы портала: карточки, заключения, согласия, фото и видео занятий';
COMMENT ON COLUMN eventum.documents.storage_kind IS 'database — содержимое в eventum.document_chunks; object_storage — в S3/MinIO';
COMMENT ON COLUMN eventum.documents.upload_status IS 'Документ виден в интерфейсе только со статусом stored: недолитый файл не покажется';
COMMENT ON COLUMN eventum.documents.checksum_sha256 IS 'Контрольная сумма для проверки целостности и обнаружения дублей';
COMMENT ON COLUMN eventum.documents.virus_scan_status IS 'Файл выдаётся пользователю только после статуса clean или skipped';

CREATE INDEX IF NOT EXISTS ix_documents_child    ON eventum.documents (child_id, uploaded_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_documents_category ON eventum.documents (category)                   WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_documents_checksum ON eventum.documents (checksum_sha256);
CREATE INDEX IF NOT EXISTS ix_documents_pending  ON eventum.documents (uploaded_at) WHERE upload_status = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS ux_documents_object
    ON eventum.documents (storage_bucket, storage_key) WHERE storage_kind = 'object_storage';

-- ---- Содержимое файлов, хранимых в самой базе ---------------------------------------------
--  Файл режется на куски по 1 МБ. Почему не одной колонкой bytea:
--    * загрузка 50-мегабайтного видео одним запросом упирается в память и таймауты;
--    * кусками можно докачивать после обрыва и отдавать потоком;
--    * TOAST всё равно хранит большие значения кусками — здесь это просто явно.

CREATE TABLE IF NOT EXISTS eventum.document_chunks (
    document_id uuid     NOT NULL REFERENCES eventum.documents(id) ON DELETE CASCADE,
    chunk_no    integer  NOT NULL CHECK (chunk_no >= 0),
    data        bytea    NOT NULL CHECK (octet_length(data) > 0 AND octet_length(data) <= 4194304),
    byte_length integer  NOT NULL GENERATED ALWAYS AS (octet_length(data)) STORED,
    PRIMARY KEY (document_id, chunk_no)
);

COMMENT ON TABLE eventum.document_chunks
    IS 'Содержимое файлов при storage_kind = database. Читается и пишется ТОЛЬКО через функции eventum.document_*.';

-- Содержимое не сжимается повторно: картинки, видео и PDF уже сжаты, а попытка
-- пожать их ещё раз тратит процессор и ничего не экономит.
ALTER TABLE eventum.document_chunks ALTER COLUMN data SET STORAGE EXTERNAL;

-- Скан подписанного согласия ссылается на документ.
DO $fk_consent_doc$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'consents_document_fk') THEN
        ALTER TABLE eventum.consents
            ADD CONSTRAINT consents_document_fk
            FOREIGN KEY (document_id) REFERENCES eventum.documents(id) ON DELETE SET NULL;
    END IF;
END
$fk_consent_doc$;

-- ---- Чат команды -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS eventum.chat_threads (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    child_id   uuid        REFERENCES eventum.children(id) ON DELETE CASCADE,
    center_id  uuid        REFERENCES eventum.centers(id)  ON DELETE CASCADE,
    kind       text        NOT NULL DEFAULT 'child'
                           CHECK (kind IN ('child', 'center', 'direct', 'announcement')),
    title      text,
    is_archived boolean    NOT NULL DEFAULT false,
    created_by uuid        REFERENCES sec.users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chat_thread_child_kind CHECK (kind <> 'child' OR child_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_chat_thread_per_child
    ON eventum.chat_threads (child_id) WHERE kind = 'child';

CREATE TABLE IF NOT EXISTS eventum.chat_messages (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id  uuid        NOT NULL REFERENCES eventum.chat_threads(id) ON DELETE CASCADE,
    author_id  uuid        NOT NULL REFERENCES sec.users(id)            ON DELETE RESTRICT,
    body       text        NOT NULL CHECK (length(btrim(body)) > 0 AND length(body) <= 4000),
    reply_to_id uuid       REFERENCES eventum.chat_messages(id) ON DELETE SET NULL,
    document_id uuid       REFERENCES eventum.documents(id)     ON DELETE SET NULL,
    sent_at    timestamptz NOT NULL DEFAULT now(),
    edited_at  timestamptz,
    deleted_at timestamptz,
    deleted_by uuid        REFERENCES sec.users(id)
);

COMMENT ON TABLE eventum.chat_messages IS 'Переписка команды по ребёнку (вкладка «Чат» в карточке)';

CREATE INDEX IF NOT EXISTS ix_chat_messages_thread ON eventum.chat_messages (thread_id, sent_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS eventum.chat_mentions (
    message_id uuid NOT NULL REFERENCES eventum.chat_messages(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES sec.users(id)             ON DELETE CASCADE,
    PRIMARY KEY (message_id, user_id)
);

COMMENT ON TABLE eventum.chat_mentions IS 'Упоминания @имя — прототип разбирал их регуляркой, здесь это связь';

CREATE TABLE IF NOT EXISTS eventum.chat_reads (
    thread_id  uuid        NOT NULL REFERENCES eventum.chat_threads(id) ON DELETE CASCADE,
    user_id    uuid        NOT NULL REFERENCES sec.users(id)            ON DELETE CASCADE,
    last_read_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (thread_id, user_id)
);

-- ---- Уведомления ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS eventum.notifications (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    kind        text        NOT NULL CHECK (kind IN ('mention', 'new_log', 'session_reminder', 'session_changed',
                                                     'approval_request', 'approval_decided', 'document_uploaded',
                                                     'task_assigned', 'system', 'security')),
    title       text        NOT NULL,
    body        text,
    entity_type text,
    entity_id   uuid,
    url         text,
    channel     core.notification_channel NOT NULL DEFAULT 'in_app',
    is_read     boolean     NOT NULL DEFAULT false,
    read_at     timestamptz,
    delivered_at timestamptz,
    delivery_error text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    CONSTRAINT notification_read_consistency CHECK ((NOT is_read AND read_at IS NULL) OR is_read)
);

CREATE INDEX IF NOT EXISTS ix_notifications_inbox ON eventum.notifications (user_id, created_at DESC)
    WHERE NOT is_read;

-- ---- Заявки на согласование (view-approvals) -------------------------------------------------
--  В прототипе у заявки была только «ожидающая» форма. Реальный процесс требует решения:
--  кто, когда и с какой формулировкой одобрил или отклонил.

CREATE TABLE IF NOT EXISTS eventum.change_requests (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_by  uuid        NOT NULL REFERENCES sec.users(id) ON DELETE RESTRICT,
    subject_type  text        NOT NULL CHECK (subject_type IN ('child', 'goal', 'team', 'user', 'document',
                                                               'session', 'center', 'access', 'other')),
    subject_id    uuid,
    subject_label text        NOT NULL,          -- «Санжар М.» — что видит согласующий
    title         text        NOT NULL,          -- «Изменить состав команды ребёнка»
    detail        text,                          -- «Добавить специалиста по трудотерапии»
    payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,   -- предлагаемые значения
    status        core.request_status NOT NULL DEFAULT 'pending',
    priority      smallint    NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    decided_by    uuid        REFERENCES sec.users(id),
    decided_at    timestamptz,
    decision_note text,
    applied_at    timestamptz,                   -- когда изменение реально применили
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz,
    CONSTRAINT change_request_decision_consistency CHECK (
        (status = 'pending'  AND decided_by IS NULL AND decided_at IS NULL) OR
        (status = 'cancelled') OR
        (status IN ('approved', 'rejected') AND decided_by IS NOT NULL AND decided_at IS NOT NULL)
    ),
    CONSTRAINT change_request_rejection_needs_note CHECK (
        status <> 'rejected' OR decision_note IS NOT NULL
    )
);

COMMENT ON TABLE eventum.change_requests IS 'Очередь согласований (экран «Согласования»). Ни одно чувствительное изменение не проходит молча.';

CREATE INDEX IF NOT EXISTS ix_change_requests_pending ON eventum.change_requests (created_at DESC) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS ix_change_requests_author  ON eventum.change_requests (requested_by, created_at DESC);

-- ---- Запросы расширенного доступа (кнопка requestAccess) --------------------------------------
CREATE TABLE IF NOT EXISTS eventum.access_requests (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    child_id      uuid        REFERENCES eventum.children(id)   ON DELETE CASCADE,
    center_id     uuid        REFERENCES eventum.centers(id)    ON DELETE CASCADE,
    permission_code text      REFERENCES sec.permissions(code)  ON DELETE CASCADE,
    justification text        NOT NULL,
    status        core.request_status NOT NULL DEFAULT 'pending',
    decided_by    uuid        REFERENCES sec.users(id),
    decided_at    timestamptz,
    decision_note text,
    granted_until timestamptz,                 -- временный доступ лучше постоянного
    created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE eventum.access_requests IS 'Запросы доступа к карте ребёнка или к центру, вне обычных прав роли';

-- ---- Расписание работы сотрудников (для проверки доступности при записи) -------------------
CREATE TABLE IF NOT EXISTS eventum.staff_availability (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES sec.users(id)      ON DELETE CASCADE,
    center_id   uuid        REFERENCES eventum.centers(id)         ON DELETE CASCADE,
    weekday     smallint    NOT NULL CHECK (weekday BETWEEN 0 AND 6),  -- 0 = воскресенье
    starts_at   time        NOT NULL,
    ends_at     time        NOT NULL,
    valid_from  date        NOT NULL DEFAULT current_date,
    valid_until date,
    CONSTRAINT availability_time_valid CHECK (ends_at > starts_at)
);

CREATE TABLE IF NOT EXISTS eventum.staff_absences (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES sec.users(id) ON DELETE CASCADE,
    starts_at   timestamptz NOT NULL,
    ends_at     timestamptz NOT NULL,
    reason      text        NOT NULL CHECK (reason IN ('vacation', 'sick_leave', 'training', 'business_trip', 'other')),
    comment     text,
    approved_by uuid        REFERENCES sec.users(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT absence_period_valid CHECK (ends_at > starts_at)
);

COMMENT ON TABLE eventum.staff_absences IS 'Отпуска, больничные, обучение — расписание не должно ставить занятия на это время';

-- =====================================================================================
--  РАЗДЕЛ 10. ПУБЛИЧНЫЙ САЙТ (schema site)
-- =====================================================================================
--  Сейчас весь контент foundation.html зашит в JavaScript тремя копиями — ru, kk и en.
--  Здесь он вынесен в таблицы по схеме «сущность + переводы»: добавить язык или
--  поправить текст можно без правки HTML.
--
--  Формы сайта (contactForm, joinForm, donationForm) сейчас просто открывают WhatsApp.
--  Таблицы ниже позволяют сохранять заявку на сервере: ни одно обращение не потеряется.
-- =====================================================================================

\echo '>>> [10] Публичный сайт: заявки, пожертвования, контент...'

-- ---- 10.1 Настройки и статистика ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS site.settings (
    key         text        PRIMARY KEY,
    value       jsonb       NOT NULL,
    description text,
    is_public   boolean     NOT NULL DEFAULT true,   -- можно ли отдавать в браузер
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid        REFERENCES sec.users(id)
);

COMMENT ON TABLE site.settings IS 'Замена window.URPAQ_CONFIG: paymentUrl, телефон, ссылки на соцсети';

CREATE TABLE IF NOT EXISTS site.stat_counters (
    code       core.slug   PRIMARY KEY,       -- centers | children | team | directions
    value      integer     NOT NULL CHECK (value >= 0),
    suffix     text,                          -- «+», «более»
    label_ru   text        NOT NULL,
    label_kk   text        NOT NULL,
    label_en   text        NOT NULL,
    sort_order smallint    NOT NULL DEFAULT 100,
    is_active  boolean     NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid        REFERENCES sec.users(id)
);

COMMENT ON TABLE site.stat_counters IS 'Счётчики в первом экране сайта: «4 центра», «детей в программах» и т.д.';

-- ---- 10.2 Обращения с сайта ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS site.contact_requests (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_number  text        NOT NULL UNIQUE,     -- «OБР-2026-000123» для ответа семье
    name           text        NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 120),
    phone          core.phone  NOT NULL,
    email          core.email,
    topic          text        NOT NULL,            -- значение из выпадающего списка формы
    message        text        CHECK (message IS NULL OR length(message) <= 1200),
    locale         core.locale_code NOT NULL DEFAULT 'ru',

    -- Согласие на обработку — на сайте это обязательная галочка, здесь она фиксируется.
    consent_given  boolean     NOT NULL,
    consent_at     timestamptz NOT NULL DEFAULT now(),
    consent_text_version text,

    status         core.lead_status NOT NULL DEFAULT 'new',
    assigned_to    uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    handled_at     timestamptz,
    internal_note  text,
    linked_child_id uuid       REFERENCES eventum.children(id) ON DELETE SET NULL,

    source_page    text,
    referrer       text,
    utm_source     text,
    utm_medium     text,
    utm_campaign   text,
    ip             inet,
    user_agent     text,
    spam_score     smallint    CHECK (spam_score IS NULL OR spam_score BETWEEN 0 AND 100),

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,

    CONSTRAINT contact_consent_required CHECK (consent_given)
);

COMMENT ON TABLE site.contact_requests IS 'Заявки формы «Записаться на консультацию» (contactForm)';

CREATE INDEX IF NOT EXISTS ix_contact_requests_status ON site.contact_requests (status, created_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_contact_requests_phone  ON site.contact_requests (phone);

CREATE TABLE IF NOT EXISTS site.join_requests (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_number  text        NOT NULL UNIQUE,
    kind           core.join_kind NOT NULL DEFAULT 'other',
    name           text        NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 120),
    phone          core.phone  NOT NULL,
    email          core.email,
    organization   text        CHECK (organization IS NULL OR length(organization) <= 180),
    message        text        CHECK (message IS NULL OR length(message) <= 1200),
    locale         core.locale_code NOT NULL DEFAULT 'ru',
    consent_given  boolean     NOT NULL,
    consent_at     timestamptz NOT NULL DEFAULT now(),
    status         core.lead_status NOT NULL DEFAULT 'new',
    assigned_to    uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    handled_at     timestamptz,
    internal_note  text,
    ip             inet,
    user_agent     text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at     timestamptz,
    CONSTRAINT join_consent_required CHECK (consent_given)
);

COMMENT ON TABLE site.join_requests IS 'Заявки «Стать партнёром / волонтёром / спонсором» (joinForm)';

CREATE TABLE IF NOT EXISTS site.training_applications (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_number  text        NOT NULL UNIQUE,
    program_code   text,
    name           text        NOT NULL,
    phone          core.phone  NOT NULL,
    email          core.email,
    city           text,
    country        text,
    profession     text,
    experience_years smallint  CHECK (experience_years IS NULL OR experience_years BETWEEN 0 AND 70),
    motivation     text,
    locale         core.locale_code NOT NULL DEFAULT 'ru',
    consent_given  boolean     NOT NULL,
    status         core.lead_status NOT NULL DEFAULT 'new',
    assigned_to    uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT training_consent_required CHECK (consent_given)
);

COMMENT ON TABLE site.training_applications IS 'Заявки на стажировки и обучение специалистов (раздел «Обучение»)';

-- ---- 10.3 Пожертвования ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS site.donation_directions (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code        core.slug   NOT NULL UNIQUE,
    goal_amount core.money_amount,
    currency    core.currency_code NOT NULL DEFAULT 'USD',
    is_active   boolean     NOT NULL DEFAULT true,
    sort_order  smallint    NOT NULL DEFAULT 100,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.donation_direction_translations (
    direction_id uuid             NOT NULL REFERENCES site.donation_directions(id) ON DELETE CASCADE,
    locale       core.locale_code NOT NULL,
    title        text             NOT NULL,
    description  text,
    PRIMARY KEY (direction_id, locale)
);

COMMENT ON TABLE site.donation_directions IS 'Направления сбора: терапия, сенсорные залы, площадка, теплица, стипендии';

CREATE TABLE IF NOT EXISTS site.donations (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    reference_code     text        NOT NULL UNIQUE,      -- номер для квитанции

    direction_id       uuid        REFERENCES site.donation_directions(id) ON DELETE SET NULL,
    amount             core.money_amount NOT NULL CHECK (amount > 0),
    currency           core.currency_code NOT NULL DEFAULT 'USD',
    amount_kzt         core.money_amount,                -- сумма в тенге на момент платежа
    exchange_rate      numeric(12, 6),

    -- Донор
    donor_name         text        CHECK (donor_name IS NULL OR length(donor_name) <= 120),
    donor_email        core.email,
    donor_phone        core.phone,
    donor_user_id      uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    visibility         core.donor_visibility NOT NULL DEFAULT 'public',
    show_amount_publicly boolean   NOT NULL DEFAULT false,
    message            text        CHECK (message IS NULL OR length(message) <= 500),

    consent_given      boolean     NOT NULL DEFAULT true,
    consent_at         timestamptz NOT NULL DEFAULT now(),

    -- Платёж. Реквизиты карт в базе НЕ хранятся: это зона ответственности провайдера (PCI DSS).
    status             core.donation_status NOT NULL DEFAULT 'created',
    payment_provider   text,
    provider_payment_id text,
    payment_method     text        CHECK (payment_method IS NULL OR payment_method IN
                                          ('card', 'kaspi', 'bank_transfer', 'cash', 'apple_pay', 'google_pay', 'crypto')),
    card_last4         char(4)     CHECK (card_last4 IS NULL OR card_last4 ~ '^[0-9]{4}$'),
    paid_at            timestamptz,
    failed_reason      text,
    refunded_at        timestamptz,
    refund_amount      core.money_amount,
    receipt_url        text,
    receipt_sent_at    timestamptz,

    is_recurring       boolean     NOT NULL DEFAULT false,
    recurring_period   text        CHECK (recurring_period IS NULL OR recurring_period IN ('monthly', 'quarterly', 'yearly')),
    parent_donation_id uuid        REFERENCES site.donations(id) ON DELETE SET NULL,

    is_verified        boolean     NOT NULL DEFAULT false,   -- сайт публикует только подтверждённое
    verified_by        uuid        REFERENCES sec.users(id),
    verified_at        timestamptz,

    locale             core.locale_code NOT NULL DEFAULT 'ru',
    ip                 inet,
    user_agent         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT donation_paid_consistency CHECK (status <> 'succeeded' OR paid_at IS NOT NULL),
    CONSTRAINT donation_public_needs_name CHECK (visibility <> 'public' OR donor_name IS NOT NULL),
    CONSTRAINT donation_refund_valid CHECK (refund_amount IS NULL OR refund_amount <= amount),
    CONSTRAINT donation_provider_unique UNIQUE (payment_provider, provider_payment_id)
);

COMMENT ON TABLE  site.donations IS 'Пожертвования (donationForm). Данные карт не хранятся — только идентификатор платежа у провайдера.';
COMMENT ON COLUMN site.donations.visibility IS 'public — имя можно показать в списке доноров; anonymous — нельзя ни при каких условиях';
COMMENT ON COLUMN site.donations.is_verified IS 'Сайт обещает публиковать доноров «только после подтверждения данных» — вот этот флаг';

CREATE INDEX IF NOT EXISTS ix_donations_status    ON site.donations (status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_donations_direction ON site.donations (direction_id) WHERE status = 'succeeded';
CREATE INDEX IF NOT EXISTS ix_donations_donor     ON site.donations (donor_email)  WHERE donor_email IS NOT NULL;

-- ---- 10.4 Контент сайта -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS site.team_members (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code        core.slug   NOT NULL UNIQUE,          -- tatiana, nurlygul, asem...
    user_id     uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    full_name   text        NOT NULL,
    -- Фотография лежит в базе как обычный документ. photo_url оставлен на случай CDN;
    -- сейчас в HTML снимки зашиты в скрипт как base64 — так их не заменить без правки кода.
    photo_document_id uuid  REFERENCES eventum.documents(id) ON DELETE SET NULL,
    photo_url   text,
    center_id   uuid        REFERENCES eventum.centers(id) ON DELETE SET NULL,
    is_published boolean    NOT NULL DEFAULT true,
    sort_order  smallint    NOT NULL DEFAULT 100,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.team_member_translations (
    member_id   uuid             NOT NULL REFERENCES site.team_members(id) ON DELETE CASCADE,
    locale      core.locale_code NOT NULL,
    full_name   text             NOT NULL,
    role_title  text             NOT NULL,
    experience  text,
    achievement text,
    bio         text,
    PRIMARY KEY (member_id, locale)
);

COMMENT ON TABLE site.team_members IS 'Раздел «Команда». Профили публикуются только с согласия сотрудника (eventum.consents).';

CREATE TABLE IF NOT EXISTS site.projects (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code         core.slug   NOT NULL UNIQUE,
    icon         text,
    stage        text        NOT NULL DEFAULT 'concept'
                             CHECK (stage IN ('concept', 'fundraising', 'active', 'completed', 'paused')),
    budget_total core.money_amount,
    budget_raised core.money_amount NOT NULL DEFAULT 0,
    currency     core.currency_code NOT NULL DEFAULT 'KZT',
    coordinator_id uuid      REFERENCES sec.users(id) ON DELETE SET NULL,
    started_on   date,
    finished_on  date,
    report_document_id uuid  REFERENCES eventum.documents(id) ON DELETE SET NULL,
    is_published boolean     NOT NULL DEFAULT true,
    sort_order   smallint    NOT NULL DEFAULT 100,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.project_translations (
    project_id  uuid             NOT NULL REFERENCES site.projects(id) ON DELETE CASCADE,
    locale      core.locale_code NOT NULL,
    title       text             NOT NULL,
    status_label text,
    summary     text,
    why_text    text,             -- поле why из данных сайта
    description text,
    PRIMARY KEY (project_id, locale)
);

COMMENT ON TABLE site.projects IS 'Проекты фонда: доступ к терапии, площадка, теплица, стипендии';

CREATE TABLE IF NOT EXISTS site.news_posts (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         core.slug   NOT NULL UNIQUE,
    cover_document_id uuid   REFERENCES eventum.documents(id) ON DELETE SET NULL,
    cover_url    text,
    category     text        NOT NULL DEFAULT 'news'
                             CHECK (category IN ('news', 'event', 'announcement', 'story', 'report')),
    author_id    uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    published_at timestamptz,
    is_published boolean     NOT NULL DEFAULT false,
    -- Новости о детях публикуются только при наличии согласия семьи.
    consent_id   uuid        REFERENCES eventum.consents(id) ON DELETE SET NULL,
    views_count  integer     NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT news_published_needs_date CHECK (NOT is_published OR published_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS site.news_translations (
    post_id  uuid             NOT NULL REFERENCES site.news_posts(id) ON DELETE CASCADE,
    locale   core.locale_code NOT NULL,
    label    text,
    title    text             NOT NULL,
    summary  text,
    body     text,
    PRIMARY KEY (post_id, locale)
);

CREATE TABLE IF NOT EXISTS site.blog_posts (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         core.slug   NOT NULL UNIQUE,
    icon         text,
    reading_minutes smallint,
    author_id    uuid        REFERENCES sec.users(id) ON DELETE SET NULL,
    published_at timestamptz,
    is_published boolean     NOT NULL DEFAULT false,
    sort_order   smallint    NOT NULL DEFAULT 100,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.blog_translations (
    post_id  uuid             NOT NULL REFERENCES site.blog_posts(id) ON DELETE CASCADE,
    locale   core.locale_code NOT NULL,
    tag      text,
    title    text             NOT NULL,
    summary  text,
    body     text,
    PRIMARY KEY (post_id, locale)
);

COMMENT ON TABLE site.blog_posts IS 'Раздел «Родителям»: короткие материалы о развитии и поддержке';

CREATE TABLE IF NOT EXISTS site.faq_items (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code       core.slug   NOT NULL UNIQUE,
    category   text        NOT NULL DEFAULT 'general'
                           CHECK (category IN ('general', 'programs', 'training', 'donations', 'legal')),
    sort_order smallint    NOT NULL DEFAULT 100,
    is_published boolean   NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.faq_translations (
    item_id  uuid             NOT NULL REFERENCES site.faq_items(id) ON DELETE CASCADE,
    locale   core.locale_code NOT NULL,
    question text             NOT NULL,
    answer   text             NOT NULL,
    PRIMARY KEY (item_id, locale)
);

CREATE TABLE IF NOT EXISTS site.training_programs (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code        core.slug   NOT NULL UNIQUE,
    format      text        NOT NULL DEFAULT 'internship'
                            CHECK (format IN ('internship', 'supervision', 'training', 'webinar', 'conference')),
    enrollment_mode text    NOT NULL DEFAULT 'by_application'
                            CHECK (enrollment_mode IN ('by_application', 'by_agreement', 'by_announcement')),
    duration_days smallint,
    price       core.money_amount,
    currency    core.currency_code NOT NULL DEFAULT 'KZT',
    center_id   uuid        REFERENCES eventum.centers(id) ON DELETE SET NULL,
    coordinator_id uuid     REFERENCES sec.users(id) ON DELETE SET NULL,
    is_published boolean    NOT NULL DEFAULT true,
    sort_order  smallint    NOT NULL DEFAULT 100,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.training_program_translations (
    program_id  uuid             NOT NULL REFERENCES site.training_programs(id) ON DELETE CASCADE,
    locale      core.locale_code NOT NULL,
    title       text             NOT NULL,
    audience    text,             -- «кому подойдёт»
    description text,
    status_note text,             -- «Даты следующего потока согласовываются»
    PRIMARY KEY (program_id, locale)
);

CREATE TABLE IF NOT EXISTS site.training_events (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    program_id  uuid        NOT NULL REFERENCES site.training_programs(id) ON DELETE CASCADE,
    starts_on   date,
    ends_on     date,
    seats_total smallint    CHECK (seats_total IS NULL OR seats_total > 0),
    seats_taken smallint    NOT NULL DEFAULT 0 CHECK (seats_taken >= 0),
    status      text        NOT NULL DEFAULT 'announced'
                            CHECK (status IN ('draft', 'announced', 'enrolling', 'full', 'running', 'finished', 'cancelled')),
    is_published boolean    NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT training_event_dates CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on),
    CONSTRAINT training_event_seats CHECK (seats_total IS NULL OR seats_taken <= seats_total)
);

COMMENT ON TABLE site.training_events IS 'Календарь набора: конкретные потоки стажировок и супервизий';

CREATE TABLE IF NOT EXISTS site.volunteer_opportunities (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code        core.slug   NOT NULL UNIQUE,
    icon        text,
    is_published boolean    NOT NULL DEFAULT true,
    sort_order  smallint    NOT NULL DEFAULT 100,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.volunteer_opportunity_translations (
    opportunity_id uuid             NOT NULL REFERENCES site.volunteer_opportunities(id) ON DELETE CASCADE,
    locale         core.locale_code NOT NULL,
    title          text             NOT NULL,
    description    text,
    PRIMARY KEY (opportunity_id, locale)
);

-- Публичная отчётность фонда — обещание прозрачности из раздела «Отчётность».
CREATE TABLE IF NOT EXISTS site.public_reports (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    year         smallint    NOT NULL CHECK (year BETWEEN 2000 AND 2100),
    kind         text        NOT NULL CHECK (kind IN ('financial', 'project', 'annual', 'audit')),
    document_id  uuid        REFERENCES eventum.documents(id) ON DELETE SET NULL,
    file_url     text,
    published_at timestamptz,
    is_published boolean     NOT NULL DEFAULT false,
    approved_by  uuid        REFERENCES sec.users(id),
    approved_at  timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (year, kind),
    CONSTRAINT report_published_requires_approval CHECK (NOT is_published OR approved_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS site.public_report_translations (
    report_id uuid             NOT NULL REFERENCES site.public_reports(id) ON DELETE CASCADE,
    locale    core.locale_code NOT NULL,
    title     text             NOT NULL,
    summary   text,
    PRIMARY KEY (report_id, locale)
);

COMMENT ON TABLE site.public_reports IS 'Годовые и проектные отчёты. Публикуются только после утверждения (approved_at).';

-- Фотоальбомы событий. Каждое фото привязано к согласию — иначе публиковать нельзя.
CREATE TABLE IF NOT EXISTS site.media_albums (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         core.slug   NOT NULL UNIQUE,
    center_id    uuid        REFERENCES eventum.centers(id) ON DELETE SET NULL,
    event_date   date,
    cover_document_id uuid   REFERENCES eventum.documents(id) ON DELETE SET NULL,
    cover_url    text,
    is_published boolean     NOT NULL DEFAULT false,
    created_by   uuid        REFERENCES sec.users(id),
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS site.media_album_translations (
    album_id uuid             NOT NULL REFERENCES site.media_albums(id) ON DELETE CASCADE,
    locale   core.locale_code NOT NULL,
    title    text             NOT NULL,
    description text,
    PRIMARY KEY (album_id, locale)
);

CREATE TABLE IF NOT EXISTS site.media_items (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id    uuid        NOT NULL REFERENCES site.media_albums(id) ON DELETE CASCADE,
    kind        text        NOT NULL DEFAULT 'photo' CHECK (kind IN ('photo', 'video')),
    file_document_id uuid    REFERENCES eventum.documents(id) ON DELETE SET NULL,
    file_url    text,
    thumbnail_url text,
    alt_ru      text,
    alt_kk      text,
    alt_en      text,
    -- Ключевая проверка: на снимке есть ребёнок → нужна ссылка на действующее согласие.
    depicts_child_id uuid   REFERENCES eventum.children(id) ON DELETE SET NULL,
    consent_id  uuid        REFERENCES eventum.consents(id) ON DELETE SET NULL,
    is_published boolean    NOT NULL DEFAULT false,
    sort_order  smallint    NOT NULL DEFAULT 100,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT media_child_requires_consent CHECK (
        depicts_child_id IS NULL OR NOT is_published OR consent_id IS NOT NULL
    ),
    CONSTRAINT media_needs_source CHECK (
        file_document_id IS NOT NULL OR file_url IS NOT NULL
    )
);

COMMENT ON CONSTRAINT media_child_requires_consent ON site.media_items
    IS 'База не даст опубликовать фотографию ребёнка без ссылки на согласие семьи';

CREATE TABLE IF NOT EXISTS site.instagram_posts (
    id          text        PRIMARY KEY,        -- идентификатор публикации в Instagram
    permalink   text        NOT NULL,
    media_url   text,
    thumbnail_url text,
    caption     text,
    media_type  text        CHECK (media_type IN ('IMAGE', 'VIDEO', 'CAROUSEL_ALBUM')),
    posted_at   timestamptz,
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    is_visible  boolean     NOT NULL DEFAULT true
);

COMMENT ON TABLE site.instagram_posts IS 'Кеш ленты Instagram: сайт не должен зависеть от доступности внешнего API';
-- ---- 10.5 Тексты интерфейса, списочные секции и юридические документы -----------------------
--  Сейчас ВЕСЬ текст сайта и портала зашит в JavaScript тремя копиями (ru/kk/en), а часть
--  разделов существует только как массивы внутри скрипта. Правка опечатки требует
--  редактирования HTML и выкладки. Три таблицы ниже переносят это в базу.

CREATE TABLE IF NOT EXISTS site.ui_strings (
    scope      text             NOT NULL CHECK (scope IN ('site', 'portal', 'email', 'sms')),
    key        text             NOT NULL CHECK (length(btrim(key)) > 0),
    locale     core.locale_code NOT NULL,
    value      text             NOT NULL,
    context    text,                       -- подсказка переводчику, где эта строка появляется
    updated_at timestamptz      NOT NULL DEFAULT now(),
    updated_by uuid             REFERENCES sec.users(id),
    PRIMARY KEY (scope, key, locale)
);

COMMENT ON TABLE site.ui_strings
    IS 'Все подписи сайта и портала: nav.about, form.consent, donate.title и т.д. Заменяет объект locales в скрипте.';

CREATE INDEX IF NOT EXISTS ix_ui_strings_locale ON site.ui_strings (scope, locale);

-- Списочные секции: «почему нам доверяют», «стандарт прозрачного проекта»,
-- форматы участия, шаги маршрута помощи, направления волонтёрства.
CREATE TABLE IF NOT EXISTS site.content_blocks (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    section      text        NOT NULL CHECK (section IN ('trust', 'standards', 'join_options',
                                                         'path_steps', 'opportunities', 'routes',
                                                         'training_audience', 'contact_topics')),
    code         core.slug   NOT NULL,
    icon         text,
    sort_order   smallint    NOT NULL DEFAULT 100,
    is_published boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (section, code)
);

CREATE TABLE IF NOT EXISTS site.content_block_translations (
    block_id uuid             NOT NULL REFERENCES site.content_blocks(id) ON DELETE CASCADE,
    locale   core.locale_code NOT NULL,
    title    text             NOT NULL,
    text     text,
    PRIMARY KEY (block_id, locale)
);

COMMENT ON TABLE site.content_blocks
    IS 'Однотипные карточки разделов сайта. Раньше — массивы trust/standards/joinOptions прямо в скрипте.';

-- Юридические документы с версиями. Версия нужна не для порядка, а по существу:
-- eventum.consents.wording_version хранит, ПОД КАКИМ текстом семья поставила подпись.
-- Без этого через год невозможно доказать, на что именно согласился представитель.
CREATE TABLE IF NOT EXISTS site.legal_documents (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code           core.slug   NOT NULL,
    kind           text        NOT NULL CHECK (kind IN ('privacy_policy', 'public_offer', 'terms',
                                                        'consent_form', 'disclaimer', 'refund_policy')),
    version        text        NOT NULL,
    effective_from date        NOT NULL DEFAULT current_date,
    is_current     boolean     NOT NULL DEFAULT false,
    document_id    uuid        REFERENCES eventum.documents(id) ON DELETE SET NULL,  -- подписанный скан
    approved_by    uuid        REFERENCES sec.users(id),
    approved_at    timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (code, version),
    CONSTRAINT legal_current_requires_approval CHECK (NOT is_current OR approved_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS site.legal_document_translations (
    legal_id uuid             NOT NULL REFERENCES site.legal_documents(id) ON DELETE CASCADE,
    locale   core.locale_code NOT NULL,
    title    text             NOT NULL,
    body     text             NOT NULL,
    PRIMARY KEY (legal_id, locale)
);

-- Действующая редакция каждого вида документа может быть только одна.
CREATE UNIQUE INDEX IF NOT EXISTS ux_legal_current ON site.legal_documents (kind) WHERE is_current;

COMMENT ON TABLE site.legal_documents
    IS 'Политика конфиденциальности, оферта, формы согласий. Публикуются только после утверждения.';

-- ---- Функции доступа к текстам ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION site.t(p_scope text, p_key text, p_locale core.locale_code DEFAULT 'ru')
RETURNS text
LANGUAGE sql
STABLE
AS $$
    -- Если перевода на нужный язык нет — отдаём русский, а не пустоту:
    -- лучше показать текст на другом языке, чем дыру в интерфейсе.
    SELECT coalesce(
             (SELECT value FROM site.ui_strings WHERE scope = p_scope AND key = p_key AND locale = p_locale),
             (SELECT value FROM site.ui_strings WHERE scope = p_scope AND key = p_key AND locale = 'ru'),
             p_key);
$$;

COMMENT ON FUNCTION site.t(text, text, core.locale_code) IS 'Перевод одной строки с откатом на русский';

-- Весь словарь одним запросом: фронт получает готовый JSON и не ходит в базу за каждой подписью.
CREATE OR REPLACE FUNCTION site.translations(p_scope text, p_locale core.locale_code DEFAULT 'ru')
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
      FROM (
        SELECT DISTINCT ON (key) key, value
          FROM site.ui_strings
         WHERE scope = p_scope AND locale IN (p_locale, 'ru')
         ORDER BY key, (locale = p_locale) DESC
      ) t;
$$;

COMMENT ON FUNCTION site.translations(text, core.locale_code)
    IS 'Словарь интерфейса целиком. Заменяет объект locales в staff-portal.html и foundation.html.';

-- Загрузка словаря из существующего JSON: чтобы не перенабирать вручную сотни строк,
-- достаточно один раз скормить сюда объект locales.ru из скрипта.
CREATE OR REPLACE FUNCTION site.import_ui_strings(
    p_scope   text,
    p_locale  core.locale_code,
    p_strings jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, sec, core, pg_catalog, public
AS $$
DECLARE
    v_count integer;
BEGIN
    IF sec.current_user_id() IS NOT NULL AND NOT sec.has_permission('content.manage') THEN
        RAISE EXCEPTION 'Недостаточно прав для загрузки текстов' USING ERRCODE = '42501';
    END IF;

    -- Вложенные объекты (nav.about, form.consent) разворачиваются в плоские ключи.
    WITH RECURSIVE flat(key, value) AS (
        SELECT k, v FROM jsonb_each(p_strings) AS e(k, v)
        UNION ALL
        SELECT f.key || '.' || e.k, e.v
          FROM flat f, jsonb_each(f.value) AS e(k, v)
         WHERE jsonb_typeof(f.value) = 'object'
    )
    INSERT INTO site.ui_strings (scope, key, locale, value, updated_by)
    SELECT p_scope, key, p_locale, value #>> '{}', sec.current_user_id()
      FROM flat
     WHERE jsonb_typeof(value) = 'string'
    ON CONFLICT (scope, key, locale) DO UPDATE
       SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION site.import_ui_strings(text, core.locale_code, jsonb)
    IS 'Разовый перенос объекта locales из HTML в базу: SELECT site.import_ui_strings(''site'', ''ru'', ''<json>'');';


-- =====================================================================================
--  РАЗДЕЛ 11. СЕРВЕРНАЯ ЛОГИКА (функции — «бекенд» внутри базы)
-- =====================================================================================
--  Приложение не должно писать в таблицы напрямую. Каждая операция — вызов функции:
--  она проверяет права, соблюдает бизнес-правила и пишет в журнал. Даже если кто-то
--  получит доступ к соединению приложения, обойти проверки не выйдет.
--
--  Порядок работы веб-запроса:
--      1. sec.begin_request(<токен сессии>, <ip>, <request_id>)
--      2. вызовы бизнес-функций / чтение представлений
--      3. sec.end_request()
-- =====================================================================================

\echo '>>> [11] Серверные функции...'

-- ---- 11.1 Вход, сессии, выход ---------------------------------------------------------

CREATE OR REPLACE FUNCTION sec.authenticate(
    p_username   text,
    p_password   text,
    p_ip         inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL
)
RETURNS TABLE (
    success              boolean,
    reason               text,
    session_token        text,
    session_id           uuid,
    user_id              uuid,
    username             text,
    full_name            text,
    role_code            text,
    must_change_password boolean,
    mfa_required         boolean,
    expires_at           timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, eventum, audit, pg_catalog, public
AS $$
DECLARE
    v_user     sec.users%ROWTYPE;
    p          sec.password_policy%ROWTYPE;
    v_token    text;
    v_expires  timestamptz;
    v_session  uuid;
    v_fail     text;
    v_attempts smallint;
BEGIN
    SELECT * INTO p FROM sec.password_policy WHERE id = 1;

    SELECT * INTO v_user
      FROM sec.users u
     WHERE u.username = p_username::citext
       AND u.deleted_at IS NULL;

    -- ВАЖНО: при ошибке входа функция НЕ бросает исключение, а возвращает строку с
    -- success = false. Исключение откатило бы транзакцию — вместе со счётчиком неудачных
    -- попыток и записью в журнале, и защита от перебора перестала бы работать.

    IF NOT FOUND THEN
        -- Одинаковое время ответа для существующего и несуществующего логина:
        -- иначе по задержке можно перебрать список действующих учётных записей.
        PERFORM crypt(coalesce(p_password, ''), gen_salt('bf', p.bcrypt_cost));

        INSERT INTO sec.login_attempts (username_attempted, succeeded, failure_reason, ip, user_agent)
        VALUES (p_username::citext, false, 'user_not_found', p_ip, p_user_agent);

        INSERT INTO audit.security_events (kind, severity, ip, user_agent, succeeded, reason, context)
        VALUES ('login_failed', 'notice', p_ip, p_user_agent, false, 'Неизвестный логин',
                jsonb_build_object('username', left(coalesce(p_username, ''), 64)));

        RETURN QUERY SELECT false, 'invalid_credentials', NULL::text, NULL::uuid, NULL::uuid,
                            NULL::text, NULL::text, NULL::text, false, false, NULL::timestamptz;
        RETURN;
    END IF;

    -- Заблокирован после серии неудачных попыток
    IF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN
        INSERT INTO sec.login_attempts (username_attempted, user_id, succeeded, failure_reason, ip, user_agent)
        VALUES (p_username::citext, v_user.id, false, 'account_locked', p_ip, p_user_agent);

        INSERT INTO audit.security_events (kind, severity, target_user_id, ip, user_agent, succeeded, reason)
        VALUES ('login_failed', 'warning', v_user.id, p_ip, p_user_agent, false,
                'Вход при активной блокировке до ' || v_user.locked_until::text);

        RETURN QUERY SELECT false, 'account_locked', NULL::text, NULL::uuid, NULL::uuid,
                            NULL::text, NULL::text, NULL::text, false, false, v_user.locked_until;
        RETURN;
    END IF;

    IF NOT v_user.is_active THEN
        v_fail := 'account_inactive';
    ELSIF v_user.password_hash IS NULL THEN
        v_fail := 'password_not_set';
    ELSIF NOT sec.verify_password(p_password, v_user.password_hash) THEN
        v_fail := 'bad_password';
    END IF;

    IF v_fail IS NOT NULL THEN
        IF v_fail = 'bad_password' THEN
            UPDATE sec.users
               SET failed_login_attempts = failed_login_attempts + 1,
                   locked_until = CASE
                                    WHEN failed_login_attempts + 1 >= p.max_failed_attempts
                                    THEN now() + make_interval(mins => p.lockout_minutes)
                                    ELSE locked_until
                                  END
             WHERE id = v_user.id
             RETURNING failed_login_attempts INTO v_attempts;

            IF v_attempts >= p.max_failed_attempts THEN
                INSERT INTO audit.security_events (kind, severity, target_user_id, ip, user_agent, succeeded, reason, context)
                VALUES ('account_locked', 'critical', v_user.id, p_ip, p_user_agent, true,
                        'Превышено число неудачных попыток входа',
                        jsonb_build_object('attempts', v_attempts, 'lockout_minutes', p.lockout_minutes));
            END IF;
        END IF;

        INSERT INTO sec.login_attempts (username_attempted, user_id, succeeded, failure_reason, ip, user_agent)
        VALUES (p_username::citext, v_user.id, false, v_fail, p_ip, p_user_agent);

        INSERT INTO audit.security_events (kind, severity, target_user_id, ip, user_agent, succeeded, reason)
        VALUES ('login_failed', 'notice', v_user.id, p_ip, p_user_agent, false, v_fail);

        -- Наружу всегда одна и та же формулировка: подсказывать «такой логин есть,
        -- но пароль не тот» нельзя.
        RETURN QUERY SELECT false,
                            CASE WHEN v_fail = 'account_inactive' THEN 'account_inactive'
                                 ELSE 'invalid_credentials' END,
                            NULL::text, NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text,
                            false, false, NULL::timestamptz;
        RETURN;
    END IF;

    -- ---- Успешный вход ----
    v_token   := encode(gen_random_bytes(32), 'hex');
    v_expires := now() + make_interval(mins => p.session_ttl_minutes);

    INSERT INTO sec.auth_sessions (user_id, token_hash, issued_at, expires_at, ip, user_agent, mfa_passed)
    VALUES (v_user.id, digest(v_token, 'sha256'), now(), v_expires, p_ip, p_user_agent, NOT v_user.mfa_enabled)
    RETURNING id INTO v_session;

    UPDATE sec.users
       SET failed_login_attempts = 0,
           locked_until  = NULL,
           last_login_at = now(),
           last_login_ip = p_ip,
           last_seen_at  = now()
     WHERE id = v_user.id;

    INSERT INTO sec.login_attempts (username_attempted, user_id, succeeded, ip, user_agent)
    VALUES (p_username::citext, v_user.id, true, p_ip, p_user_agent);

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, ip, user_agent, session_id, succeeded, reason)
    VALUES ('login_success', 'info', v_user.id, v_user.id, p_ip, p_user_agent, v_session, true, 'Успешный вход');

    RETURN QUERY SELECT true,
                        CASE
                          WHEN v_user.must_change_password THEN 'password_change_required'
                          WHEN v_user.password_expires_at IS NOT NULL
                               AND v_user.password_expires_at < now() THEN 'password_expired'
                          ELSE 'ok'
                        END,
                        v_token, v_session, v_user.id, v_user.username::text, v_user.full_name,
                        v_user.role_code, v_user.must_change_password, v_user.mfa_enabled, v_expires;
END;
$$;

COMMENT ON FUNCTION sec.authenticate(text, text, inet, text)
    IS 'Единственная точка входа в систему. Никогда не бросает исключение при неверных данных — иначе откатывался бы счётчик попыток.';

-- Установка контекста запроса: после неё работают все RLS-политики.
CREATE OR REPLACE FUNCTION sec.begin_request(
    p_session_token text,
    p_ip            inet DEFAULT NULL,
    p_request_id    text DEFAULT NULL
)
RETURNS TABLE (user_id uuid, role_code text, full_name text, locale core.locale_code)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_session sec.auth_sessions%ROWTYPE;
    v_user    sec.users%ROWTYPE;
    p         sec.password_policy%ROWTYPE;
BEGIN
    SELECT * INTO p FROM sec.password_policy WHERE id = 1;

    SELECT * INTO v_session
      FROM sec.auth_sessions
     WHERE token_hash = digest(p_session_token, 'sha256')
       AND revoked_at IS NULL
       AND expires_at > now();

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Сессия недействительна или истекла' USING ERRCODE = '28000';
    END IF;

    -- Простой сессии дольше idle_timeout закрывает доступ: оставленный без присмотра
    -- компьютер в центре не должен оставаться открытой дверью.
    IF v_session.last_seen_at < now() - make_interval(mins => p.idle_timeout_minutes) THEN
        UPDATE sec.auth_sessions SET revoked_at = now(), revoked_reason = 'idle_timeout' WHERE id = v_session.id;
        INSERT INTO audit.security_events (kind, severity, target_user_id, session_id, succeeded, reason)
        VALUES ('session_revoked', 'notice', v_session.user_id, v_session.id, true, 'Бездействие дольше допустимого');
        RAISE EXCEPTION 'Сессия закрыта из-за бездействия' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v_user FROM sec.users WHERE id = v_session.user_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        UPDATE sec.auth_sessions SET revoked_at = now(), revoked_reason = 'user_deactivated' WHERE id = v_session.id;
        RAISE EXCEPTION 'Учётная запись отключена' USING ERRCODE = '28000';
    END IF;

    UPDATE sec.auth_sessions SET last_seen_at = now() WHERE id = v_session.id;
    UPDATE sec.users        SET last_seen_at = now() WHERE id = v_user.id;

    -- is_local = true: настройки живут до конца транзакции. Это обязательно при работе
    -- через пул соединений (PgBouncer), иначе контекст утечёт в чужой запрос.
    PERFORM set_config('app.current_user_id',    v_user.id::text,    true);
    PERFORM set_config('app.current_role_code',  v_user.role_code,   true);
    PERFORM set_config('app.current_session_id', v_session.id::text, true);
    PERFORM set_config('app.current_ip',         coalesce(p_ip::text, ''), true);
    PERFORM set_config('app.request_id',         coalesce(p_request_id, ''), true);

    RETURN QUERY SELECT v_user.id, v_user.role_code, v_user.full_name, v_user.locale;
END;
$$;

COMMENT ON FUNCTION sec.begin_request(text, inet, text)
    IS 'Вызывается в начале каждого запроса. Проверяет сессию и задаёт контекст для RLS.';

CREATE OR REPLACE FUNCTION sec.end_request()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('app.current_user_id',    '', true);
    PERFORM set_config('app.current_role_code',  '', true);
    PERFORM set_config('app.current_session_id', '', true);
    PERFORM set_config('app.current_ip',         '', true);
    PERFORM set_config('app.request_id',         '', true);
END;
$$;

CREATE OR REPLACE FUNCTION sec.logout(p_session_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, audit, pg_catalog, public
AS $$
DECLARE
    v_id   uuid;
    v_user uuid;
BEGIN
    UPDATE sec.auth_sessions
       SET revoked_at = now(), revoked_reason = 'logout'
     WHERE token_hash = digest(p_session_token, 'sha256')
       AND revoked_at IS NULL
    RETURNING id, user_id INTO v_id, v_user;

    IF v_id IS NULL THEN
        RETURN false;
    END IF;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, session_id, succeeded, reason)
    VALUES ('logout', 'info', v_user, v_user, v_id, true, 'Выход из системы');
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION sec.revoke_all_sessions(p_user_id uuid, p_actor_id uuid DEFAULT NULL, p_reason text DEFAULT 'admin_revoked')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, audit, pg_catalog, public
AS $$
DECLARE
    v_count integer;
BEGIN
    UPDATE sec.auth_sessions
       SET revoked_at = now(), revoked_reason = p_reason
     WHERE user_id = p_user_id AND revoked_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason, context)
    VALUES ('session_revoked', 'warning', p_actor_id, p_user_id, true, p_reason,
            jsonb_build_object('revoked_sessions', v_count));
    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION sec.unlock_user(p_user_id uuid, p_actor_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, audit, pg_catalog, public
AS $$
BEGIN
    UPDATE sec.users
       SET locked_until = NULL, failed_login_attempts = 0, updated_at = now(), updated_by = p_actor_id
     WHERE id = p_user_id;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason)
    VALUES ('account_unlocked', 'notice', p_actor_id, p_user_id, true, 'Блокировка снята администратором');
END;
$$;

-- ---- 11.2 Права и доступ к данным ребёнка ----------------------------------------------
--  Эти функции — основа RLS. Они SECURITY DEFINER и принадлежат eventum_secdef
--  (роль с BYPASSRLS): иначе проверка доступа сама попала бы под политику и зациклилась.

CREATE OR REPLACE FUNCTION sec.has_permission(p_permission_code text, p_user_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = sec, pg_catalog, public
AS $$
DECLARE
    v_user_id  uuid := coalesce(p_user_id, sec.current_user_id());
    v_override boolean;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN false;
    END IF;

    -- Персональное исключение важнее роли.
    SELECT is_granted INTO v_override
      FROM sec.user_permission_overrides
     WHERE user_id = v_user_id
       AND permission_code = p_permission_code
       AND (expires_at IS NULL OR expires_at > now());

    IF FOUND THEN
        RETURN v_override;
    END IF;

    RETURN EXISTS (
        SELECT 1
          FROM sec.users u
          JOIN sec.role_permissions rp ON rp.role_code = u.role_code
         WHERE u.id = v_user_id
           AND u.is_active
           AND u.deleted_at IS NULL
           AND rp.permission_code = p_permission_code
    );
END;
$$;

COMMENT ON FUNCTION sec.has_permission(text, uuid) IS 'Право роли с учётом персональных исключений';

CREATE OR REPLACE FUNCTION eventum.can_access_child(p_child_id uuid, p_user_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user_id uuid := coalesce(p_user_id, sec.current_user_id());
    v_user    sec.users%ROWTYPE;
BEGIN
    IF v_user_id IS NULL OR p_child_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT * INTO v_user FROM sec.users WHERE id = v_user_id AND is_active AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN false;
    END IF;

    -- 1. Администрация видит всех
    IF v_user.role_code IN ('admin', 'director') THEN
        RETURN true;
    END IF;

    -- 2. Родитель — только своих детей, и только пока связь действует
    IF v_user.role_code = 'parent' THEN
        RETURN EXISTS (
            SELECT 1
              FROM eventum.child_guardians cg
              JOIN eventum.guardians g ON g.id = cg.guardian_id
             WHERE cg.child_id = p_child_id
               AND g.user_id = v_user_id
               AND g.deleted_at IS NULL
               AND (cg.valid_until IS NULL OR cg.valid_until >= current_date)
        );
    END IF;

    -- 3. Куратор ребёнка
    IF EXISTS (SELECT 1 FROM eventum.children c WHERE c.id = p_child_id AND c.curator_id = v_user_id) THEN
        RETURN true;
    END IF;

    -- 4. Член междисциплинарной команды
    IF EXISTS (
        SELECT 1 FROM eventum.child_team_members t
         WHERE t.child_id = p_child_id AND t.user_id = v_user_id AND t.unassigned_at IS NULL
    ) THEN
        RETURN true;
    END IF;

    -- 5. Временный доступ, выданный по заявке
    IF EXISTS (
        SELECT 1 FROM eventum.access_requests ar
         WHERE ar.child_id = p_child_id AND ar.user_id = v_user_id
           AND ar.status = 'approved'
           AND (ar.granted_until IS NULL OR ar.granted_until > now())
    ) THEN
        RETURN true;
    END IF;

    -- 6. Сотрудник своего центра — только если роль это допускает.
    --    Заметьте: одного совпадения центра мало, нужно ещё право children.view_center.
    IF v_user.has_all_centers_access OR EXISTS (
        SELECT 1 FROM eventum.children c
         WHERE c.id = p_child_id
           AND c.center_id IS NOT NULL
           AND (c.center_id = v_user.primary_center_id
                OR EXISTS (SELECT 1 FROM eventum.user_centers uc
                            WHERE uc.user_id = v_user_id AND uc.center_id = c.center_id))
    ) THEN
        RETURN sec.has_permission('children.view_center', v_user_id);
    END IF;

    RETURN false;
END;
$$;

COMMENT ON FUNCTION eventum.can_access_child(uuid, uuid)
    IS 'Единое правило доступа к карте ребёнка. Используется во всех RLS-политиках рабочей части.';

CREATE OR REPLACE FUNCTION eventum.can_edit_child(p_child_id uuid, p_user_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user_id uuid := coalesce(p_user_id, sec.current_user_id());
    v_role    text;
BEGIN
    IF NOT eventum.can_access_child(p_child_id, v_user_id) THEN
        RETURN false;
    END IF;
    SELECT role_code INTO v_role FROM sec.users WHERE id = v_user_id;
    -- Родитель читает, но не правит карту.
    RETURN v_role IS DISTINCT FROM 'parent' AND sec.has_permission('children.edit', v_user_id);
END;
$$;

-- Проверка действующего согласия — вызывается перед любой публикацией.
CREATE OR REPLACE FUNCTION eventum.has_consent(p_child_id uuid, p_purpose core.consent_purpose)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = eventum, pg_catalog, public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM eventum.consents
         WHERE child_id = p_child_id
           AND purpose  = p_purpose
           AND is_granted
           AND revoked_at IS NULL
           AND (valid_until IS NULL OR valid_until > now())
    );
$$;

COMMENT ON FUNCTION eventum.has_consent(uuid, core.consent_purpose)
    IS 'Есть ли действующее согласие семьи. Без true публиковать фото, имя или историю нельзя.';

-- ---- 11.3 Операции рабочей части --------------------------------------------------------

-- Добавление записи о прогрессе + уведомления команде и родителям.
CREATE OR REPLACE FUNCTION eventum.add_progress_log(
    p_child_id   uuid,
    p_type_code  text,
    p_body       text,
    p_next_step  text DEFAULT NULL,
    p_goal_id    uuid DEFAULT NULL,
    p_session_id uuid DEFAULT NULL,
    p_visibility core.visibility_scope DEFAULT 'team',
    p_occurred_at timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, core, pg_catalog, public
AS $$
DECLARE
    v_author uuid := sec.current_user_id();
    v_log_id uuid;
    v_child  text;
BEGIN
    IF v_author IS NULL THEN
        RAISE EXCEPTION 'Нет контекста пользователя: сначала вызовите sec.begin_request()' USING ERRCODE = '28000';
    END IF;

    IF NOT eventum.can_access_child(p_child_id, v_author) THEN
        INSERT INTO audit.security_events (kind, severity, actor_user_id, succeeded, reason, context)
        VALUES ('permission_denied', 'warning', v_author, false, 'Попытка добавить запись к недоступному ребёнку',
                jsonb_build_object('child_id', p_child_id));
        RAISE EXCEPTION 'Нет доступа к карте ребёнка' USING ERRCODE = '42501';
    END IF;

    IF NOT sec.has_permission('logs.create', v_author) THEN
        RAISE EXCEPTION 'Недостаточно прав для создания записи' USING ERRCODE = '42501';
    END IF;

    SELECT display_name INTO v_child FROM eventum.children WHERE id = p_child_id;

    INSERT INTO eventum.progress_logs (child_id, session_id, goal_id, author_id, type_code, body, next_step,
                                       visibility, occurred_at)
    VALUES (p_child_id, p_session_id, p_goal_id, v_author, p_type_code, p_body, p_next_step,
            p_visibility, coalesce(p_occurred_at, now()))
    RETURNING id INTO v_log_id;

    -- Уведомляем команду ребёнка (кроме автора).
    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    SELECT t.user_id, 'new_log',
           'Новая запись: ' || coalesce(v_child, 'ребёнок'),
           left(p_body, 160),
           'progress_log', v_log_id
      FROM eventum.child_team_members t
     WHERE t.child_id = p_child_id
       AND t.unassigned_at IS NULL
       AND t.user_id <> v_author;

    -- Родителям — только если запись помечена как видимая семье.
    IF p_visibility = 'parents' THEN
        INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
        SELECT DISTINCT g.user_id, 'new_log',
               'Новая запись о ребёнке', left(p_body, 160), 'progress_log', v_log_id
          FROM eventum.child_guardians cg
          JOIN eventum.guardians g ON g.id = cg.guardian_id
         WHERE cg.child_id = p_child_id
           AND cg.can_view_reports
           AND g.user_id IS NOT NULL
           AND g.deleted_at IS NULL;
    END IF;

    RETURN v_log_id;
END;
$$;

COMMENT ON FUNCTION eventum.add_progress_log(uuid, text, text, text, uuid, uuid, core.visibility_scope, timestamptz)
    IS 'Добавление записи в дневник наблюдений с проверкой доступа и рассылкой уведомлений';

-- Сообщение в чат ребёнка: упоминания разбираются на сервере, а не в браузере.
CREATE OR REPLACE FUNCTION eventum.post_chat_message(
    p_child_id uuid,
    p_body     text,
    p_reply_to uuid DEFAULT NULL,
    p_document_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_author    uuid := sec.current_user_id();
    v_thread_id uuid;
    v_msg_id    uuid;
    v_author_name text;
BEGIN
    IF v_author IS NULL THEN
        RAISE EXCEPTION 'Нет контекста пользователя' USING ERRCODE = '28000';
    END IF;

    IF NOT eventum.can_access_child(p_child_id, v_author) THEN
        RAISE EXCEPTION 'Нет доступа к карте ребёнка' USING ERRCODE = '42501';
    END IF;

    SELECT coalesce(display_name, full_name) INTO v_author_name FROM sec.users WHERE id = v_author;

    -- Ветка чата создаётся один раз на ребёнка.
    SELECT id INTO v_thread_id FROM eventum.chat_threads WHERE child_id = p_child_id AND kind = 'child';
    IF v_thread_id IS NULL THEN
        INSERT INTO eventum.chat_threads (child_id, kind, created_by)
        VALUES (p_child_id, 'child', v_author)
        RETURNING id INTO v_thread_id;
    END IF;

    INSERT INTO eventum.chat_messages (thread_id, author_id, body, reply_to_id, document_id)
    VALUES (v_thread_id, v_author, p_body, p_reply_to, p_document_id)
    RETURNING id INTO v_msg_id;

    -- Упоминания: ищем участников команды, чьё имя встречается в тексте.
    INSERT INTO eventum.chat_mentions (message_id, user_id)
    SELECT DISTINCT v_msg_id, u.id
      FROM eventum.child_team_members t
      JOIN sec.users u ON u.id = t.user_id
     WHERE t.child_id = p_child_id
       AND t.unassigned_at IS NULL
       AND u.id <> v_author
       AND position(core.normalize_search(coalesce(u.display_name, u.full_name))
                    in core.normalize_search(p_body)) > 0
    ON CONFLICT DO NOTHING;

    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    SELECT m.user_id, 'mention',
           coalesce(v_author_name, 'Коллега') || ' упомянул(а) вас в чате',
           left(p_body, 160), 'chat_message', v_msg_id
      FROM eventum.chat_mentions m
     WHERE m.message_id = v_msg_id;

    RETURN v_msg_id;
END;
$$;

-- Отметка задачи выполненной / снятие отметки.
CREATE OR REPLACE FUNCTION eventum.set_task_done(p_task_id uuid, p_done boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user  uuid := sec.current_user_id();
    v_child uuid;
BEGIN
    SELECT child_id INTO v_child FROM eventum.child_tasks WHERE id = p_task_id;
    IF v_child IS NULL THEN
        RAISE EXCEPTION 'Задача не найдена' USING ERRCODE = 'P0002';
    END IF;
    IF NOT eventum.can_edit_child(v_child, v_user) THEN
        RAISE EXCEPTION 'Нет прав на изменение задач ребёнка' USING ERRCODE = '42501';
    END IF;

    UPDATE eventum.child_tasks
       SET is_done = p_done,
           done_at = CASE WHEN p_done THEN now() ELSE NULL END,
           done_by = CASE WHEN p_done THEN v_user ELSE NULL END,
           updated_at = now()
     WHERE id = p_task_id;
END;
$$;

-- Запись на занятие с проверкой доступности специалиста и отсутствия отпуска.
CREATE OR REPLACE FUNCTION eventum.schedule_session(
    p_child_id     uuid,
    p_specialist_id uuid,
    p_center_id    uuid,
    p_scheduled_at timestamptz,
    p_duration     smallint DEFAULT 45,
    p_format       core.session_format DEFAULT 'individual',
    p_program_id   uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    v_id   uuid;
BEGIN
    IF NOT sec.has_permission('sessions.manage', v_user) THEN
        RAISE EXCEPTION 'Недостаточно прав для работы с расписанием' USING ERRCODE = '42501';
    END IF;

    IF p_scheduled_at < now() - interval '1 day' THEN
        RAISE EXCEPTION 'Нельзя запланировать занятие задним числом более чем на сутки' USING ERRCODE = '22023';
    END IF;

    -- Отпуск, больничный, обучение
    IF EXISTS (
        SELECT 1 FROM eventum.staff_absences a
         WHERE a.user_id = p_specialist_id
           AND tstzrange(a.starts_at, a.ends_at) &&
               tstzrange(p_scheduled_at, p_scheduled_at + make_interval(mins => p_duration))
    ) THEN
        RAISE EXCEPTION 'Специалист отсутствует в это время (отпуск, больничный или обучение)' USING ERRCODE = '23P01';
    END IF;

    -- Пересечение с другим занятием ловит ограничение session_no_specialist_overlap,
    -- но понятное сообщение лучше выдать заранее.
    IF EXISTS (
        SELECT 1 FROM eventum.therapy_sessions s
         WHERE s.specialist_id = p_specialist_id
           AND s.status IN ('planned', 'confirmed', 'in_progress')
           AND tstzrange(s.scheduled_at, s.scheduled_at + make_interval(mins => s.duration_minutes)) &&
               tstzrange(p_scheduled_at, p_scheduled_at + make_interval(mins => p_duration))
    ) THEN
        RAISE EXCEPTION 'У специалиста уже есть занятие в это время' USING ERRCODE = '23P01';
    END IF;

    INSERT INTO eventum.therapy_sessions (center_id, program_id, specialist_id, primary_child_id,
                                          scheduled_at, duration_minutes, format, created_by)
    VALUES (p_center_id, p_program_id, p_specialist_id, p_child_id,
            p_scheduled_at, p_duration, p_format, v_user)
    RETURNING id INTO v_id;

    IF p_child_id IS NOT NULL THEN
        INSERT INTO eventum.session_attendees (session_id, child_id) VALUES (v_id, p_child_id)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_id;
END;
$$;

-- Заявка на согласование (кнопки «Запросить изменение» в портале).
CREATE OR REPLACE FUNCTION eventum.create_change_request(
    p_subject_type text,
    p_subject_id   uuid,
    p_subject_label text,
    p_title        text,
    p_detail       text DEFAULT NULL,
    p_payload      jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    v_id   uuid;
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'Нет контекста пользователя' USING ERRCODE = '28000';
    END IF;

    INSERT INTO eventum.change_requests (requested_by, subject_type, subject_id, subject_label,
                                         title, detail, payload)
    VALUES (v_user, p_subject_type, p_subject_id, p_subject_label, p_title, p_detail, p_payload)
    RETURNING id INTO v_id;

    -- Уведомляем всех, кто вправе согласовывать.
    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    SELECT u.id, 'approval_request', 'Новая заявка на согласование',
           p_title || coalesce(' — ' || p_subject_label, ''), 'change_request', v_id
      FROM sec.users u
     WHERE u.is_active AND u.deleted_at IS NULL
       AND sec.has_permission('approvals.decide', u.id);

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.decide_change_request(
    p_request_id uuid,
    p_approve    boolean,
    p_note       text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    v_req  eventum.change_requests%ROWTYPE;
BEGIN
    IF NOT sec.has_permission('approvals.decide', v_user) THEN
        RAISE EXCEPTION 'Недостаточно прав для согласования' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_req FROM eventum.change_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заявка не найдена' USING ERRCODE = 'P0002';
    END IF;
    IF v_req.status <> 'pending' THEN
        RAISE EXCEPTION 'Заявка уже обработана (статус: %)', v_req.status USING ERRCODE = '22023';
    END IF;
    IF v_req.requested_by = v_user THEN
        RAISE EXCEPTION 'Нельзя согласовать собственную заявку' USING ERRCODE = '42501';
    END IF;
    IF NOT p_approve AND coalesce(btrim(p_note), '') = '' THEN
        RAISE EXCEPTION 'При отклонении заявки нужно указать причину' USING ERRCODE = '22023';
    END IF;

    UPDATE eventum.change_requests
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END::core.request_status,
           decided_by = v_user, decided_at = now(), decision_note = p_note
     WHERE id = p_request_id;

    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    VALUES (v_req.requested_by, 'approval_decided',
            CASE WHEN p_approve THEN 'Заявка согласована' ELSE 'Заявка отклонена' END,
            coalesce(p_note, v_req.title), 'change_request', p_request_id);
END;
$$;

COMMENT ON FUNCTION eventum.decide_change_request(uuid, boolean, text)
    IS 'Решение по заявке. Согласовать собственную заявку нельзя — принцип четырёх глаз.';

-- Пересчёт прогресса ребёнка по достигнутым целям (вместо ручного числа из прототипа).
CREATE OR REPLACE FUNCTION eventum.calc_child_progress(p_child_id uuid)
RETURNS core.percent
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(
             (SELECT round(avg(g.progress_percent))::smallint
                FROM eventum.goals g
               WHERE g.child_id = p_child_id
                 AND g.deleted_at IS NULL
                 AND g.status IN ('in_progress', 'achieved')),
             (SELECT c.progress_override FROM eventum.children c WHERE c.id = p_child_id),
             0
           )::core.percent;
$$;

-- Фиксация согласия семьи.
CREATE OR REPLACE FUNCTION eventum.grant_consent(
    p_child_id    uuid,
    p_guardian_id uuid,
    p_purpose     core.consent_purpose,
    p_scope       text DEFAULT NULL,
    p_valid_until timestamptz DEFAULT NULL,
    p_document_id uuid DEFAULT NULL,
    p_method      text DEFAULT 'written'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    v_id   uuid;
BEGIN
    IF NOT sec.has_permission('consents.manage', v_user) THEN
        RAISE EXCEPTION 'Недостаточно прав для регистрации согласия' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.consents (child_id, guardian_id, purpose, scope, valid_until,
                                  document_id, collection_method, recorded_by)
    VALUES (p_child_id, p_guardian_id, p_purpose, p_scope, p_valid_until,
            p_document_id, p_method, v_user)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.revoke_consent(p_consent_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, site, pg_catalog, public
AS $$
DECLARE
    v_user  uuid := sec.current_user_id();
    v_child uuid;
BEGIN
    UPDATE eventum.consents
       SET revoked_at = now(), revoke_reason = p_reason, is_granted = false
     WHERE id = p_consent_id AND revoked_at IS NULL
    RETURNING child_id INTO v_child;

    IF v_child IS NULL THEN
        RAISE EXCEPTION 'Согласие не найдено или уже отозвано' USING ERRCODE = 'P0002';
    END IF;

    -- Отзыв согласия должен сразу убирать материалы с сайта, а не «когда-нибудь потом».
    UPDATE site.media_items SET is_published = false WHERE consent_id = p_consent_id;
    UPDATE site.news_posts  SET is_published = false WHERE consent_id = p_consent_id;
END;
$$;

COMMENT ON FUNCTION eventum.revoke_consent(uuid, text)
    IS 'Отзыв согласия немедленно снимает с публикации связанные фото и материалы';

-- Обезличивание карты ребёнка (право на удаление данных / истечение срока хранения).
CREATE OR REPLACE FUNCTION eventum.anonymize_child(p_child_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    v_code text;
BEGIN
    IF NOT sec.has_permission('children.erase', v_user) THEN
        RAISE EXCEPTION 'Недостаточно прав для обезличивания карты' USING ERRCODE = '42501';
    END IF;

    SELECT public_code INTO v_code FROM eventum.children WHERE id = p_child_id;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'Ребёнок не найден' USING ERRCODE = 'P0002';
    END IF;

    UPDATE eventum.children
       SET last_name = 'Удалено', first_name = v_code, middle_name = NULL,
           display_name = v_code,
           birth_date = NULL, iin_hash = NULL, home_address = NULL, citizenship = NULL,
           primary_diagnosis = NULL, diagnosis_notes = NULL, medical_notes = NULL,
           allergies = NULL, medications = NULL, special_needs = NULL,
           communication_notes = NULL, sensory_profile = NULL, behavior_plan = NULL,
           emergency_contact_name = NULL, emergency_contact_phone = NULL,
           notes = NULL, status = 'archived',
           anonymized_at = now(), updated_at = now(), updated_by = v_user
     WHERE id = p_child_id;

    -- Тексты записей и сообщений удаляются: статистика остаётся, персональные данные — нет.
    UPDATE eventum.progress_logs SET body = '[данные удалены]', next_step = NULL, deleted_at = now()
     WHERE child_id = p_child_id AND deleted_at IS NULL;

    UPDATE eventum.chat_messages m SET body = '[данные удалены]', deleted_at = now()
      FROM eventum.chat_threads t
     WHERE m.thread_id = t.id AND t.child_id = p_child_id AND m.deleted_at IS NULL;

    UPDATE eventum.documents SET deleted_at = now(), deleted_by = v_user
     WHERE child_id = p_child_id AND deleted_at IS NULL;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, succeeded, reason, context)
    VALUES ('data_export', 'critical', v_user, true, 'Обезличивание карты ребёнка',
            jsonb_build_object('public_code', v_code, 'reason', p_reason));
END;
$$;

COMMENT ON FUNCTION eventum.anonymize_child(uuid, text)
    IS 'Обезличивание вместо DELETE: связи и статистика сохраняются, персональные данные стираются';

-- ---- 11.4 Операции публичного сайта -----------------------------------------------------

CREATE SEQUENCE IF NOT EXISTS site.ticket_seq START 1;

CREATE OR REPLACE FUNCTION site.next_ticket_number(p_prefix text)
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
    -- Последовательность, а не random(): случайный номер рано или поздно повторится
    -- и упрётся в UNIQUE, а семья получит ошибку вместо принятой заявки.
    SELECT p_prefix || '-' || to_char(now(), 'YYYY') || '-' ||
           lpad(nextval('site.ticket_seq')::text, 6, '0');
$$;

COMMENT ON FUNCTION site.next_ticket_number(text)
    IS 'Номер обращения для семьи: ОБР-2026-000123. Уникальность гарантирует последовательность.';

CREATE OR REPLACE FUNCTION site.submit_contact_request(
    p_name    text,
    p_phone   text,
    p_topic   text,
    p_message text DEFAULT NULL,
    p_email   text DEFAULT NULL,
    p_locale  core.locale_code DEFAULT 'ru',
    p_consent boolean DEFAULT false,
    p_ip      inet DEFAULT NULL,
    p_user_agent text DEFAULT NULL,
    p_source_page text DEFAULT NULL,
    p_utm     jsonb DEFAULT '{}'::jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, sec, core, pg_catalog, public
AS $$
DECLARE
    v_ticket text := site.next_ticket_number('OBR');
    v_recent integer;
BEGIN
    IF NOT p_consent THEN
        RAISE EXCEPTION 'Без согласия на обработку данных заявка не принимается' USING ERRCODE = '22023';
    END IF;

    -- Простейшая защита от спама: не больше 3 заявок с одного адреса за 10 минут.
    IF p_ip IS NOT NULL THEN
        SELECT count(*) INTO v_recent
          FROM site.contact_requests
         WHERE ip = p_ip AND created_at > now() - interval '10 minutes';
        IF v_recent >= 3 THEN
            RAISE EXCEPTION 'Слишком много заявок подряд. Попробуйте позже.' USING ERRCODE = '53400';
        END IF;
    END IF;

    INSERT INTO site.contact_requests (ticket_number, name, phone, email, topic, message, locale,
                                       consent_given, ip, user_agent, source_page,
                                       utm_source, utm_medium, utm_campaign)
    VALUES (v_ticket, btrim(p_name), p_phone, p_email, p_topic, p_message, p_locale,
            true, p_ip, p_user_agent, p_source_page,
            p_utm ->> 'source', p_utm ->> 'medium', p_utm ->> 'campaign');

    RETURN v_ticket;
END;
$$;

COMMENT ON FUNCTION site.submit_contact_request(text, text, text, text, text, core.locale_code, boolean, inet, text, text, jsonb)
    IS 'Приём заявки с формы «Записаться на консультацию». Возвращает номер обращения.';

CREATE OR REPLACE FUNCTION site.submit_join_request(
    p_name         text,
    p_phone        text,
    p_kind         core.join_kind DEFAULT 'other',
    p_organization text DEFAULT NULL,
    p_message      text DEFAULT NULL,
    p_email        text DEFAULT NULL,
    p_locale       core.locale_code DEFAULT 'ru',
    p_consent      boolean DEFAULT false,
    p_ip           inet DEFAULT NULL,
    p_user_agent   text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, core, pg_catalog, public
AS $$
DECLARE
    v_ticket text := site.next_ticket_number('JOIN');
BEGIN
    IF NOT p_consent THEN
        RAISE EXCEPTION 'Без согласия на обработку данных заявка не принимается' USING ERRCODE = '22023';
    END IF;

    INSERT INTO site.join_requests (ticket_number, kind, name, phone, email, organization,
                                    message, locale, consent_given, ip, user_agent)
    VALUES (v_ticket, p_kind, btrim(p_name), p_phone, p_email, p_organization,
            p_message, p_locale, true, p_ip, p_user_agent);

    RETURN v_ticket;
END;
$$;

-- Создание пожертвования. Возвращает ссылку для оплаты и номер квитанции.
CREATE OR REPLACE FUNCTION site.create_donation(
    p_amount       numeric,
    p_currency     text DEFAULT 'USD',
    p_direction_code text DEFAULT NULL,
    p_donor_name   text DEFAULT NULL,
    p_donor_email  text DEFAULT NULL,
    p_visibility   core.donor_visibility DEFAULT 'public',
    p_message      text DEFAULT NULL,
    p_locale       core.locale_code DEFAULT 'ru',
    p_ip           inet DEFAULT NULL
)
RETURNS TABLE (donation_id uuid, reference_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, core, pg_catalog, public
AS $$
DECLARE
    v_ref       text := site.next_ticket_number('DON');
    v_direction uuid;
    v_id        uuid;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Сумма пожертвования должна быть больше нуля' USING ERRCODE = '22023';
    END IF;

    IF p_direction_code IS NOT NULL THEN
        SELECT id INTO v_direction FROM site.donation_directions WHERE code = p_direction_code AND is_active;
    END IF;

    -- Анонимное пожертвование: имя не сохраняем вовсе, а не «сохраняем и не показываем».
    INSERT INTO site.donations (reference_code, direction_id, amount, currency,
                                donor_name, donor_email, visibility, message, locale, ip, status)
    VALUES (v_ref, v_direction, p_amount, upper(p_currency)::core.currency_code,
            CASE WHEN p_visibility = 'anonymous' THEN NULL ELSE btrim(p_donor_name) END,
            p_donor_email, p_visibility, p_message, p_locale, p_ip, 'created')
    RETURNING id INTO v_id;

    RETURN QUERY SELECT v_id, v_ref;
END;
$$;

COMMENT ON FUNCTION site.create_donation(numeric, text, text, text, text, core.donor_visibility, text, core.locale_code, inet)
    IS 'Создаёт запись о пожертвовании ДО перехода к оплате. Реквизиты карты в базу не попадают.';

-- Подтверждение оплаты — вызывается обработчиком webhook платёжного провайдера.
CREATE OR REPLACE FUNCTION site.confirm_donation(
    p_reference_code text,
    p_provider       text,
    p_provider_payment_id text,
    p_paid_amount    numeric DEFAULT NULL,
    p_method         text DEFAULT NULL,
    p_card_last4     text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, core, pg_catalog, public
AS $$
DECLARE
    v_row site.donations%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM site.donations WHERE reference_code = p_reference_code FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Пожертвование % не найдено', p_reference_code USING ERRCODE = 'P0002';
    END IF;

    -- Повторный вызов webhook не должен создавать двойную оплату.
    IF v_row.status = 'succeeded' THEN
        RETURN false;
    END IF;

    IF p_paid_amount IS NOT NULL AND p_paid_amount <> v_row.amount THEN
        RAISE EXCEPTION 'Сумма платежа (%) не совпадает с заявленной (%)', p_paid_amount, v_row.amount
            USING ERRCODE = '22023';
    END IF;

    UPDATE site.donations
       SET status = 'succeeded', paid_at = now(),
           payment_provider = p_provider, provider_payment_id = p_provider_payment_id,
           payment_method = p_method, card_last4 = p_card_last4,
           updated_at = now()
     WHERE id = v_row.id;

    RETURN true;
END;
$$;

-- ---- 11.5 Документы: загрузка, чтение, удаление -----------------------------------------
--  Это серверная часть вкладки «Документы» в карточке ребёнка (documentDrop / documentGrid).
--  Приложение НЕ пишет в eventum.documents и eventum.document_chunks напрямую — только
--  через эти функции. Они проверяют права, размер, тип файла, считают контрольную сумму
--  и пишут в журнал доступа: кто и когда скачал медицинский документ ребёнка.
--
--  Два сценария:
--
--   А. Небольшой файл, одним запросом (обычный случай для панели):
--        SELECT eventum.upload_document(<ребёнок>, 'Заключение.pdf', 'application/pdf',
--                                       <bytea содержимого>, 'Заключение невролога', 'medical');
--
--   Б. Большой файл, кусками (видео занятия, докачка после обрыва):
--        SELECT eventum.document_begin_upload(...);         -- получаем id
--        SELECT eventum.document_write_chunk(id, 0, ...);   -- по 1 МБ
--        SELECT eventum.document_write_chunk(id, 1, ...);
--        SELECT * FROM eventum.document_finish_upload(id);  -- контрольная сумма и статус

CREATE OR REPLACE FUNCTION eventum.document_chunk_size()
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce((SELECT (value #>> '{}')::integer FROM site.settings WHERE key = 'document_chunk_bytes'),
                    1048576);   -- 1 МБ
$$;

CREATE OR REPLACE FUNCTION eventum.document_max_bytes()
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce((SELECT (value #>> '{}')::bigint FROM site.settings WHERE key = 'document_max_bytes'),
                    52428800);  -- 50 МБ — столько же, сколько обещает интерфейс портала
$$;

-- Может ли текущий пользователь читать этот документ.
--  Логика повторяет RLS-политику documents_select. Повтор здесь обязателен: функции ниже
--  объявлены SECURITY DEFINER и работают от роли с BYPASSRLS, то есть политики к ним не
--  применяются. Если не проверить доступ вручную, любой сотрудник скачает любой файл.
CREATE OR REPLACE FUNCTION eventum.can_read_document(p_document_id uuid, p_user_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user uuid := coalesce(p_user_id, sec.current_user_id());
    v_role text;
    d      eventum.documents%ROWTYPE;
BEGIN
    IF v_user IS NULL THEN
        RETURN false;
    END IF;

    SELECT * INTO d FROM eventum.documents WHERE id = p_document_id;
    IF NOT FOUND OR d.deleted_at IS NOT NULL THEN
        RETURN false;
    END IF;

    -- Недолитый или заражённый файл не отдаётся никому, включая администратора.
    IF d.upload_status <> 'stored' OR d.virus_scan_status NOT IN ('clean', 'skipped') THEN
        RETURN false;
    END IF;

    IF d.child_id IS NOT NULL AND NOT eventum.can_access_child(d.child_id, v_user) THEN
        RETURN false;
    END IF;

    SELECT role_code INTO v_role FROM sec.users WHERE id = v_user AND is_active AND deleted_at IS NULL;
    IF v_role IS NULL THEN
        RETURN false;
    END IF;

    IF d.visibility = 'admin_only' THEN
        RETURN v_role IN ('admin', 'director') OR d.uploaded_by = v_user;
    END IF;

    IF d.visibility = 'team' AND v_role = 'parent' THEN
        RETURN false;   -- рабочие документы команды родителю не показываем
    END IF;

    RETURN true;
END;
$$;

-- Запись в журнал доступа к персональным данным.
CREATE OR REPLACE FUNCTION eventum.log_document_access(p_document_id uuid, p_kind text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    d eventum.documents%ROWTYPE;
BEGIN
    SELECT * INTO d FROM eventum.documents WHERE id = p_document_id;

    INSERT INTO audit.data_access_log (actor_user_id, actor_role, subject_type, subject_id,
                                       subject_label, access_kind, legal_basis, ip, request_id)
    VALUES (sec.current_user_id(), sec.current_role_code(), 'document', p_document_id,
            coalesce(d.original_filename, '—'), p_kind,
            CASE WHEN d.child_id IS NOT NULL THEN 'Согласие законного представителя'
                 ELSE 'Трудовые обязанности' END,
            sec.current_ip(), sec.current_request_id());
END;
$$;

-- ---- Начало загрузки ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.document_begin_upload(
    p_child_id       uuid,
    p_filename       text,
    p_mime_type      text,
    p_declared_size  bigint DEFAULT NULL,
    p_title          text   DEFAULT NULL,
    p_category       core.document_category DEFAULT 'other',
    p_visibility     core.visibility_scope  DEFAULT 'team',
    p_description    text   DEFAULT NULL,
    p_session_id     uuid   DEFAULT NULL,
    p_replaces       uuid   DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, audit, pg_catalog, public
AS $$
DECLARE
    v_user    uuid := sec.current_user_id();
    v_id      uuid;
    v_version integer := 1;
    v_center  uuid;
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'Нет контекста пользователя: сначала вызовите sec.begin_request()' USING ERRCODE = '28000';
    END IF;

    IF NOT sec.has_permission('documents.upload', v_user) THEN
        RAISE EXCEPTION 'Недостаточно прав для загрузки файлов' USING ERRCODE = '42501';
    END IF;

    IF p_child_id IS NOT NULL AND NOT eventum.can_edit_child(p_child_id, v_user) THEN
        INSERT INTO audit.security_events (kind, severity, actor_user_id, succeeded, reason, context)
        VALUES ('permission_denied', 'warning', v_user, false, 'Загрузка файла в недоступную карту ребёнка',
                jsonb_build_object('child_id', p_child_id, 'filename', left(coalesce(p_filename,''), 120)));
        RAISE EXCEPTION 'Нет доступа к карте ребёнка' USING ERRCODE = '42501';
    END IF;

    IF p_declared_size IS NOT NULL AND p_declared_size > eventum.document_max_bytes() THEN
        RAISE EXCEPTION 'Файл больше допустимого размера (% МБ)',
              round(eventum.document_max_bytes() / 1048576.0, 1) USING ERRCODE = '22023';
    END IF;

    -- Новая версия прежнего документа
    IF p_replaces IS NOT NULL THEN
        SELECT version + 1 INTO v_version FROM eventum.documents WHERE id = p_replaces;
        IF v_version IS NULL THEN
            RAISE EXCEPTION 'Заменяемый документ не найден' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    SELECT center_id INTO v_center FROM eventum.children WHERE id = p_child_id;

    INSERT INTO eventum.documents (child_id, center_id, session_id, title, description, category,
                                   storage_kind, original_filename, mime_type, size_bytes,
                                   visibility, upload_status, version, replaces_document_id, uploaded_by)
    VALUES (p_child_id, v_center, p_session_id,
            coalesce(nullif(btrim(coalesce(p_title, '')), ''), p_filename),
            p_description, p_category,
            'database', p_filename, lower(btrim(p_mime_type)), p_declared_size,
            p_visibility, 'pending', v_version, p_replaces, v_user)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION eventum.document_begin_upload(uuid, text, text, bigint, text, core.document_category, core.visibility_scope, text, uuid, uuid)
    IS 'Заводит запись о файле до передачи содержимого. Проверяет права, размер и доступ к карте ребёнка.';

-- ---- Запись куска -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.document_write_chunk(
    p_document_id uuid,
    p_chunk_no    integer,
    p_data        bytea
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_user  uuid := sec.current_user_id();
    d       eventum.documents%ROWTYPE;
    v_total bigint;
BEGIN
    SELECT * INTO d FROM eventum.documents WHERE id = p_document_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Документ не найден' USING ERRCODE = 'P0002';
    END IF;
    IF d.uploaded_by <> v_user AND NOT sec.has_permission('documents.manage', v_user) THEN
        RAISE EXCEPTION 'Дописывать можно только собственную загрузку' USING ERRCODE = '42501';
    END IF;
    IF d.upload_status <> 'pending' THEN
        RAISE EXCEPTION 'Загрузка уже завершена (статус: %)', d.upload_status USING ERRCODE = '22023';
    END IF;
    IF p_data IS NULL OR octet_length(p_data) = 0 THEN
        RAISE EXCEPTION 'Пустой кусок файла' USING ERRCODE = '22023';
    END IF;

    INSERT INTO eventum.document_chunks (document_id, chunk_no, data)
    VALUES (p_document_id, p_chunk_no, p_data)
    ON CONFLICT (document_id, chunk_no) DO UPDATE SET data = EXCLUDED.data;

    SELECT coalesce(sum(c.byte_length), 0) INTO v_total
      FROM eventum.document_chunks c WHERE c.document_id = p_document_id;

    IF v_total > eventum.document_max_bytes() THEN
        RAISE EXCEPTION 'Превышен допустимый размер файла (% МБ)',
              round(eventum.document_max_bytes() / 1048576.0, 1) USING ERRCODE = '22023';
    END IF;

    UPDATE eventum.documents SET uploaded_bytes = v_total, updated_at = now() WHERE id = p_document_id;
    RETURN v_total;
END;
$$;

-- ---- Завершение загрузки -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.document_finish_upload(
    p_document_id      uuid,
    p_expected_sha256  bytea DEFAULT NULL
)
RETURNS TABLE (document_id uuid, size_bytes bigint, checksum_sha256 bytea, is_duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    v_user     uuid := sec.current_user_id();
    d          eventum.documents%ROWTYPE;
    v_size     bigint;
    v_checksum bytea;
    v_gaps     integer;
    v_dup      boolean;
BEGIN
    SELECT * INTO d FROM eventum.documents WHERE id = p_document_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Документ не найден' USING ERRCODE = 'P0002';
    END IF;
    IF d.uploaded_by <> v_user AND NOT sec.has_permission('documents.manage', v_user) THEN
        RAISE EXCEPTION 'Завершить может только автор загрузки' USING ERRCODE = '42501';
    END IF;
    IF d.upload_status = 'stored' THEN
        RETURN QUERY SELECT d.id, d.size_bytes, d.checksum_sha256, false;
        RETURN;
    END IF;

    -- Куски должны идти подряд с нуля: пропуск означает потерянный кусок.
    -- Таблица везде под псевдонимом: имена колонок совпадают с именами выходных
    -- параметров функции, и без квалификации PL/pgSQL не поймёт, о чём идёт речь.
    SELECT count(*) INTO v_gaps
      FROM generate_series(0, (SELECT max(mx.chunk_no) FROM eventum.document_chunks mx
                                WHERE mx.document_id = p_document_id)) AS g(n)
     WHERE NOT EXISTS (SELECT 1 FROM eventum.document_chunks c
                        WHERE c.document_id = p_document_id AND c.chunk_no = g.n);

    IF v_gaps IS NULL THEN
        UPDATE eventum.documents SET upload_status = 'failed' WHERE id = p_document_id;
        RAISE EXCEPTION 'Содержимое файла не передано' USING ERRCODE = '22023';
    END IF;
    IF v_gaps > 0 THEN
        RAISE EXCEPTION 'Потеряно кусков файла: %. Повторите загрузку.', v_gaps USING ERRCODE = '22023';
    END IF;

    SELECT sum(c.byte_length), digest(string_agg(c.data, ''::bytea ORDER BY c.chunk_no), 'sha256')
      INTO v_size, v_checksum
      FROM eventum.document_chunks c WHERE c.document_id = p_document_id;

    -- Если клиент прислал свою контрольную сумму — сверяем. Так ловится файл,
    -- побившийся по дороге, и подмена содержимого между кусками.
    IF p_expected_sha256 IS NOT NULL AND p_expected_sha256 <> v_checksum THEN
        UPDATE eventum.documents SET upload_status = 'failed' WHERE id = p_document_id;
        DELETE FROM eventum.document_chunks c WHERE c.document_id = p_document_id;
        RAISE EXCEPTION 'Контрольная сумма не совпала: файл повреждён при передаче' USING ERRCODE = '22023';
    END IF;

    v_dup := EXISTS (SELECT 1 FROM eventum.documents x
                      WHERE x.checksum_sha256 = v_checksum AND x.id <> p_document_id
                        AND x.deleted_at IS NULL);

    UPDATE eventum.documents
       SET size_bytes = v_size,
           uploaded_bytes = v_size,
           checksum_sha256 = v_checksum,
           upload_status = 'stored',
           -- Антивирус подключается отдельным сервисом; пока его нет, отмечаем skipped,
           -- иначе файл никогда не станет доступен для скачивания.
           virus_scan_status = CASE WHEN d.virus_scan_status = 'pending' THEN 'skipped'
                                    ELSE d.virus_scan_status END,
           updated_at = now()
     WHERE id = p_document_id;

    -- Прежняя версия документа помечается заменённой
    IF d.replaces_document_id IS NOT NULL THEN
        UPDATE eventum.documents
           SET deleted_at = now(), deleted_by = v_user, delete_reason = 'Заменён новой версией'
         WHERE id = d.replaces_document_id AND deleted_at IS NULL;
    END IF;

    -- Уведомляем команду ребёнка
    IF d.child_id IS NOT NULL THEN
        INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
        SELECT t.user_id, 'document_uploaded',
               'Новый документ: ' || (SELECT display_name FROM eventum.children WHERE id = d.child_id),
               d.original_filename, 'document', d.id
          FROM eventum.child_team_members t
         WHERE t.child_id = d.child_id AND t.unassigned_at IS NULL AND t.user_id <> v_user;
    END IF;

    PERFORM eventum.log_document_access(p_document_id, 'view');

    RETURN QUERY SELECT d.id, v_size, v_checksum, v_dup;
END;
$$;

-- ---- Загрузка одним вызовом (основной путь для панели) --------------------------------------
CREATE OR REPLACE FUNCTION eventum.upload_document(
    p_child_id   uuid,
    p_filename   text,
    p_mime_type  text,
    p_content    bytea,
    p_title      text DEFAULT NULL,
    p_category   core.document_category DEFAULT 'other',
    p_visibility core.visibility_scope  DEFAULT 'team',
    p_description text DEFAULT NULL,
    p_session_id uuid DEFAULT NULL
)
RETURNS TABLE (document_id uuid, size_bytes bigint, checksum_sha256 bytea, is_duplicate boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_id    uuid;
    v_chunk integer := eventum.document_chunk_size();
    v_size  bigint;
    i       integer;
BEGIN
    IF p_content IS NULL OR octet_length(p_content) = 0 THEN
        RAISE EXCEPTION 'Пустой файл' USING ERRCODE = '22023';
    END IF;
    v_size := octet_length(p_content);

    v_id := eventum.document_begin_upload(p_child_id, p_filename, p_mime_type, v_size,
                                          p_title, p_category, p_visibility, p_description, p_session_id);

    FOR i IN 0 .. ((v_size - 1) / v_chunk)::integer LOOP
        PERFORM eventum.document_write_chunk(v_id, i, substring(p_content from i * v_chunk + 1 for v_chunk));
    END LOOP;

    RETURN QUERY SELECT * FROM eventum.document_finish_upload(v_id);
END;
$$;

COMMENT ON FUNCTION eventum.upload_document(uuid, text, text, bytea, text, core.document_category, core.visibility_scope, text, uuid)
    IS 'Загрузка файла одним вызовом: то, что вызывает панель при перетаскивании файла в documentDrop';

-- ---- Чтение ----------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.document_download(p_document_id uuid)
RETURNS TABLE (filename text, mime_type text, size_bytes bigint, content bytea)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    d eventum.documents%ROWTYPE;
BEGIN
    IF NOT eventum.can_read_document(p_document_id) THEN
        INSERT INTO audit.security_events (kind, severity, actor_user_id, succeeded, reason, context)
        VALUES ('permission_denied', 'warning', sec.current_user_id(), false,
                'Попытка скачать недоступный документ', jsonb_build_object('document_id', p_document_id));
        -- Одна формулировка и для отсутствующего, и для закрытого документа:
        -- иначе по тексту ошибки можно перебором выяснить, какие файлы существуют.
        RAISE EXCEPTION 'Документ не найден или недоступен' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO d FROM eventum.documents WHERE id = p_document_id;

    IF d.storage_kind <> 'database' THEN
        RAISE EXCEPTION 'Файл хранится в объектном хранилище: запросите подписанную ссылку по ключу %/%',
              d.storage_bucket, d.storage_key USING ERRCODE = '0A000';
    END IF;

    UPDATE eventum.documents
       SET download_count = download_count + 1, last_downloaded_at = now()
     WHERE id = p_document_id;

    PERFORM eventum.log_document_access(p_document_id, 'download');

    RETURN QUERY
    SELECT d.original_filename, d.mime_type, d.size_bytes,
           (SELECT string_agg(c.data, ''::bytea ORDER BY c.chunk_no)
              FROM eventum.document_chunks c WHERE c.document_id = p_document_id);
END;
$$;

COMMENT ON FUNCTION eventum.document_download(uuid)
    IS 'Выдача файла с проверкой прав и записью в журнал доступа к персональным данным';

-- Чтение по кускам — для больших файлов и потоковой отдачи.
CREATE OR REPLACE FUNCTION eventum.document_read_chunk(p_document_id uuid, p_chunk_no integer)
RETURNS bytea
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_data bytea;
BEGIN
    IF NOT eventum.can_read_document(p_document_id) THEN
        -- Одна формулировка и для отсутствующего, и для закрытого документа:
        -- иначе по тексту ошибки можно перебором выяснить, какие файлы существуют.
        RAISE EXCEPTION 'Документ не найден или недоступен' USING ERRCODE = '42501';
    END IF;

    SELECT data INTO v_data FROM eventum.document_chunks
     WHERE document_id = p_document_id AND chunk_no = p_chunk_no;

    -- В журнал пишем один раз на файл, а не на каждый кусок.
    IF p_chunk_no = 0 THEN
        UPDATE eventum.documents
           SET download_count = download_count + 1, last_downloaded_at = now()
         WHERE id = p_document_id;
        PERFORM eventum.log_document_access(p_document_id, 'download');
    END IF;

    RETURN v_data;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.document_chunk_count(p_document_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_count integer;
BEGIN
    IF NOT eventum.can_read_document(p_document_id) THEN
        -- Одна формулировка и для отсутствующего, и для закрытого документа:
        -- иначе по тексту ошибки можно перебором выяснить, какие файлы существуют.
        RAISE EXCEPTION 'Документ не найден или недоступен' USING ERRCODE = '42501';
    END IF;
    SELECT count(*) INTO v_count FROM eventum.document_chunks c WHERE c.document_id = p_document_id;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION eventum.document_chunk_count(uuid)
    IS 'Сколько кусков у файла — чтобы приложение знало, сколько раз вызвать document_read_chunk()';

-- ---- Внешнее хранилище (S3 / MinIO) ------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.register_external_document(
    p_child_id   uuid,
    p_filename   text,
    p_mime_type  text,
    p_bucket     text,
    p_key        text,
    p_size       bigint,
    p_checksum   bytea,
    p_title      text DEFAULT NULL,
    p_category   core.document_category DEFAULT 'other',
    p_visibility core.visibility_scope  DEFAULT 'team'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    v_id   uuid;
BEGIN
    IF NOT sec.has_permission('documents.upload', v_user) THEN
        RAISE EXCEPTION 'Недостаточно прав для загрузки файлов' USING ERRCODE = '42501';
    END IF;
    IF p_child_id IS NOT NULL AND NOT eventum.can_edit_child(p_child_id, v_user) THEN
        RAISE EXCEPTION 'Нет доступа к карте ребёнка' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.documents (child_id, title, description, category, storage_kind,
                                   storage_bucket, storage_key, original_filename, mime_type,
                                   size_bytes, checksum_sha256, upload_status, uploaded_bytes,
                                   is_encrypted, visibility, uploaded_by)
    VALUES (p_child_id, coalesce(p_title, p_filename), NULL, p_category, 'object_storage',
            p_bucket, p_key, p_filename, lower(btrim(p_mime_type)),
            p_size, p_checksum, 'stored', p_size, true, p_visibility, v_user)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ---- Антивирусная проверка ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.document_set_scan_result(
    p_document_id uuid,
    p_status      text,
    p_note        text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, audit, sec, pg_catalog, public
AS $$
BEGIN
    IF p_status NOT IN ('clean', 'infected', 'failed', 'skipped') THEN
        RAISE EXCEPTION 'Недопустимый результат проверки: %', p_status USING ERRCODE = '22023';
    END IF;

    UPDATE eventum.documents
       SET virus_scan_status = p_status,
           virus_scanned_at  = now(),
           virus_scan_note   = p_note,
           upload_status     = CASE WHEN p_status = 'infected' THEN 'quarantined' ELSE upload_status END
     WHERE id = p_document_id;

    IF p_status = 'infected' THEN
        -- Заражённый файл стираем сразу: держать его в базе незачем.
        DELETE FROM eventum.document_chunks WHERE document_id = p_document_id;
        INSERT INTO audit.security_events (kind, severity, actor_user_id, succeeded, reason, context)
        VALUES ('suspicious_activity', 'critical', sec.current_user_id(), true,
                'Загруженный файл заражён и удалён', jsonb_build_object('document_id', p_document_id));
    END IF;
END;
$$;

-- ---- Удаление -----------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.document_delete(
    p_document_id uuid,
    p_reason      text,
    p_purge       boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    v_user uuid := sec.current_user_id();
    d      eventum.documents%ROWTYPE;
BEGIN
    SELECT * INTO d FROM eventum.documents WHERE id = p_document_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Документ не найден' USING ERRCODE = 'P0002';
    END IF;

    IF d.uploaded_by <> v_user AND NOT sec.has_permission('documents.manage', v_user) THEN
        RAISE EXCEPTION 'Удалить документ может автор загрузки или администратор' USING ERRCODE = '42501';
    END IF;

    IF coalesce(btrim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'Укажите причину удаления документа' USING ERRCODE = '22023';
    END IF;

    -- Скан подписанного согласия удалять нельзя: это юридическое основание обработки данных.
    IF EXISTS (SELECT 1 FROM eventum.consents c
                WHERE c.document_id = p_document_id AND c.revoked_at IS NULL) THEN
        RAISE EXCEPTION 'Документ приложен к действующему согласию семьи и не может быть удалён'
            USING ERRCODE = '23503';
    END IF;

    UPDATE eventum.documents
       SET deleted_at = now(), deleted_by = v_user, delete_reason = p_reason
     WHERE id = p_document_id;

    -- По умолчанию содержимое остаётся: удаление в интерфейсе обратимо, а срок хранения
    -- документов у фонда свой. Полное стирание — только явным p_purge.
    IF p_purge THEN
        IF NOT sec.has_permission('documents.manage', v_user) THEN
            RAISE EXCEPTION 'Полное стирание файла доступно только администратору' USING ERRCODE = '42501';
        END IF;
        DELETE FROM eventum.document_chunks WHERE document_id = p_document_id;
    END IF;

    PERFORM eventum.log_document_access(p_document_id, 'export');
END;
$$;

-- ---- Уборка недогруженных файлов --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION eventum.purge_stale_uploads(p_hours integer DEFAULT 24)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, pg_catalog, public
AS $$
DECLARE
    v_count integer;
BEGIN
    -- Пользователь закрыл вкладку на середине загрузки — куски остались висеть.
    DELETE FROM eventum.document_chunks c
     USING eventum.documents d
     WHERE d.id = c.document_id
       AND d.upload_status = 'pending'
       AND d.uploaded_at < now() - make_interval(hours => p_hours);

    DELETE FROM eventum.documents
     WHERE upload_status = 'pending'
       AND uploaded_at < now() - make_interval(hours => p_hours);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION eventum.purge_stale_uploads(integer)
    IS 'Убирает файлы, загрузка которых оборвалась. Ставится в ежедневный планировщик.';

-- ---- 11.6 Остальные операции админ-панели -------------------------------------------------
--  Всё, что панель умеет менять, проходит через функции: они проверяют право, соблюдают
--  бизнес-правило и оставляют след в журнале. Прямой INSERT/UPDATE в таблицы приложению
--  формально доступен (RLS его ограничит), но правильный путь — эти вызовы.

-- ===== Пользователи =====
CREATE OR REPLACE FUNCTION sec.create_user(
    p_username    text,
    p_last_name   text,
    p_first_name  text,
    p_role_code   text,
    p_middle_name text DEFAULT NULL,
    p_display_name text DEFAULT NULL,
    p_job_title   text DEFAULT NULL,
    p_email       text DEFAULT NULL,
    p_phone       text DEFAULT NULL,
    p_center_code text DEFAULT NULL,
    p_all_centers boolean DEFAULT false,
    p_initial_password text DEFAULT NULL,
    p_locale      core.locale_code DEFAULT 'ru'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, eventum, core, audit, pg_catalog, public
AS $$
DECLARE
    v_actor  uuid := sec.current_user_id();
    v_center uuid;
    v_rank   smallint;
    v_my_rank smallint;
    v_id     uuid;
BEGIN
    IF NOT sec.has_permission('users.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав для создания пользователей' USING ERRCODE = '42501';
    END IF;

    SELECT rank INTO v_rank FROM sec.roles WHERE code = p_role_code;
    IF v_rank IS NULL THEN
        RAISE EXCEPTION 'Неизвестная роль: %', p_role_code USING ERRCODE = '22023';
    END IF;

    -- Нельзя выдать роль выше собственной: иначе куратор с правом на пользователей
    -- заведёт себе второго администратора и обойдёт все ограничения.
    SELECT r.rank INTO v_my_rank FROM sec.users u JOIN sec.roles r ON r.code = u.role_code
     WHERE u.id = v_actor;
    IF v_my_rank IS NOT NULL AND v_rank < v_my_rank THEN
        RAISE EXCEPTION 'Нельзя назначить роль с полномочиями выше собственных' USING ERRCODE = '42501';
    END IF;

    IF p_center_code IS NOT NULL THEN
        SELECT id INTO v_center FROM eventum.centers WHERE code = p_center_code;
    END IF;

    INSERT INTO sec.users (username, last_name, first_name, middle_name, display_name, job_title,
                           email, phone, role_code, primary_center_id, has_all_centers_access,
                           locale, must_change_password, created_by)
    VALUES (p_username, btrim(p_last_name), btrim(p_first_name), p_middle_name,
            coalesce(p_display_name, btrim(p_first_name) || ' ' || left(btrim(p_last_name), 1) || '.'),
            p_job_title, p_email::core.email, p_phone::core.phone, p_role_code, v_center,
            p_all_centers, p_locale, true, v_actor)
    RETURNING id INTO v_id;

    IF p_initial_password IS NOT NULL THEN
        PERFORM sec.set_password(v_id, p_initial_password, v_actor, 'initial', sec.current_ip(), true);
    END IF;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason, context)
    VALUES ('role_changed', 'notice', v_actor, v_id, true, 'Создана учётная запись',
            jsonb_build_object('username', p_username, 'role', p_role_code));

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION sec.create_user(text, text, text, text, text, text, text, text, text, text, boolean, text, core.locale_code)
    IS 'Экран «Пользователи» → кнопка добавления. Без пароля учётная запись создаётся заблокированной для входа.';

CREATE OR REPLACE FUNCTION sec.set_user_active(p_user_id uuid, p_active boolean, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, audit, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
BEGIN
    IF NOT sec.has_permission('users.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав' USING ERRCODE = '42501';
    END IF;
    IF p_user_id = v_actor AND NOT p_active THEN
        RAISE EXCEPTION 'Нельзя отключить собственную учётную запись' USING ERRCODE = '22023';
    END IF;

    UPDATE sec.users
       SET is_active = p_active,
           deactivated_at = CASE WHEN p_active THEN NULL ELSE now() END,
           deactivation_reason = CASE WHEN p_active THEN NULL ELSE p_reason END,
           updated_by = v_actor
     WHERE id = p_user_id;

    -- Отключили сотрудника — его открытые сессии должны закрыться немедленно.
    IF NOT p_active THEN
        PERFORM sec.revoke_all_sessions(p_user_id, v_actor, 'user_deactivated');
    END IF;

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason)
    VALUES (CASE WHEN p_active THEN 'user_activated' ELSE 'user_deactivated' END::core.security_event_kind,
            'warning', v_actor, p_user_id, true, coalesce(p_reason, '—'));
END;
$$;

CREATE OR REPLACE FUNCTION sec.change_user_role(p_user_id uuid, p_role_code text, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, audit, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_old   text;
BEGIN
    IF NOT sec.has_permission('users.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав' USING ERRCODE = '42501';
    END IF;
    IF p_user_id = v_actor THEN
        RAISE EXCEPTION 'Нельзя менять роль самому себе' USING ERRCODE = '42501';
    END IF;

    SELECT role_code INTO v_old FROM sec.users WHERE id = p_user_id;
    UPDATE sec.users SET role_code = p_role_code, updated_by = v_actor WHERE id = p_user_id;
    PERFORM sec.revoke_all_sessions(p_user_id, v_actor, 'admin_revoked');

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason, context)
    VALUES ('role_changed', 'critical', v_actor, p_user_id, true, p_reason,
            jsonb_build_object('from', v_old, 'to', p_role_code));
END;
$$;

-- ===== Дети и семьи =====
CREATE OR REPLACE FUNCTION eventum.create_child(
    p_last_name   text,
    p_first_name  text,
    p_birth_date  date DEFAULT NULL,
    p_center_code text DEFAULT NULL,
    p_curator_id  uuid DEFAULT NULL,
    p_middle_name text DEFAULT NULL,
    p_status      core.child_status DEFAULT 'active',
    p_notes       text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_actor  uuid := sec.current_user_id();
    v_center uuid;
    v_id     uuid;
BEGIN
    IF NOT sec.has_permission('children.create', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав для создания карты ребёнка' USING ERRCODE = '42501';
    END IF;

    IF p_center_code IS NOT NULL THEN
        SELECT id INTO v_center FROM eventum.centers WHERE code = p_center_code AND is_active;
        IF v_center IS NULL THEN
            RAISE EXCEPTION 'Центр % не найден', p_center_code USING ERRCODE = 'P0002';
        END IF;
    END IF;

    INSERT INTO eventum.children (last_name, first_name, middle_name, birth_date, center_id,
                                  curator_id, status, notes, created_by)
    VALUES (btrim(p_last_name), btrim(p_first_name), p_middle_name, p_birth_date, v_center,
            coalesce(p_curator_id, v_actor), p_status, p_notes, v_actor)
    RETURNING id INTO v_id;

    -- Куратор сразу становится членом команды — иначе он потеряет доступ к карте,
    -- как только его снимут с роли куратора этого ребёнка.
    INSERT INTO eventum.child_team_members (child_id, user_id, role_in_team, assigned_by)
    VALUES (v_id, coalesce(p_curator_id, v_actor), 'curator', v_actor)
    ON CONFLICT DO NOTHING;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.assign_team_member(
    p_child_id  uuid,
    p_user_id   uuid,
    p_role      text DEFAULT 'specialist',
    p_program_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_id    uuid;
BEGIN
    IF NOT sec.has_permission('team.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав для изменения состава команды' USING ERRCODE = '42501';
    END IF;
    IF NOT eventum.can_access_child(p_child_id, v_actor) THEN
        RAISE EXCEPTION 'Нет доступа к карте ребёнка' USING ERRCODE = '42501';
    END IF;
    IF (SELECT role_code FROM sec.users WHERE id = p_user_id) = 'parent' THEN
        RAISE EXCEPTION 'Родителя нельзя добавить в команду специалистов' USING ERRCODE = '22023';
    END IF;

    INSERT INTO eventum.child_team_members (child_id, user_id, role_in_team, program_id, assigned_by)
    VALUES (p_child_id, p_user_id, p_role, p_program_id, v_actor)
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_id;

    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    VALUES (p_user_id, 'task_assigned', 'Вас добавили в команду ребёнка',
            (SELECT display_name FROM eventum.children WHERE id = p_child_id), 'child', p_child_id);

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.unassign_team_member(p_child_id uuid, p_user_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
BEGIN
    IF NOT sec.has_permission('team.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав' USING ERRCODE = '42501';
    END IF;

    UPDATE eventum.child_team_members
       SET unassigned_at = now(), unassign_reason = p_reason
     WHERE child_id = p_child_id AND user_id = p_user_id AND unassigned_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.add_guardian(
    p_child_id   uuid,
    p_last_name  text,
    p_first_name text,
    p_relation   text,
    p_phone      text DEFAULT NULL,
    p_email      text DEFAULT NULL,
    p_middle_name text DEFAULT NULL,
    p_is_legal   boolean DEFAULT true,
    p_portal_user_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_id    uuid;
BEGIN
    IF NOT eventum.can_edit_child(p_child_id, v_actor) THEN
        RAISE EXCEPTION 'Нет прав на изменение карты ребёнка' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.guardians (user_id, last_name, first_name, middle_name, phone, email)
    VALUES (p_portal_user_id, btrim(p_last_name), btrim(p_first_name), p_middle_name,
            p_phone::core.phone, p_email::core.email)
    RETURNING id INTO v_id;

    INSERT INTO eventum.child_guardians (child_id, guardian_id, relation, is_legal_representative)
    VALUES (p_child_id, v_id, p_relation, p_is_legal);

    RETURN v_id;
END;
$$;

-- ===== Цели и задачи =====
CREATE OR REPLACE FUNCTION eventum.create_goal(
    p_child_id   uuid,
    p_title      text,
    p_domain     text DEFAULT NULL,
    p_target_criteria text DEFAULT NULL,
    p_baseline   text DEFAULT NULL,
    p_due_on     date DEFAULT NULL,
    p_priority   smallint DEFAULT 3,
    p_program_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_id    uuid;
BEGIN
    IF NOT sec.has_permission('goals.manage', v_actor) OR NOT eventum.can_edit_child(p_child_id, v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав для работы с целями ребёнка' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.goals (child_id, program_id, title, domain, target_criteria, baseline,
                               due_on, priority, status, started_on, created_by)
    VALUES (p_child_id, p_program_id, btrim(p_title), p_domain, p_target_criteria, p_baseline,
            p_due_on, p_priority, 'in_progress', current_date, v_actor)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.update_goal_progress(
    p_goal_id  uuid,
    p_percent  smallint,
    p_note     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_child uuid;
BEGIN
    SELECT child_id INTO v_child FROM eventum.goals WHERE id = p_goal_id;
    IF v_child IS NULL THEN
        RAISE EXCEPTION 'Цель не найдена' USING ERRCODE = 'P0002';
    END IF;
    IF NOT eventum.can_edit_child(v_child, v_actor) THEN
        RAISE EXCEPTION 'Нет прав на изменение целей ребёнка' USING ERRCODE = '42501';
    END IF;

    UPDATE eventum.goals
       SET progress_percent = p_percent,
           status = CASE WHEN p_percent >= 100 THEN 'achieved'::core.goal_status ELSE status END,
           achieved_at = CASE WHEN p_percent >= 100 AND achieved_at IS NULL THEN now() ELSE achieved_at END,
           updated_by = v_actor
     WHERE id = p_goal_id;

    -- Замер сохраняем отдельно: по нему потом строится динамика, а не одно текущее число.
    INSERT INTO eventum.goal_measurements (goal_id, value, unit, note, recorded_by)
    VALUES (p_goal_id, p_percent, 'percent', p_note, v_actor);
END;
$$;

CREATE OR REPLACE FUNCTION eventum.add_task(
    p_child_id uuid,
    p_text     text,
    p_goal_id  uuid DEFAULT NULL,
    p_due_on   date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_id    uuid;
BEGIN
    IF NOT eventum.can_edit_child(p_child_id, v_actor) THEN
        RAISE EXCEPTION 'Нет прав на изменение задач ребёнка' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.child_tasks (child_id, goal_id, text, due_on, created_by,
                                     sort_order)
    VALUES (p_child_id, p_goal_id, btrim(p_text), p_due_on, v_actor,
            coalesce((SELECT max(sort_order) + 10 FROM eventum.child_tasks WHERE child_id = p_child_id), 10))
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ===== Занятия =====
CREATE OR REPLACE FUNCTION eventum.set_session_status(
    p_session_id uuid,
    p_status     core.session_status,
    p_summary    text DEFAULT NULL,
    p_reason     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    ses     eventum.therapy_sessions%ROWTYPE;
BEGIN
    SELECT * INTO ses FROM eventum.therapy_sessions WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Занятие не найдено' USING ERRCODE = 'P0002';
    END IF;
    IF ses.specialist_id <> v_actor AND NOT sec.has_permission('sessions.manage', v_actor) THEN
        RAISE EXCEPTION 'Менять статус занятия может ведущий специалист или администратор' USING ERRCODE = '42501';
    END IF;
    IF p_status = 'cancelled' AND coalesce(btrim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'При отмене занятия нужно указать причину' USING ERRCODE = '22023';
    END IF;

    UPDATE eventum.therapy_sessions
       SET status = p_status,
           summary = coalesce(p_summary, summary),
           actual_start_at = CASE WHEN p_status = 'in_progress' AND actual_start_at IS NULL
                                  THEN now() ELSE actual_start_at END,
           actual_end_at   = CASE WHEN p_status = 'completed' THEN now() ELSE actual_end_at END,
           cancel_reason   = CASE WHEN p_status = 'cancelled' THEN p_reason ELSE cancel_reason END,
           cancelled_by    = CASE WHEN p_status = 'cancelled' THEN v_actor ELSE cancelled_by END,
           cancelled_at    = CASE WHEN p_status = 'cancelled' THEN now() ELSE cancelled_at END,
           updated_by      = v_actor
     WHERE id = p_session_id;

    -- Отменённое занятие освобождает время специалиста, поэтому семью надо предупредить.
    IF p_status = 'cancelled' AND ses.primary_child_id IS NOT NULL THEN
        INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
        SELECT DISTINCT g.user_id, 'session_changed', 'Занятие отменено',
               coalesce(p_reason, 'Причина не указана'), 'session', p_session_id
          FROM eventum.child_guardians cg
          JOIN eventum.guardians g ON g.id = cg.guardian_id
         WHERE cg.child_id = ses.primary_child_id AND g.user_id IS NOT NULL AND g.deleted_at IS NULL;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.mark_attendance(
    p_session_id uuid,
    p_child_id   uuid,
    p_attendance core.attendance_status,
    p_note       text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
BEGIN
    IF NOT eventum.can_access_child(p_child_id, v_actor) THEN
        RAISE EXCEPTION 'Нет доступа к карте ребёнка' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.session_attendees (session_id, child_id, attendance, arrived_at, note)
    VALUES (p_session_id, p_child_id, p_attendance,
            CASE WHEN p_attendance IN ('present', 'late') THEN now() END, p_note)
    ON CONFLICT (session_id, child_id) DO UPDATE
       SET attendance = EXCLUDED.attendance,
           arrived_at = EXCLUDED.arrived_at,
           note       = EXCLUDED.note;
END;
$$;

-- ===== Заявки на доступ (кнопка requestAccess) =====
CREATE OR REPLACE FUNCTION eventum.request_access(
    p_child_id      uuid,
    p_justification text,
    p_days          integer DEFAULT 14
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_id    uuid;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Нет контекста пользователя' USING ERRCODE = '28000';
    END IF;
    IF coalesce(btrim(p_justification), '') = '' THEN
        RAISE EXCEPTION 'Укажите, зачем нужен доступ к карте ребёнка' USING ERRCODE = '22023';
    END IF;
    IF (SELECT role_code FROM sec.users WHERE id = v_actor) = 'parent' THEN
        RAISE EXCEPTION 'Родителю доступ к чужим картам не выдаётся' USING ERRCODE = '42501';
    END IF;
    IF eventum.can_access_child(p_child_id, v_actor) THEN
        RAISE EXCEPTION 'Доступ к этой карте у вас уже есть' USING ERRCODE = '22023';
    END IF;

    INSERT INTO eventum.access_requests (user_id, child_id, justification, granted_until)
    VALUES (v_actor, p_child_id, p_justification, now() + make_interval(days => p_days))
    RETURNING id INTO v_id;

    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    SELECT u.id, 'approval_request', 'Запрос доступа к карте ребёнка',
           sec.user_display_name(v_actor) || ': ' || left(p_justification, 120), 'access_request', v_id
      FROM sec.users u
     WHERE u.is_active AND u.deleted_at IS NULL AND sec.has_permission('approvals.decide', u.id);

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eventum.decide_access_request(
    p_request_id uuid,
    p_approve    boolean,
    p_note       text DEFAULT NULL,
    p_days       integer DEFAULT 14
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, audit, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    req     eventum.access_requests%ROWTYPE;
BEGIN
    IF NOT sec.has_permission('approvals.decide', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав для решения по заявке' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO req FROM eventum.access_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND OR req.status <> 'pending' THEN
        RAISE EXCEPTION 'Заявка не найдена или уже обработана' USING ERRCODE = '22023';
    END IF;
    IF req.user_id = v_actor THEN
        RAISE EXCEPTION 'Нельзя согласовать собственную заявку' USING ERRCODE = '42501';
    END IF;

    UPDATE eventum.access_requests
       SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END::core.request_status,
           decided_by = v_actor, decided_at = now(), decision_note = p_note,
           -- Доступ всегда временный: постоянный никто никогда не отзовёт.
           granted_until = CASE WHEN p_approve THEN now() + make_interval(days => p_days) END
     WHERE id = p_request_id;

    INSERT INTO eventum.notifications (user_id, kind, title, body, entity_type, entity_id)
    VALUES (req.user_id, 'approval_decided',
            CASE WHEN p_approve THEN 'Доступ открыт' ELSE 'В доступе отказано' END,
            coalesce(p_note, '—'), 'access_request', p_request_id);

    INSERT INTO audit.security_events (kind, severity, actor_user_id, target_user_id, succeeded, reason, context)
    VALUES ('permission_denied', CASE WHEN p_approve THEN 'warning' ELSE 'info' END,
            v_actor, req.user_id, true,
            CASE WHEN p_approve THEN 'Выдан временный доступ к карте ребёнка'
                 ELSE 'Отказано в доступе к карте ребёнка' END,
            jsonb_build_object('child_id', req.child_id, 'days', p_days));
END;
$$;

-- ===== Уведомления =====
CREATE OR REPLACE FUNCTION eventum.mark_notifications_read(p_ids uuid[] DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_count integer;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'Нет контекста пользователя' USING ERRCODE = '28000';
    END IF;

    UPDATE eventum.notifications
       SET is_read = true, read_at = now()
     WHERE user_id = v_actor
       AND NOT is_read
       AND (p_ids IS NULL OR id = ANY (p_ids));
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION eventum.mark_notifications_read(uuid[])
    IS 'Кнопка «Отметить всё прочитанным». Без списка идентификаторов помечает все свои непрочитанные.';

-- ===== Центры =====
CREATE OR REPLACE FUNCTION eventum.upsert_center(
    p_code     text,
    p_name     text,
    p_address  text,
    p_city     text DEFAULT 'Актобе',
    p_capacity integer DEFAULT NULL,
    p_phone    text DEFAULT NULL,
    p_age_from smallint DEFAULT NULL,
    p_age_to   smallint DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, core, pg_catalog, public
AS $$
DECLARE
    v_id uuid;
BEGIN
    IF NOT sec.has_permission('centers.manage', sec.current_user_id()) THEN
        RAISE EXCEPTION 'Недостаточно прав для управления центрами' USING ERRCODE = '42501';
    END IF;

    INSERT INTO eventum.centers (code, name, address, city, capacity, phone, age_from, age_to)
    VALUES (p_code, p_name, p_address, p_city, p_capacity, p_phone::core.phone, p_age_from, p_age_to)
    ON CONFLICT (code) DO UPDATE
       SET name = EXCLUDED.name, address = EXCLUDED.address, city = EXCLUDED.city,
           capacity = EXCLUDED.capacity, phone = EXCLUDED.phone,
           age_from = EXCLUDED.age_from, age_to = EXCLUDED.age_to, updated_at = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ===== Заявки с сайта: работа администратора =====
CREATE OR REPLACE FUNCTION site.set_lead_status(
    p_ticket_number text,
    p_status        core.lead_status,
    p_note          text DEFAULT NULL,
    p_assign_to     uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, sec, core, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
    v_found integer;
BEGIN
    IF NOT sec.has_permission('leads.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав для работы с заявками' USING ERRCODE = '42501';
    END IF;

    UPDATE site.contact_requests
       SET status = p_status,
           internal_note = coalesce(p_note, internal_note),
           assigned_to = coalesce(p_assign_to, assigned_to, v_actor),
           handled_at = CASE WHEN p_status IN ('done', 'rejected', 'spam') THEN now() ELSE handled_at END
     WHERE ticket_number = p_ticket_number;
    GET DIAGNOSTICS v_found = ROW_COUNT;

    IF v_found = 0 THEN
        UPDATE site.join_requests
           SET status = p_status,
               internal_note = coalesce(p_note, internal_note),
               assigned_to = coalesce(p_assign_to, assigned_to, v_actor),
               handled_at = CASE WHEN p_status IN ('done', 'rejected', 'spam') THEN now() ELSE handled_at END
         WHERE ticket_number = p_ticket_number;
        GET DIAGNOSTICS v_found = ROW_COUNT;
    END IF;

    RETURN v_found > 0;
END;
$$;

CREATE OR REPLACE FUNCTION site.verify_donation(p_reference_code text, p_verified boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = site, sec, pg_catalog, public
AS $$
DECLARE
    v_actor uuid := sec.current_user_id();
BEGIN
    IF NOT sec.has_permission('donations.manage', v_actor) THEN
        RAISE EXCEPTION 'Недостаточно прав' USING ERRCODE = '42501';
    END IF;

    -- Пока пожертвование не подтверждено вручную, имя донора на сайте не появится.
    UPDATE site.donations
       SET is_verified = p_verified,
           verified_by = CASE WHEN p_verified THEN v_actor END,
           verified_at = CASE WHEN p_verified THEN now() END
     WHERE reference_code = p_reference_code;
END;
$$;

-- =====================================================================================
--  РАЗДЕЛ 12. ТРИГГЕРЫ
-- =====================================================================================

\echo '>>> [12] Триггеры...'

-- ---- 12.1 updated_at ------------------------------------------------------------------
--  Ставится автоматически на каждую таблицу, где есть колонка updated_at.
DO $upd$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.table_schema, c.table_name
          FROM information_schema.columns c
          JOIN information_schema.tables t
            ON t.table_schema = c.table_schema AND t.table_name = c.table_name
         WHERE c.column_name = 'updated_at'
           AND c.table_schema IN ('sec', 'eventum', 'site')
           AND t.table_type = 'BASE TABLE'
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_set_updated_at ON %I.%I', r.table_schema, r.table_name);
        EXECUTE format(
            'CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON %I.%I
             FOR EACH ROW EXECUTE FUNCTION core.tg_set_updated_at()',
            r.table_schema, r.table_name);
    END LOOP;
END
$upd$;

-- ---- 12.2 Универсальный аудит изменений ------------------------------------------------
CREATE OR REPLACE FUNCTION audit.tg_log_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, sec, pg_catalog, public
AS $$
DECLARE
    v_old     jsonb;
    v_new     jsonb;
    v_changed jsonb;
    v_label   text;
    v_id      text;
    v_label_col text := TG_ARGV[0];
BEGIN
    IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW); END IF;

    -- Секреты в журнал не попадают ни при каких условиях.
    v_old := v_old - 'password_hash' - 'mfa_secret_encrypted' - 'token_hash'
                   - 'refresh_token_hash' - 'code_hash' - 'iin_hash';
    v_new := v_new - 'password_hash' - 'mfa_secret_encrypted' - 'token_hash'
                   - 'refresh_token_hash' - 'code_hash' - 'iin_hash';

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(key, value) INTO v_changed
          FROM jsonb_each(v_new)
         WHERE v_old -> key IS DISTINCT FROM value;

        -- Пустой UPDATE журналировать незачем.
        IF v_changed IS NULL OR v_changed = '{}'::jsonb THEN
            RETURN NULL;
        END IF;
    END IF;

    v_id := coalesce(v_new ->> 'id', v_old ->> 'id');
    IF v_label_col IS NOT NULL THEN
        v_label := coalesce(v_new ->> v_label_col, v_old ->> v_label_col);
    END IF;

    INSERT INTO audit.activity_log (
        actor_user_id, actor_role, actor_ip, session_id, request_id,
        action, entity_schema, entity_table, entity_id, entity_label,
        old_data, new_data, changed_fields
    )
    VALUES (
        sec.current_user_id(), sec.current_role_code(), sec.current_ip(),
        sec.current_session_id(), sec.current_request_id(),
        lower(TG_OP), TG_TABLE_SCHEMA, TG_TABLE_NAME, v_id, v_label,
        v_old, v_new, v_changed
    );

    RETURN NULL;   -- AFTER-триггер: возвращаемое значение не используется
END;
$$;

COMMENT ON FUNCTION audit.tg_log_row_change() IS 'Универсальный аудит: пишет было/стало, вырезая хеши и секреты';

-- Навешиваем аудит на таблицы с чувствительными или юридически значимыми данными.
DO $audit_attach$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('sec',     'users',                'username'),
            ('sec',     'roles',                'code'),
            ('sec',     'role_permissions',     NULL),
            ('sec',     'user_permission_overrides', NULL),
            ('eventum', 'children',             'display_name'),
            ('eventum', 'guardians',            'full_name'),
            ('eventum', 'child_guardians',      NULL),
            ('eventum', 'child_team_members',   NULL),
            ('eventum', 'consents',             NULL),
            ('eventum', 'goals',                'title'),
            ('eventum', 'progress_logs',        NULL),
            ('eventum', 'documents',            'title'),
            ('eventum', 'therapy_sessions',     NULL),
            ('eventum', 'change_requests',      'subject_label'),
            ('eventum', 'access_requests',      NULL),
            ('site',    'donations',            'reference_code'),
            ('site',    'public_reports',       NULL),
            ('site',    'settings',             'key')
        ) AS t(sch, tbl, label_col)
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables
                    WHERE table_schema = r.sch AND table_name = r.tbl) THEN
            EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON %I.%I', r.sch, r.tbl);
            IF r.label_col IS NULL THEN
                EXECUTE format(
                    'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                     FOR EACH ROW EXECUTE FUNCTION audit.tg_log_row_change()', r.sch, r.tbl);
            ELSE
                EXECUTE format(
                    'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                     FOR EACH ROW EXECUTE FUNCTION audit.tg_log_row_change(%L)', r.sch, r.tbl, r.label_col);
            END IF;
        END IF;
    END LOOP;
END
$audit_attach$;

-- ---- 12.3 Запрет физического удаления данных о детях ------------------------------------
--  Карту ребёнка нельзя удалить командой DELETE: только обезличивание через функцию.
--  Иначе одна опечатка в WHERE стирает историю работы с семьёй без следа.
DROP TRIGGER IF EXISTS trg_children_no_delete      ON eventum.children;
DROP TRIGGER IF EXISTS trg_progress_logs_no_delete ON eventum.progress_logs;

CREATE TRIGGER trg_children_no_delete
    BEFORE DELETE ON eventum.children
    FOR EACH ROW EXECUTE FUNCTION core.tg_forbid_delete();

CREATE TRIGGER trg_progress_logs_no_delete
    BEFORE DELETE ON eventum.progress_logs
    FOR EACH ROW EXECUTE FUNCTION core.tg_forbid_delete();

-- ---- 12.4 Пересчёт прогресса ребёнка при изменении целей ---------------------------------
CREATE OR REPLACE FUNCTION eventum.tg_refresh_child_progress()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_child uuid := coalesce(NEW.child_id, OLD.child_id);
BEGIN
    -- Цель считается достигнутой → фиксируем дату автоматически.
    IF TG_OP = 'UPDATE' AND NEW.status = 'achieved' AND OLD.status <> 'achieved' AND NEW.achieved_at IS NULL THEN
        UPDATE eventum.goals SET achieved_at = now(), progress_percent = 100 WHERE id = NEW.id;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_goals_progress ON eventum.goals;
CREATE TRIGGER trg_goals_progress
    AFTER UPDATE OF status ON eventum.goals
    FOR EACH ROW EXECUTE FUNCTION eventum.tg_refresh_child_progress();

-- ---- 12.5 Автоматический public_code для ребёнка ------------------------------------------
CREATE SEQUENCE IF NOT EXISTS eventum.child_code_seq START 1;

CREATE OR REPLACE FUNCTION eventum.tg_child_public_code()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.public_code IS NULL OR btrim(NEW.public_code) = '' THEN
        NEW.public_code := 'EV-' || lpad(nextval('eventum.child_code_seq')::text, 5, '0');
    END IF;
    IF NEW.display_name IS NULL OR btrim(NEW.display_name) = '' THEN
        -- «Айсулу К.» — имя и первая буква фамилии, как в интерфейсе портала
        NEW.display_name := NEW.first_name || ' ' || left(NEW.last_name, 1) || '.';
    END IF;
    IF NEW.birth_year IS NULL AND NEW.birth_date IS NOT NULL THEN
        NEW.birth_year := extract(year FROM NEW.birth_date)::smallint;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_child_public_code ON eventum.children;
CREATE TRIGGER trg_child_public_code
    BEFORE INSERT ON eventum.children
    FOR EACH ROW EXECUTE FUNCTION eventum.tg_child_public_code();

-- ---- 12.6 Время окончания занятия ---------------------------------------------------------
--  Колонка ends_at нужна ограничению session_no_specialist_overlap: индексное выражение
--  обязано быть IMMUTABLE, а сложение timestamptz с интервалом таковым не является.
CREATE OR REPLACE FUNCTION eventum.tg_session_ends_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.ends_at := NEW.scheduled_at + make_interval(mins => NEW.duration_minutes);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_session_ends_at ON eventum.therapy_sessions;
CREATE TRIGGER trg_session_ends_at
    BEFORE INSERT OR UPDATE OF scheduled_at, duration_minutes ON eventum.therapy_sessions
    FOR EACH ROW EXECUTE FUNCTION eventum.tg_session_ends_at();

-- ---- 12.7 Ветка чата заводится вместе с ребёнком --------------------------------------------
CREATE OR REPLACE FUNCTION eventum.tg_create_child_thread()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO eventum.chat_threads (child_id, kind, created_by)
    VALUES (NEW.id, 'child', NEW.created_by)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_child_thread ON eventum.children;
CREATE TRIGGER trg_child_thread
    AFTER INSERT ON eventum.children
    FOR EACH ROW EXECUTE FUNCTION eventum.tg_create_child_thread();

-- ---- 12.8 Запрет на публикацию без согласия ---------------------------------------------------
CREATE OR REPLACE FUNCTION site.tg_check_publication_consent()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_published AND NEW.depicts_child_id IS NOT NULL THEN
        IF NOT eventum.has_consent(NEW.depicts_child_id, 'photo_publication') THEN
            RAISE EXCEPTION
                'Нельзя опубликовать материал: у семьи нет действующего согласия на публикацию фотографий'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_media_consent ON site.media_items;
CREATE TRIGGER trg_media_consent
    BEFORE INSERT OR UPDATE OF is_published, depicts_child_id ON site.media_items
    FOR EACH ROW EXECUTE FUNCTION site.tg_check_publication_consent();

COMMENT ON FUNCTION site.tg_check_publication_consent()
    IS 'Техническая гарантия обещания сайта: «публикуем события только с соблюдением согласий семей»';

-- =====================================================================================
--  РАЗДЕЛ 13. ПРЕДСТАВЛЕНИЯ — по одному на экран портала
-- =====================================================================================
--  Представления не отменяют RLS: политики применяются к таблицам под ними, а условия
--  строятся на app.current_user_id. Каждый видит ровно свою часть данных.
-- =====================================================================================

\echo '>>> [13] Представления...'

-- ---- Имя сотрудника для представлений -----------------------------------------------------
--  Представления не должны делать JOIN к sec.users: на этой таблице стоит RLS, и родитель
--  видит в ней только собственную строку. Обычный JOIN молча выбросил бы у него все записи
--  и документы — вместе с фамилией специалиста, который их создал. Эти две функции отдают
--  ровно два безобидных поля: как показывать человека и кем он работает.

CREATE OR REPLACE FUNCTION sec.user_display_name(p_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = sec, pg_catalog, public
AS $$
    SELECT coalesce(u.display_name, u.full_name) FROM sec.users u WHERE u.id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION sec.user_job_title(p_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = sec, pg_catalog, public
AS $$
    SELECT u.job_title FROM sec.users u WHERE u.id = p_user_id;
$$;

COMMENT ON FUNCTION sec.user_display_name(uuid)
    IS 'Отображаемое имя сотрудника. Больше ничего из карточки пользователя не раскрывает.';

-- ---- Карточка ребёнка со сводкой (view-children, childGrid) ------------------------------
CREATE OR REPLACE VIEW eventum.v_children_overview AS
SELECT
    c.id,
    c.public_code,
    c.display_name,
    c.last_name,
    c.first_name,
    c.birth_year,
    core.age_years(c.birth_date)                        AS age_years,
    c.status,
    c.center_id,
    ce.name                                             AS center_name,
    c.curator_id,
    sec.user_display_name(c.curator_id)                 AS curator_name,
    eventum.calc_child_progress(c.id)                   AS progress_percent,
    (SELECT count(*) FROM eventum.child_team_members t
      WHERE t.child_id = c.id AND t.unassigned_at IS NULL)          AS team_size,
    (SELECT count(*) FROM eventum.goals g
      WHERE g.child_id = c.id AND g.deleted_at IS NULL
        AND g.status = 'in_progress')                               AS active_goals,
    (SELECT count(*) FROM eventum.child_tasks ct
      WHERE ct.child_id = c.id AND NOT ct.is_done)                  AS open_tasks,
    (SELECT max(pl.occurred_at) FROM eventum.progress_logs pl
      WHERE pl.child_id = c.id AND pl.deleted_at IS NULL)           AS last_log_at,
    (SELECT min(s.scheduled_at) FROM eventum.therapy_sessions s
      WHERE s.primary_child_id = c.id
        AND s.status IN ('planned', 'confirmed')
        AND s.scheduled_at > now())                                 AS next_session_at,
    c.enrolled_on,
    c.created_at
FROM eventum.children c
LEFT JOIN eventum.centers ce ON ce.id = c.center_id
WHERE c.deleted_at IS NULL;

COMMENT ON VIEW eventum.v_children_overview IS 'Сетка детей на экране «Дети» со сводкой по команде, целям и занятиям';

-- ---- Документы ребёнка (вкладка documentGrid) ---------------------------------------------
CREATE OR REPLACE VIEW eventum.v_child_documents AS
SELECT
    d.id,
    d.child_id,
    c.display_name        AS child_name,
    d.title,
    d.original_filename,
    d.mime_type,
    d.size_bytes,
    round(d.size_bytes / 1048576.0, 2) AS size_mb,
    d.category,
    d.visibility,
    d.version,
    d.storage_kind,
    d.virus_scan_status,
    d.download_count,
    d.last_downloaded_at,
    d.uploaded_at,
    d.uploaded_by,
    sec.user_display_name(d.uploaded_by) AS uploaded_by_name,
    (d.mime_type LIKE 'image/%') AS is_image,
    (d.mime_type LIKE 'video/%') AS is_video,
    encode(d.checksum_sha256, 'hex') AS checksum_hex
FROM eventum.documents d
LEFT JOIN eventum.children c ON c.id = d.child_id
WHERE d.deleted_at IS NULL
  AND d.upload_status = 'stored'
  AND d.virus_scan_status IN ('clean', 'skipped')
ORDER BY d.uploaded_at DESC;

COMMENT ON VIEW eventum.v_child_documents
    IS 'Сетка документов в карточке ребёнка. Недогруженные и заражённые файлы сюда не попадают.';

-- ---- Расписание на сегодня (todaySchedule) ------------------------------------------------
CREATE OR REPLACE VIEW eventum.v_today_schedule AS
SELECT
    s.id,
    s.scheduled_at,
    to_char(s.scheduled_at AT TIME ZONE 'Asia/Aqtobe', 'HH24:MI') AS time_label,
    s.duration_minutes,
    s.format,
    s.status,
    s.room,
    c.id             AS child_id,
    c.display_name   AS child_name,
    ce.id            AS center_id,
    ce.name          AS center_name,
    s.specialist_id,
    sec.user_display_name(s.specialist_id) AS specialist_name,
    p.code           AS program_code
FROM eventum.therapy_sessions s
LEFT JOIN eventum.children c  ON c.id  = s.primary_child_id
JOIN      eventum.centers  ce ON ce.id = s.center_id
LEFT JOIN eventum.programs p  ON p.id  = s.program_id
WHERE s.scheduled_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Aqtobe')
  AND s.scheduled_at <  date_trunc('day', now() AT TIME ZONE 'Asia/Aqtobe') + interval '1 day';

-- ---- Сводка для дашборда (metrics) ----------------------------------------------------------
CREATE OR REPLACE VIEW eventum.v_dashboard_metrics AS
SELECT
    (SELECT count(*) FROM eventum.children
      WHERE status = 'active' AND deleted_at IS NULL)                       AS active_children,
    (SELECT count(*) FROM eventum.therapy_sessions
      WHERE scheduled_at::date = current_date)                              AS sessions_today,
    (SELECT count(*) FROM eventum.therapy_sessions
      WHERE scheduled_at::date = current_date AND status = 'completed')     AS sessions_completed_today,
    (SELECT count(*) FROM eventum.change_requests WHERE status = 'pending') AS pending_approvals,
    (SELECT count(*) FROM eventum.progress_logs
      WHERE occurred_at > now() - interval '7 days' AND deleted_at IS NULL) AS logs_last_7_days,
    (SELECT count(*) FROM eventum.children
      WHERE status = 'waitlist' AND deleted_at IS NULL)                     AS waitlist_children,
    (SELECT count(*) FROM sec.users
      WHERE is_active AND deleted_at IS NULL)                               AS active_users,
    (SELECT count(*) FROM eventum.documents
      WHERE uploaded_at > now() - interval '30 days' AND deleted_at IS NULL) AS documents_last_30_days,
    (SELECT count(*) FROM site.contact_requests
      WHERE status = 'new' AND deleted_at IS NULL)                          AS new_contact_requests;

COMMENT ON VIEW eventum.v_dashboard_metrics IS 'Плитки на главном экране портала';

-- ---- Лента последних записей ------------------------------------------------------------------
CREATE OR REPLACE VIEW eventum.v_recent_logs AS
SELECT
    l.id,
    l.occurred_at,
    l.child_id,
    c.display_name AS child_name,
    l.author_id,
    sec.user_display_name(l.author_id) AS author_name,
    sec.user_job_title(l.author_id)    AS author_role,
    l.type_code,
    lt.name_ru     AS type_name,
    l.body,
    l.next_step,
    l.visibility,
    l.is_incident
FROM eventum.progress_logs l
JOIN eventum.children  c  ON c.id = l.child_id
JOIN eventum.log_types lt ON lt.code = l.type_code
WHERE l.deleted_at IS NULL
ORDER BY l.occurred_at DESC;

-- ---- Очередь согласований ----------------------------------------------------------------------
CREATE OR REPLACE VIEW eventum.v_pending_change_requests AS
SELECT
    r.id,
    r.created_at,
    r.requested_by,
    sec.user_display_name(r.requested_by) AS requester_name,
    left(sec.user_display_name(r.requested_by), 1) AS requester_initial,
    r.subject_type,
    r.subject_label,
    r.title,
    r.detail,
    r.priority,
    r.payload,
    age(now(), r.created_at) AS waiting_for
FROM eventum.change_requests r
WHERE r.status = 'pending'
ORDER BY r.priority, r.created_at;

-- ---- Загрузка центров -------------------------------------------------------------------------
CREATE OR REPLACE VIEW eventum.v_center_load AS
SELECT
    ce.id,
    ce.code,
    ce.name,
    ce.address,
    ce.capacity,
    (SELECT count(*) FROM eventum.children c
      WHERE c.center_id = ce.id AND c.status = 'active' AND c.deleted_at IS NULL) AS active_children,
    (SELECT count(DISTINCT u.id) FROM sec.users u
      WHERE u.primary_center_id = ce.id AND u.is_active AND u.deleted_at IS NULL) AS staff_count,
    (SELECT count(*) FROM eventum.therapy_sessions s
      WHERE s.center_id = ce.id AND s.scheduled_at::date = current_date)          AS sessions_today,
    CASE WHEN ce.capacity IS NULL OR ce.capacity = 0 THEN NULL
         ELSE round(100.0 * (SELECT count(*) FROM eventum.children c
                              WHERE c.center_id = ce.id AND c.status = 'active'
                                AND c.deleted_at IS NULL) / ce.capacity, 1)
    END AS load_percent
FROM eventum.centers ce
WHERE ce.is_active;

-- ---- Справочник сотрудников (view-users) ---------------------------------------------------------
CREATE OR REPLACE VIEW sec.v_user_directory AS
SELECT
    u.id,
    u.username,
    u.full_name,
    u.display_name,
    u.job_title,
    u.email,
    u.phone,
    u.role_code,
    r.name_ru       AS role_name,
    u.primary_center_id,
    ce.name         AS center_name,
    u.has_all_centers_access,
    u.is_active,
    u.mfa_enabled,
    u.last_login_at,
    u.last_seen_at,
    (u.locked_until IS NOT NULL AND u.locked_until > now())          AS is_locked,
    (u.password_hash IS NULL)                                        AS password_not_set,
    (u.password_expires_at IS NOT NULL AND u.password_expires_at < now()) AS password_expired,
    u.must_change_password,
    (SELECT count(*) FROM sec.auth_sessions s
      WHERE s.user_id = u.id AND s.revoked_at IS NULL AND s.expires_at > now()) AS active_sessions,
    u.created_at
FROM sec.users u
JOIN sec.roles r ON r.code = u.role_code
LEFT JOIN eventum.centers ce ON ce.id = u.primary_center_id
WHERE u.deleted_at IS NULL;

COMMENT ON VIEW sec.v_user_directory
    IS 'Экран «Пользователи». Хеши паролей и секреты 2FA здесь отсутствуют по построению.';

-- ---- Журнал для экрана «Аудит» ---------------------------------------------------------------------
CREATE OR REPLACE VIEW audit.v_recent_activity AS
SELECT
    a.occurred_at,
    coalesce(a.actor_username, u.display_name, u.full_name, '—') AS actor_name,
    a.actor_role,
    a.action,
    a.entity_table,
    coalesce(a.entity_label, a.entity_id, '—')                   AS object_label,
    a.actor_ip                                                   AS ip,
    a.success,
    a.changed_fields
FROM audit.activity_log a
LEFT JOIN sec.users u ON u.id = a.actor_user_id
ORDER BY a.occurred_at DESC;

-- ---- Панель безопасности --------------------------------------------------------------------------
--  Считается SECURITY DEFINER-функцией, а не обычным представлением. Причина: служба
--  безопасности подключается ролью eventum_auditor напрямую, без входа в портал, и без
--  контекста пользователя RLS вернул бы ей нули вместо реальных цифр. Наружу отдаются
--  только агрегаты — ни одной строки с персональными данными.
CREATE OR REPLACE FUNCTION audit.security_dashboard()
RETURNS TABLE (
    locked_accounts          bigint,
    failed_logins_24h        bigint,
    distinct_failing_ips_24h bigint,
    active_sessions          bigint,
    users_without_password   bigint,
    expired_passwords        bigint,
    admins_without_mfa       bigint,
    critical_events_7d       bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = audit, sec, pg_catalog, public
AS $$
SELECT
    (SELECT count(*) FROM sec.users
      WHERE locked_until > now() AND deleted_at IS NULL)                       AS locked_accounts,
    (SELECT count(*) FROM sec.login_attempts
      WHERE NOT succeeded AND attempted_at > now() - interval '24 hours')      AS failed_logins_24h,
    (SELECT count(DISTINCT ip) FROM sec.login_attempts
      WHERE NOT succeeded AND attempted_at > now() - interval '24 hours')      AS distinct_failing_ips_24h,
    (SELECT count(*) FROM sec.auth_sessions
      WHERE revoked_at IS NULL AND expires_at > now())                         AS active_sessions,
    (SELECT count(*) FROM sec.users
      WHERE password_hash IS NULL AND is_active AND deleted_at IS NULL)        AS users_without_password,
    (SELECT count(*) FROM sec.users
      WHERE password_expires_at < now() AND is_active AND deleted_at IS NULL)  AS expired_passwords,
    (SELECT count(*) FROM sec.users u JOIN sec.roles r ON r.code = u.role_code
      WHERE r.rank <= 10 AND NOT u.mfa_enabled AND u.is_active AND u.deleted_at IS NULL)
                                                                               AS admins_without_mfa,
    (SELECT count(*) FROM audit.security_events
      WHERE severity = 'critical' AND occurred_at > now() - interval '7 days') AS critical_events_7d;
$$;

DROP VIEW IF EXISTS audit.v_security_dashboard;
CREATE VIEW audit.v_security_dashboard AS SELECT * FROM audit.security_dashboard();

COMMENT ON VIEW audit.v_security_dashboard IS 'Что смотреть службе безопасности каждое утро';

-- ---- Публичные доноры: только подтверждённые и только с согласием на публикацию имени ------------
--  Оформлено функцией, а не открытым представлением: список доноров показывается
--  анонимному посетителю сайта, то есть без контекста пользователя. Если бы для этого
--  открыли RLS-доступ к site.donations, наружу утекли бы и e-mail, и суммы. Функция
--  отдаёт только те поля, которые фонд вправе публиковать.
CREATE OR REPLACE FUNCTION site.public_donors()
RETURNS TABLE (
    donor_name          text,
    donations_count     bigint,
    last_donation_at    timestamptz,
    total_amount_public core.money_amount,
    currency            core.currency_code
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = site, core, pg_catalog, public
AS $$
SELECT
    d.donor_name,
    count(*)                                        AS donations_count,
    max(d.paid_at)                                  AS last_donation_at,
    CASE WHEN bool_and(d.show_amount_publicly)
         THEN sum(d.amount) END                     AS total_amount_public,
    min(d.currency)                                 AS currency
FROM site.donations d
WHERE d.status = 'succeeded'
  AND d.visibility = 'public'
  AND d.is_verified                 -- «только подтверждённые данные», как обещает сайт
  AND d.donor_name IS NOT NULL
GROUP BY d.donor_name
ORDER BY max(d.paid_at) DESC;
$$;

DROP VIEW IF EXISTS site.v_public_donors;
CREATE VIEW site.v_public_donors AS SELECT * FROM site.public_donors();

COMMENT ON VIEW site.v_public_donors IS 'Список доноров для сайта. Анонимные и неподтверждённые сюда не попадают.';

-- ---- Сбор по направлениям -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION site.donation_progress()
RETURNS TABLE (
    id               uuid,
    code             core.slug,
    title            text,
    goal_amount      core.money_amount,
    currency         core.currency_code,
    raised_amount    numeric,
    donations_count  bigint,
    progress_percent numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = site, core, pg_catalog, public
AS $$
SELECT
    dd.id,
    dd.code,
    t.title,
    dd.goal_amount,
    dd.currency,
    coalesce(sum(d.amount) FILTER (WHERE d.status = 'succeeded'), 0) AS raised_amount,
    count(*) FILTER (WHERE d.status = 'succeeded')                   AS donations_count,
    CASE WHEN dd.goal_amount IS NULL OR dd.goal_amount = 0 THEN NULL
         ELSE round(100.0 * coalesce(sum(d.amount) FILTER (WHERE d.status = 'succeeded'), 0)
                    / dd.goal_amount, 1)
    END AS progress_percent
FROM site.donation_directions dd
LEFT JOIN site.donation_direction_translations t
       ON t.direction_id = dd.id AND t.locale = 'ru'
LEFT JOIN site.donations d ON d.direction_id = dd.id
WHERE dd.is_active
GROUP BY dd.id, dd.code, t.title, dd.goal_amount, dd.currency, dd.sort_order
ORDER BY dd.sort_order;
$$;

DROP VIEW IF EXISTS site.v_donation_progress;
CREATE VIEW site.v_donation_progress AS SELECT * FROM site.donation_progress();

COMMENT ON VIEW site.v_donation_progress IS 'Сбор по направлениям для публичной страницы поддержки фонда';

-- ---- Непрочитанные уведомления --------------------------------------------------------------------
CREATE OR REPLACE VIEW eventum.v_my_notifications AS
SELECT n.*
FROM eventum.notifications n
WHERE n.user_id = sec.current_user_id()
  AND (n.expires_at IS NULL OR n.expires_at > now())
ORDER BY n.is_read, n.created_at DESC;

-- ---- Обезличенная выборка для аналитики и грантовых отчётов ------------------------------------------
--  Ни имён, ни дат рождения, ни диагнозов текстом. Роль eventum_readonly видит только это.
--  Как и панель безопасности, оформлено функцией: аналитик подключается к базе напрямую,
--  без сессии портала, и обычное представление вернуло бы ему пустоту из-за RLS.
CREATE OR REPLACE FUNCTION eventum.anonymous_statistics()
RETURNS TABLE (
    public_code        text,
    center_code        text,
    status             core.child_status,
    age_group          text,
    enrolled_month     date,
    progress_percent   core.percent,
    goals_achieved     bigint,
    sessions_completed bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = eventum, core, pg_catalog, public
AS $$
SELECT
    c.public_code,
    ce.code::text                              AS center_code,
    c.status,
    CASE
      WHEN core.age_years(c.birth_date) IS NULL THEN 'unknown'
      WHEN core.age_years(c.birth_date) < 3     THEN '0-2'
      WHEN core.age_years(c.birth_date) < 8     THEN '3-7'
      WHEN core.age_years(c.birth_date) < 13    THEN '8-12'
      WHEN core.age_years(c.birth_date) < 18    THEN '13-17'
      ELSE '18+'
    END                                        AS age_group,
    date_trunc('month', c.enrolled_on)::date   AS enrolled_month,
    eventum.calc_child_progress(c.id)          AS progress_percent,
    (SELECT count(*) FROM eventum.goals g
      WHERE g.child_id = c.id AND g.status = 'achieved')       AS goals_achieved,
    (SELECT count(*) FROM eventum.therapy_sessions s
      WHERE s.primary_child_id = c.id AND s.status = 'completed') AS sessions_completed
FROM eventum.children c
LEFT JOIN eventum.centers ce ON ce.id = c.center_id
WHERE c.deleted_at IS NULL;
$$;

DROP VIEW IF EXISTS eventum.v_anonymous_statistics;
CREATE VIEW eventum.v_anonymous_statistics AS SELECT * FROM eventum.anonymous_statistics();

COMMENT ON VIEW eventum.v_anonymous_statistics
    IS 'Обезличенные данные для отчётов донорам и грантодателям: возрастные группы вместо дат рождения';

-- =====================================================================================
--  РАЗДЕЛ 14. РАЗГРАНИЧЕНИЕ ПРАВ НА УРОВНЕ СТРОК (Row Level Security)
-- =====================================================================================
--  Это главный механизм защиты. Даже если в приложении будет ошибка и запрос уйдёт без
--  условия WHERE, база вернёт только те строки, которые пользователю разрешено видеть.
--
--  Правила:
--    admin / director  — видят всё
--    curator / specialist — детей своего центра и тех, в чьей команде состоят
--    parent            — только своих детей и только записи с visibility = 'parents'
--    все               — свои уведомления, свои сессии, свой профиль
--
--  FORCE ROW LEVEL SECURITY включён намеренно: политики действуют и на владельца таблиц.
--  Исключение — роль eventum_secdef с атрибутом BYPASSRLS: ей принадлежат функции
--  проверки доступа, и без обхода политик они зациклились бы сами на себе.
-- =====================================================================================

\echo '>>> [14] Политики доступа к строкам (RLS)...'

DO $rls$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('sec',     'users'),
            ('sec',     'auth_sessions'),
            ('sec',     'password_history'),
            ('sec',     'user_permission_overrides'),
            ('sec',     'user_preferences'),
            ('eventum', 'children'),
            ('eventum', 'guardians'),
            ('eventum', 'child_guardians'),
            ('eventum', 'child_team_members'),
            ('eventum', 'consents'),
            ('eventum', 'goals'),
            ('eventum', 'goal_measurements'),
            ('eventum', 'child_tasks'),
            ('eventum', 'therapy_sessions'),
            ('eventum', 'session_attendees'),
            ('eventum', 'progress_logs'),
            ('eventum', 'documents'),
            ('eventum', 'document_chunks'),
            ('eventum', 'chat_threads'),
            ('eventum', 'chat_messages'),
            ('eventum', 'notifications'),
            ('eventum', 'change_requests'),
            ('eventum', 'access_requests'),
            ('site',    'contact_requests'),
            ('site',    'join_requests'),
            ('site',    'training_applications'),
            ('site',    'donations')
        ) AS t(sch, tbl)
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.sch, r.tbl);
        EXECUTE format('ALTER TABLE %I.%I FORCE  ROW LEVEL SECURITY', r.sch, r.tbl);
    END LOOP;
END
$rls$;

-- ---- sec.users --------------------------------------------------------------------------
DROP POLICY IF EXISTS users_select ON sec.users;
CREATE POLICY users_select ON sec.users FOR SELECT
    USING (
        sec.is_admin()
        OR id = sec.current_user_id()                       -- свой профиль
        OR sec.has_permission('users.view')                 -- кадровый просмотр
    );

DROP POLICY IF EXISTS users_update_self ON sec.users;
CREATE POLICY users_update_self ON sec.users FOR UPDATE
    USING (id = sec.current_user_id() OR sec.has_permission('users.manage'))
    WITH CHECK (id = sec.current_user_id() OR sec.has_permission('users.manage'));

DROP POLICY IF EXISTS users_insert ON sec.users;
CREATE POLICY users_insert ON sec.users FOR INSERT
    WITH CHECK (sec.has_permission('users.manage'));

-- ---- Сессии и история паролей: строго свои ------------------------------------------------
DROP POLICY IF EXISTS sessions_own ON sec.auth_sessions;
CREATE POLICY sessions_own ON sec.auth_sessions FOR ALL
    USING (user_id = sec.current_user_id() OR sec.has_permission('security.manage'))
    WITH CHECK (user_id = sec.current_user_id() OR sec.has_permission('security.manage'));

DROP POLICY IF EXISTS password_history_own ON sec.password_history;
CREATE POLICY password_history_own ON sec.password_history FOR SELECT
    USING (user_id = sec.current_user_id() OR sec.has_permission('security.manage'));

DROP POLICY IF EXISTS overrides_visible ON sec.user_permission_overrides;
CREATE POLICY overrides_visible ON sec.user_permission_overrides FOR ALL
    USING (user_id = sec.current_user_id() OR sec.has_permission('users.manage'))
    WITH CHECK (sec.has_permission('users.manage'));

-- ---- Дети ---------------------------------------------------------------------------------
DROP POLICY IF EXISTS children_select ON eventum.children;
CREATE POLICY children_select ON eventum.children FOR SELECT
    USING (eventum.can_access_child(id));

DROP POLICY IF EXISTS children_insert ON eventum.children;
CREATE POLICY children_insert ON eventum.children FOR INSERT
    WITH CHECK (sec.has_permission('children.create'));

DROP POLICY IF EXISTS children_update ON eventum.children;
CREATE POLICY children_update ON eventum.children FOR UPDATE
    USING (eventum.can_edit_child(id))
    WITH CHECK (eventum.can_edit_child(id));

-- ---- Семьи ---------------------------------------------------------------------------------
DROP POLICY IF EXISTS guardians_select ON eventum.guardians;
CREATE POLICY guardians_select ON eventum.guardians FOR SELECT
    USING (
        sec.is_admin()
        OR user_id = sec.current_user_id()
        OR EXISTS (SELECT 1 FROM eventum.child_guardians cg
                    WHERE cg.guardian_id = eventum.guardians.id
                      AND eventum.can_access_child(cg.child_id))
    );

DROP POLICY IF EXISTS guardians_write ON eventum.guardians;
CREATE POLICY guardians_write ON eventum.guardians FOR ALL
    USING (sec.has_permission('children.edit'))
    WITH CHECK (sec.has_permission('children.edit'));

DROP POLICY IF EXISTS child_guardians_access ON eventum.child_guardians;
CREATE POLICY child_guardians_access ON eventum.child_guardians FOR ALL
    USING (eventum.can_access_child(child_id))
    WITH CHECK (eventum.can_edit_child(child_id));

-- ---- Команда ребёнка --------------------------------------------------------------------------
DROP POLICY IF EXISTS team_select ON eventum.child_team_members;
CREATE POLICY team_select ON eventum.child_team_members FOR SELECT
    USING (user_id = sec.current_user_id() OR eventum.can_access_child(child_id));

DROP POLICY IF EXISTS team_write ON eventum.child_team_members;
CREATE POLICY team_write ON eventum.child_team_members FOR ALL
    USING (sec.has_permission('team.manage'))
    WITH CHECK (sec.has_permission('team.manage'));

-- ---- Согласия ------------------------------------------------------------------------------------
DROP POLICY IF EXISTS consents_select ON eventum.consents;
CREATE POLICY consents_select ON eventum.consents FOR SELECT
    USING (
        sec.is_admin()
        OR subject_user_id = sec.current_user_id()
        OR (child_id IS NOT NULL AND eventum.can_access_child(child_id))
    );

DROP POLICY IF EXISTS consents_write ON eventum.consents;
CREATE POLICY consents_write ON eventum.consents FOR ALL
    USING (sec.has_permission('consents.manage'))
    WITH CHECK (sec.has_permission('consents.manage'));

-- ---- Цели, замеры, задачи ----------------------------------------------------------------------------
DROP POLICY IF EXISTS goals_access ON eventum.goals;
CREATE POLICY goals_access ON eventum.goals FOR SELECT USING (eventum.can_access_child(child_id));

DROP POLICY IF EXISTS goals_write ON eventum.goals;
CREATE POLICY goals_write ON eventum.goals FOR ALL
    USING (eventum.can_edit_child(child_id))
    WITH CHECK (eventum.can_edit_child(child_id));

DROP POLICY IF EXISTS measurements_access ON eventum.goal_measurements;
CREATE POLICY measurements_access ON eventum.goal_measurements FOR ALL
    USING (EXISTS (SELECT 1 FROM eventum.goals g
                    WHERE g.id = goal_id AND eventum.can_access_child(g.child_id)))
    WITH CHECK (EXISTS (SELECT 1 FROM eventum.goals g
                         WHERE g.id = goal_id AND eventum.can_edit_child(g.child_id)));

DROP POLICY IF EXISTS tasks_access ON eventum.child_tasks;
CREATE POLICY tasks_access ON eventum.child_tasks FOR SELECT USING (eventum.can_access_child(child_id));

DROP POLICY IF EXISTS tasks_write ON eventum.child_tasks;
CREATE POLICY tasks_write ON eventum.child_tasks FOR ALL
    USING (eventum.can_edit_child(child_id))
    WITH CHECK (eventum.can_edit_child(child_id));

-- ---- Занятия -----------------------------------------------------------------------------------------
DROP POLICY IF EXISTS sessions_select ON eventum.therapy_sessions;
CREATE POLICY sessions_select ON eventum.therapy_sessions FOR SELECT
    USING (
        specialist_id = sec.current_user_id()
        OR primary_child_id IS NULL
        OR eventum.can_access_child(primary_child_id)
    );

DROP POLICY IF EXISTS sessions_write ON eventum.therapy_sessions;
CREATE POLICY sessions_write ON eventum.therapy_sessions FOR ALL
    USING (sec.has_permission('sessions.manage') OR specialist_id = sec.current_user_id())
    WITH CHECK (sec.has_permission('sessions.manage') OR specialist_id = sec.current_user_id());

DROP POLICY IF EXISTS attendees_access ON eventum.session_attendees;
CREATE POLICY attendees_access ON eventum.session_attendees FOR ALL
    USING (eventum.can_access_child(child_id))
    WITH CHECK (eventum.can_edit_child(child_id));

-- ---- Записи о прогрессе ---------------------------------------------------------------------------------
--  Родитель видит только записи, помеченные как видимые семье. Служебные пометки
--  (visibility = 'admin_only') не видит никто, кроме администрации.
DROP POLICY IF EXISTS logs_select ON eventum.progress_logs;
CREATE POLICY logs_select ON eventum.progress_logs FOR SELECT
    USING (
        deleted_at IS NULL
        AND eventum.can_access_child(child_id)
        AND (
            sec.is_admin()
            OR author_id = sec.current_user_id()
            OR (visibility = 'team'    AND sec.current_role_code() <> 'parent')
            OR (visibility = 'parents')
            OR (visibility = 'public')
        )
    );

DROP POLICY IF EXISTS logs_insert ON eventum.progress_logs;
CREATE POLICY logs_insert ON eventum.progress_logs FOR INSERT
    WITH CHECK (author_id = sec.current_user_id() AND eventum.can_edit_child(child_id));

--  Правка чужой записи запрещена, своей — только в течение суток: дневник наблюдений
--  должен оставаться достоверным, а не переписываемым задним числом.
DROP POLICY IF EXISTS logs_update_own ON eventum.progress_logs;
CREATE POLICY logs_update_own ON eventum.progress_logs FOR UPDATE
    USING (
        (author_id = sec.current_user_id() AND created_at > now() - interval '24 hours')
        OR sec.has_permission('logs.moderate')
    )
    WITH CHECK (
        (author_id = sec.current_user_id() AND created_at > now() - interval '24 hours')
        OR sec.has_permission('logs.moderate')
    );

-- ---- Документы -------------------------------------------------------------------------------------------
DROP POLICY IF EXISTS documents_select ON eventum.documents;
CREATE POLICY documents_select ON eventum.documents FOR SELECT
    USING (
        deleted_at IS NULL
        AND virus_scan_status IN ('clean', 'skipped')
        AND (
            child_id IS NULL
            OR eventum.can_access_child(child_id)
        )
        AND (
            sec.is_admin()
            OR uploaded_by = sec.current_user_id()
            OR visibility <> 'admin_only'
        )
        AND (visibility <> 'team' OR sec.current_role_code() <> 'parent')
    );

DROP POLICY IF EXISTS documents_insert ON eventum.documents;
CREATE POLICY documents_insert ON eventum.documents FOR INSERT
    WITH CHECK (
        uploaded_by = sec.current_user_id()
        AND sec.has_permission('documents.upload')
        AND (child_id IS NULL OR eventum.can_access_child(child_id))
    );

DROP POLICY IF EXISTS documents_update ON eventum.documents;
CREATE POLICY documents_update ON eventum.documents FOR UPDATE
    USING (uploaded_by = sec.current_user_id() OR sec.has_permission('documents.manage'))
    WITH CHECK (uploaded_by = sec.current_user_id() OR sec.has_permission('documents.manage'));

--  Содержимое файлов: политика есть, но приложение к таблице всё равно не допущено
--  (см. REVOKE в разделе 16). Читать и писать куски можно только через функции
--  eventum.document_*, которые ведут журнал доступа. Политика — второй рубеж на случай,
--  если права когда-нибудь выдадут по ошибке.
DROP POLICY IF EXISTS document_chunks_access ON eventum.document_chunks;
CREATE POLICY document_chunks_access ON eventum.document_chunks FOR ALL
    USING (eventum.can_read_document(document_id))
    WITH CHECK (EXISTS (SELECT 1 FROM eventum.documents d
                         WHERE d.id = document_id AND d.uploaded_by = sec.current_user_id()));

-- ---- Чат ----------------------------------------------------------------------------------------------------
DROP POLICY IF EXISTS threads_access ON eventum.chat_threads;
CREATE POLICY threads_access ON eventum.chat_threads FOR ALL
    USING (child_id IS NULL OR eventum.can_access_child(child_id))
    WITH CHECK (child_id IS NULL OR eventum.can_access_child(child_id));

DROP POLICY IF EXISTS messages_select ON eventum.chat_messages;
CREATE POLICY messages_select ON eventum.chat_messages FOR SELECT
    USING (
        deleted_at IS NULL
        AND EXISTS (
            SELECT 1 FROM eventum.chat_threads t
             WHERE t.id = thread_id
               AND (t.child_id IS NULL OR eventum.can_access_child(t.child_id))
        )
        -- Родителю рабочая переписка команды не видна.
        AND (sec.current_role_code() <> 'parent'
             OR EXISTS (SELECT 1 FROM eventum.chat_threads t2
                         WHERE t2.id = thread_id AND t2.kind = 'announcement'))
    );

DROP POLICY IF EXISTS messages_insert ON eventum.chat_messages;
CREATE POLICY messages_insert ON eventum.chat_messages FOR INSERT
    WITH CHECK (author_id = sec.current_user_id());

DROP POLICY IF EXISTS messages_update_own ON eventum.chat_messages;
CREATE POLICY messages_update_own ON eventum.chat_messages FOR UPDATE
    USING (author_id = sec.current_user_id() OR sec.has_permission('chat.moderate'))
    WITH CHECK (author_id = sec.current_user_id() OR sec.has_permission('chat.moderate'));

-- ---- Уведомления: только свои ------------------------------------------------------------------------------------
DROP POLICY IF EXISTS notifications_own ON eventum.notifications;
CREATE POLICY notifications_own ON eventum.notifications FOR ALL
    USING (user_id = sec.current_user_id())
    WITH CHECK (true);   -- создавать уведомления другим вправе серверные функции

-- ---- Согласования ---------------------------------------------------------------------------------------------------
DROP POLICY IF EXISTS approvals_select ON eventum.change_requests;
CREATE POLICY approvals_select ON eventum.change_requests FOR SELECT
    USING (requested_by = sec.current_user_id() OR sec.has_permission('approvals.decide'));

DROP POLICY IF EXISTS approvals_insert ON eventum.change_requests;
CREATE POLICY approvals_insert ON eventum.change_requests FOR INSERT
    WITH CHECK (requested_by = sec.current_user_id());

DROP POLICY IF EXISTS approvals_update ON eventum.change_requests;
CREATE POLICY approvals_update ON eventum.change_requests FOR UPDATE
    USING (sec.has_permission('approvals.decide') OR requested_by = sec.current_user_id())
    WITH CHECK (sec.has_permission('approvals.decide') OR requested_by = sec.current_user_id());

DROP POLICY IF EXISTS access_requests_policy ON eventum.access_requests;
CREATE POLICY access_requests_policy ON eventum.access_requests FOR ALL
    USING (user_id = sec.current_user_id() OR sec.has_permission('approvals.decide'))
    WITH CHECK (user_id = sec.current_user_id() OR sec.has_permission('approvals.decide'));

-- ---- Остатки, которые тоже не должны лежать открыто ------------------------------------------------
--  Ниже — таблицы, про которые легко забыть, но в них лежат либо секреты, либо сведения
--  о здоровье. Справочники (центры, программы, типы записей, роли) намеренно оставлены
--  открытыми на чтение: без них не отрисовать ни одну страницу, а тайны в них нет.

--  Резервные коды 2FA и токены восстановления — только свои. Даже администратор не должен
--  видеть чужие: увидев их, он сможет войти под чужим именем и подписать чужие записи.
ALTER TABLE sec.mfa_recovery_codes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sec.mfa_recovery_codes      FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mfa_codes_own ON sec.mfa_recovery_codes;
CREATE POLICY mfa_codes_own ON sec.mfa_recovery_codes FOR ALL
    USING (user_id = sec.current_user_id())
    WITH CHECK (user_id = sec.current_user_id());

ALTER TABLE sec.password_reset_tokens   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sec.password_reset_tokens   FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reset_tokens_own ON sec.password_reset_tokens;
CREATE POLICY reset_tokens_own ON sec.password_reset_tokens FOR ALL
    USING (user_id = sec.current_user_id())
    WITH CHECK (user_id = sec.current_user_id());

--  Попытки входа: свои видит каждый, все — служба безопасности. Это список действующих
--  логинов и адресов, с которых работает фонд.
ALTER TABLE sec.login_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE sec.login_attempts FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS login_attempts_read ON sec.login_attempts;
CREATE POLICY login_attempts_read ON sec.login_attempts FOR SELECT
    USING (user_id = sec.current_user_id() OR sec.has_permission('security.manage')
           OR sec.has_permission('audit.view'));
DROP POLICY IF EXISTS login_attempts_insert ON sec.login_attempts;
CREATE POLICY login_attempts_insert ON sec.login_attempts FOR INSERT WITH CHECK (true);

--  Справочники прав: читать может любой вошедший (интерфейс скрывает недоступные кнопки),
--  менять — только тот, кто управляет пользователями.
DO $ref_rls$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('sec', 'roles', 'users.manage'),
        ('sec', 'permissions', 'users.manage'),
        ('sec', 'role_permissions', 'users.manage'),
        ('eventum', 'centers', 'centers.manage'),
        ('eventum', 'center_translations', 'centers.manage'),
        ('eventum', 'programs', 'centers.manage'),
        ('eventum', 'program_translations', 'centers.manage'),
        ('eventum', 'log_types', 'centers.manage'),
        ('eventum', 'user_centers', 'users.manage'),
        ('eventum', 'user_programs', 'users.manage')
    ) AS t(sch, tbl, perm)
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.sch, r.tbl);
        EXECUTE format('ALTER TABLE %I.%I FORCE  ROW LEVEL SECURITY', r.sch, r.tbl);
        EXECUTE format('DROP POLICY IF EXISTS reference_read ON %I.%I', r.sch, r.tbl);
        EXECUTE format('CREATE POLICY reference_read ON %I.%I FOR SELECT USING (true)', r.sch, r.tbl);
        EXECUTE format('DROP POLICY IF EXISTS reference_write ON %I.%I', r.sch, r.tbl);
        EXECUTE format($p$CREATE POLICY reference_write ON %I.%I FOR ALL
                          USING (sec.has_permission(%L)) WITH CHECK (sec.has_permission(%L))$p$,
                       r.sch, r.tbl, r.perm, r.perm);
    END LOOP;
END
$ref_rls$;

--  Парольная политика: видят все (интерфейс подсказывает требования), меняет администратор.
ALTER TABLE sec.password_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE sec.password_policy FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS password_policy_read ON sec.password_policy;
CREATE POLICY password_policy_read ON sec.password_policy FOR SELECT USING (true);
DROP POLICY IF EXISTS password_policy_write ON sec.password_policy;
CREATE POLICY password_policy_write ON sec.password_policy FOR ALL
    USING (sec.is_admin()) WITH CHECK (sec.is_admin());

--  Отпуска и больничные. Причина отсутствия — это сведения о здоровье сотрудника,
--  и коллегам они не нужны: для расписания достаточно факта занятости.
ALTER TABLE eventum.staff_absences ENABLE ROW LEVEL SECURITY;
ALTER TABLE eventum.staff_absences FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS absences_access ON eventum.staff_absences;
CREATE POLICY absences_access ON eventum.staff_absences FOR ALL
    USING (user_id = sec.current_user_id() OR sec.has_permission('users.manage')
           OR sec.has_permission('sessions.manage'))
    WITH CHECK (user_id = sec.current_user_id() OR sec.has_permission('users.manage'));

ALTER TABLE eventum.staff_availability ENABLE ROW LEVEL SECURITY;
ALTER TABLE eventum.staff_availability FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS availability_read ON eventum.staff_availability;
CREATE POLICY availability_read ON eventum.staff_availability FOR SELECT USING (true);
DROP POLICY IF EXISTS availability_write ON eventum.staff_availability;
CREATE POLICY availability_write ON eventum.staff_availability FOR ALL
    USING (user_id = sec.current_user_id() OR sec.has_permission('users.manage'))
    WITH CHECK (user_id = sec.current_user_id() OR sec.has_permission('users.manage'));

--  Упоминания в чате и отметки прочтения: видны только тем, кому виден сам чат.
ALTER TABLE eventum.chat_mentions ENABLE ROW LEVEL SECURITY;
ALTER TABLE eventum.chat_mentions FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mentions_access ON eventum.chat_mentions;
CREATE POLICY mentions_access ON eventum.chat_mentions FOR ALL
    USING (
        user_id = sec.current_user_id()
        OR EXISTS (SELECT 1 FROM eventum.chat_threads t
                     JOIN eventum.chat_messages m ON m.thread_id = t.id
                    WHERE m.id = message_id
                      AND (t.child_id IS NULL OR eventum.can_access_child(t.child_id)))
    )
    WITH CHECK (true);

ALTER TABLE eventum.chat_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE eventum.chat_reads FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS chat_reads_own ON eventum.chat_reads;
CREATE POLICY chat_reads_own ON eventum.chat_reads FOR ALL
    USING (user_id = sec.current_user_id())
    WITH CHECK (user_id = sec.current_user_id());

--  Кто ещё вёл занятие: видно тем, кому доступен ребёнок.
ALTER TABLE eventum.session_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE eventum.session_staff FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS session_staff_access ON eventum.session_staff;
CREATE POLICY session_staff_access ON eventum.session_staff FOR ALL
    USING (
        user_id = sec.current_user_id()
        OR EXISTS (SELECT 1 FROM eventum.therapy_sessions s
                    WHERE s.id = session_id
                      AND (s.primary_child_id IS NULL OR eventum.can_access_child(s.primary_child_id)))
    )
    WITH CHECK (sec.has_permission('sessions.manage'));

-- ---- Настройки интерфейса: строго свои ------------------------------------------------------------
DROP POLICY IF EXISTS user_preferences_own ON sec.user_preferences;
CREATE POLICY user_preferences_own ON sec.user_preferences FOR ALL
    USING (user_id = sec.current_user_id())
    WITH CHECK (user_id = sec.current_user_id());

-- ---- Контент сайта: читают все, меняет только редактор -----------------------------------------------
--  Без этих политик любое соединение приложения могло бы переписать оферту, отчёт фонда
--  или список команды. Чтение публичное — это и есть сайт; запись — по праву content.manage.
DO $site_rls$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('news_posts'), ('news_translations'),
            ('blog_posts'), ('blog_translations'),
            ('faq_items'), ('faq_translations'),
            ('projects'), ('project_translations'),
            ('team_members'), ('team_member_translations'),
            ('training_programs'), ('training_program_translations'), ('training_events'),
            ('volunteer_opportunities'), ('volunteer_opportunity_translations'),
            ('media_albums'), ('media_album_translations'), ('media_items'),
            ('instagram_posts'), ('stat_counters'),
            ('donation_directions'), ('donation_direction_translations'),
            ('content_blocks'), ('content_block_translations'),
            ('ui_strings'), ('legal_documents'), ('legal_document_translations'),
            ('public_report_translations')
        ) AS t(tbl)
    LOOP
        EXECUTE format('ALTER TABLE site.%I ENABLE ROW LEVEL SECURITY', r.tbl);
        EXECUTE format('ALTER TABLE site.%I FORCE  ROW LEVEL SECURITY', r.tbl);
        EXECUTE format('DROP POLICY IF EXISTS content_public_read ON site.%I', r.tbl);
        EXECUTE format('CREATE POLICY content_public_read ON site.%I FOR SELECT USING (true)', r.tbl);
        EXECUTE format('DROP POLICY IF EXISTS content_editor_write ON site.%I', r.tbl);
        EXECUTE format($p$CREATE POLICY content_editor_write ON site.%I FOR ALL
                          USING (sec.has_permission('content.manage'))
                          WITH CHECK (sec.has_permission('content.manage'))$p$, r.tbl);
    END LOOP;
END
$site_rls$;

--  Отчёты фонда — отдельно: публиковать их вправе только тот, у кого есть reports.publish.
--  Редактор сайта правит новости и FAQ, но не годовой финансовый отчёт.
ALTER TABLE site.public_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE site.public_reports FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reports_public_read ON site.public_reports;
CREATE POLICY reports_public_read ON site.public_reports FOR SELECT USING (true);
DROP POLICY IF EXISTS reports_publisher_write ON site.public_reports;
CREATE POLICY reports_publisher_write ON site.public_reports FOR ALL
    USING (sec.has_permission('reports.publish'))
    WITH CHECK (sec.has_permission('reports.publish'));

--  Настройки: наружу отдаются только помеченные как публичные (телефон, валюта),
--  служебные (адреса интеграций, сроки хранения) — по праву на управление контентом.
ALTER TABLE site.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE site.settings FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS settings_read ON site.settings;
CREATE POLICY settings_read ON site.settings FOR SELECT
    USING (is_public OR sec.has_permission('content.manage') OR sec.is_admin());
DROP POLICY IF EXISTS settings_write ON site.settings;
CREATE POLICY settings_write ON site.settings FOR ALL
    USING (sec.is_admin())
    WITH CHECK (sec.is_admin());

-- ---- Заявки с сайта и пожертвования ----------------------------------------------------------------------------------
--  Вставку делают SECURITY DEFINER-функции (site.submit_*), поэтому политика на INSERT
--  разрешающая. Чтение — только у сотрудников с соответствующим правом.
DROP POLICY IF EXISTS contact_requests_read ON site.contact_requests;
CREATE POLICY contact_requests_read ON site.contact_requests FOR SELECT
    USING (sec.has_permission('leads.view'));

DROP POLICY IF EXISTS contact_requests_write ON site.contact_requests;
CREATE POLICY contact_requests_write ON site.contact_requests FOR UPDATE
    USING (sec.has_permission('leads.manage'))
    WITH CHECK (sec.has_permission('leads.manage'));

DROP POLICY IF EXISTS contact_requests_insert ON site.contact_requests;
CREATE POLICY contact_requests_insert ON site.contact_requests FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS join_requests_read ON site.join_requests;
CREATE POLICY join_requests_read ON site.join_requests FOR SELECT
    USING (sec.has_permission('leads.view'));

DROP POLICY IF EXISTS join_requests_insert ON site.join_requests;
CREATE POLICY join_requests_insert ON site.join_requests FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS join_requests_update ON site.join_requests;
CREATE POLICY join_requests_update ON site.join_requests FOR UPDATE
    USING (sec.has_permission('leads.manage'))
    WITH CHECK (sec.has_permission('leads.manage'));

DROP POLICY IF EXISTS training_apps_read ON site.training_applications;
CREATE POLICY training_apps_read ON site.training_applications FOR SELECT
    USING (sec.has_permission('leads.view'));

DROP POLICY IF EXISTS training_apps_insert ON site.training_applications;
CREATE POLICY training_apps_insert ON site.training_applications FOR INSERT WITH CHECK (true);

--  Пожертвования — финансовые данные: их видит только бухгалтерия и руководство.
DROP POLICY IF EXISTS donations_read ON site.donations;
CREATE POLICY donations_read ON site.donations FOR SELECT
    USING (sec.has_permission('donations.view') OR donor_user_id = sec.current_user_id());

--  Публичная страница доноров читает не таблицу, а функцию site.public_donors():
--  открывать site.donations анонимному посетителю нельзя даже частично — в строке
--  лежат e-mail донора, сумма и идентификатор платежа.
DROP POLICY IF EXISTS donations_public_read ON site.donations;

DROP POLICY IF EXISTS donations_insert ON site.donations;
CREATE POLICY donations_insert ON site.donations FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS donations_update ON site.donations;
CREATE POLICY donations_update ON site.donations FOR UPDATE
    USING (sec.has_permission('donations.manage'))
    WITH CHECK (sec.has_permission('donations.manage'));

-- =====================================================================================
--  РАЗДЕЛ 15. ОБСЛУЖИВАНИЕ И РЕЗЕРВНОЕ КОПИРОВАНИЕ
-- =====================================================================================

\echo '>>> [15] Обслуживание...'

-- Удаление истёкших сессий и токенов. Запускать раз в час.
CREATE OR REPLACE FUNCTION sec.purge_expired()
RETURNS TABLE (sessions_removed integer, tokens_removed integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, pg_catalog, public
AS $$
DECLARE
    v_sessions integer;
    v_tokens   integer;
BEGIN
    DELETE FROM sec.auth_sessions
     WHERE expires_at < now() - interval '30 days'
        OR (revoked_at IS NOT NULL AND revoked_at < now() - interval '30 days');
    GET DIAGNOSTICS v_sessions = ROW_COUNT;

    DELETE FROM sec.password_reset_tokens WHERE created_at < now() - interval '7 days';
    GET DIAGNOSTICS v_tokens = ROW_COUNT;

    -- История паролей обрезается до глубины политики: хранить больше незачем.
    DELETE FROM sec.password_history ph
     WHERE ph.id NOT IN (
        SELECT id FROM (
            SELECT id, row_number() OVER (PARTITION BY user_id ORDER BY changed_at DESC) AS rn
              FROM sec.password_history
        ) t
        WHERE t.rn <= (SELECT history_depth FROM sec.password_policy WHERE id = 1)
     );

    RETURN QUERY SELECT v_sessions, v_tokens;
END;
$$;

-- Блокировка учётных записей, которые давно не использовались.
CREATE OR REPLACE FUNCTION sec.deactivate_stale_users(p_days integer DEFAULT 180)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = sec, audit, pg_catalog, public
AS $$
DECLARE
    v_count integer;
BEGIN
    WITH stale AS (
        UPDATE sec.users
           SET is_active = false, deactivated_at = now(),
               deactivation_reason = format('Нет входов более %s дней', p_days)
         WHERE is_active
           AND deleted_at IS NULL
           AND coalesce(last_login_at, created_at) < now() - make_interval(days => p_days)
        RETURNING id
    )
    INSERT INTO audit.security_events (kind, severity, target_user_id, succeeded, reason)
    SELECT 'user_deactivated', 'warning', id, true, format('Неактивность более %s дней', p_days)
      FROM stale;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- Применение сроков хранения персональных данных.
CREATE OR REPLACE FUNCTION eventum.apply_retention_policy()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = eventum, sec, pg_catalog, public
AS $$
DECLARE
    r       record;
    v_count integer := 0;
BEGIN
    FOR r IN
        SELECT id FROM eventum.children
         WHERE retention_until IS NOT NULL
           AND retention_until < now()
           AND anonymized_at IS NULL
           AND deleted_at IS NULL
    LOOP
        PERFORM eventum.anonymize_child(r.id, 'Истёк срок хранения персональных данных');
        v_count := v_count + 1;
    END LOOP;

    UPDATE eventum.documents
       SET deleted_at = now()
     WHERE retention_until IS NOT NULL AND retention_until < now() AND deleted_at IS NULL;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION eventum.apply_retention_policy()
    IS 'Автоматическое обезличивание по истечении срока хранения. Ставится в ежедневный планировщик.';

-- Архивирование старых журналов.
CREATE OR REPLACE FUNCTION audit.drop_old_partitions(p_keep_months integer DEFAULT 60)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    r        record;
    v_cutoff date := (date_trunc('month', current_date) - make_interval(months => p_keep_months))::date;
    v_count  integer := 0;
BEGIN
    FOR r IN
        SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'audit'
           AND c.relname ~ '^activity_log_[0-9]{4}_[0-9]{2}$'
           AND to_date(substring(c.relname from 14), 'YYYY_MM') < v_cutoff
    LOOP
        -- ВНИМАНИЕ: секцию удалять только после выгрузки в холодное хранилище.
        RAISE NOTICE 'Секция журнала готова к архивированию: audit.%', r.relname;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION audit.drop_old_partitions(integer)
    IS 'Намеренно только сообщает о старых секциях, но не удаляет их: журнал стирается решением человека, а не задачей по расписанию';

-- Проверка состояния базы (для мониторинга).
CREATE OR REPLACE FUNCTION core.health_check()
RETURNS TABLE (check_name text, status text, details text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, sec, eventum, audit, pg_catalog, public
AS $$
BEGIN
    RETURN QUERY
    SELECT 'users_without_password'::text,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warning' END,
           count(*)::text || ' активных учётных записей без пароля'
      FROM sec.users WHERE password_hash IS NULL AND is_active AND deleted_at IS NULL;

    RETURN QUERY
    SELECT 'admins_without_mfa'::text,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warning' END,
           count(*)::text || ' администраторов без двухфакторной аутентификации'
      FROM sec.users u JOIN sec.roles r ON r.code = u.role_code
     WHERE r.rank <= 10 AND NOT u.mfa_enabled AND u.is_active AND u.deleted_at IS NULL;

    RETURN QUERY
    SELECT 'children_without_consent'::text,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'critical' END,
           count(*)::text || ' детей без согласия на обработку данных'
      FROM eventum.children c
     WHERE c.deleted_at IS NULL AND c.status = 'active'
       AND NOT eventum.has_consent(c.id, 'data_processing');

    RETURN QUERY
    SELECT 'audit_partitions'::text,
           CASE WHEN count(*) >= 2 THEN 'ok' ELSE 'warning' END,
           count(*)::text || ' помесячных секций журнала создано'
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'audit' AND c.relname ~ '^activity_log_[0-9]{4}_[0-9]{2}$';

    RETURN QUERY
    SELECT 'default_partition_rows'::text,
           CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warning' END,
           CASE WHEN count(*) = 0
                THEN 'секция по умолчанию пуста — помесячных секций хватает'
                ELSE count(*)::text || ' записей попало в секцию по умолчанию: не хватает помесячных секций'
           END
      FROM audit.activity_log_default;
END;
$$;

COMMENT ON FUNCTION core.health_check() IS 'Ежедневная проверка: пароли, 2FA, согласия, секции журнала';

-- -------------------------------------------------------------------------------------------
--  РЕГЛАМЕНТ РЕЗЕРВНОГО КОПИРОВАНИЯ (выполняется вне базы, вынесено в комментарий)
-- -------------------------------------------------------------------------------------------
--  1. Полный логический дамп — ежедневно, с шифрованием:
--       pg_dump -h <host> -U eventum_backup -Fc -Z9 "EVENTUM" \
--         | age -r <ключ-получателя> > eventum_$(date +%F).dump.age
--
--  2. Непрерывное архивирование WAL (PITR) — восстановление на любой момент:
--       archive_mode = on
--       archive_command = 'age -r <ключ> < %p > /backup/wal/%f.age'
--       wal_level = replica
--
--  3. Правило 3-2-1: три копии, два разных носителя, одна — вне офиса фонда.
--
--  4. Проверка восстановления — ежемесячно на отдельном сервере. Резервная копия,
--     которую ни разу не восстанавливали, резервной копией не является.
--
--  5. Срок хранения: ежедневные — 30 дней, еженедельные — 12 недель, ежемесячные — 7 лет
--     (срок хранения документов социального обслуживания уточнить у юриста фонда).
--
--  6. Дампы содержат персональные данные детей. Хранить только в зашифрованном виде,
--     доступ — по отдельному ключу, выдача — под запись в журнале.
--
--  РАСПИСАНИЕ ЗАДАЧ (cron или pg_cron):
--       каждый час      SELECT sec.purge_expired();
--       ежедневно 02:00 SELECT eventum.purge_stale_uploads();
--       ежедневно 03:00 SELECT eventum.apply_retention_policy();
--       ежедневно 03:30 SELECT * FROM core.health_check();
--       ежемесячно      SELECT audit.create_monthly_partitions();
--       еженедельно     VACUUM ANALYZE;
-- -------------------------------------------------------------------------------------------

-- =====================================================================================
--  РАЗДЕЛ 16. ПРАВА ДОСТУПА НА УРОВНЕ СУБД (GRANT / REVOKE)
-- =====================================================================================
--  Принцип: «запрещено всё, что не разрешено явно».
--  Приложение получает ровно те права, без которых оно не работает — и ни одним больше.
-- =====================================================================================

\echo '>>> [16] Права доступа...'

-- ---- 16.1 Владельцы объектов --------------------------------------------------------------
--  Скрипт запускается суперпользователем (нужны CREATE DATABASE, CREATE ROLE, расширения),
--  поэтому по умолчанию все таблицы принадлежали бы ему. Это плохо: ошибка в приложении
--  или в SECURITY DEFINER-функции получала бы права суперпользователя на весь сервер,
--  а не только на данные фонда. Передаём владение выделенной роли eventum_owner.
DO $owners$
DECLARE
    r record;
BEGIN
    -- Таблицы, секции, представления
    FOR r IN
        SELECT n.nspname, c.relname, c.relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN ('core', 'sec', 'eventum', 'site', 'audit')
           AND c.relkind IN ('r', 'p', 'v', 'm')
    LOOP
        IF r.relkind = 'v' THEN
            EXECUTE format('ALTER VIEW %I.%I OWNER TO eventum_owner', r.nspname, r.relname);
        ELSIF r.relkind = 'm' THEN
            EXECUTE format('ALTER MATERIALIZED VIEW %I.%I OWNER TO eventum_owner', r.nspname, r.relname);
        ELSE
            EXECUTE format('ALTER TABLE %I.%I OWNER TO eventum_owner', r.nspname, r.relname);
        END IF;
    END LOOP;

    -- Самостоятельные последовательности (у identity-колонок владелец меняется вместе с таблицей)
    FOR r IN
        SELECT n.nspname, c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname IN ('core', 'sec', 'eventum', 'site', 'audit')
           AND c.relkind = 'S'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d
                            WHERE d.objid = c.oid AND d.deptype IN ('a', 'i'))
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO eventum_owner', r.nspname, r.relname);
    END LOOP;

    -- Функции
    FOR r IN
        SELECT p.oid::regprocedure AS sig
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname IN ('core', 'sec', 'eventum', 'site', 'audit')
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO eventum_owner', r.sig);
    END LOOP;
END
$owners$;

--  Функции с SECURITY DEFINER переводим на eventum_secdef — роль с BYPASSRLS.
--  Без обхода RLS проверки доступа зациклились бы: политика на eventum.children
--  вызывает can_access_child(), а та сама читает eventum.children.
--  Права на данные eventum_secdef получает через членство в eventum_owner.
DO $secdef$
DECLARE
    r record;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eventum_secdef') THEN
        FOR r IN
            SELECT p.oid::regprocedure AS sig
              FROM pg_proc p
              JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname IN ('core', 'sec', 'eventum', 'site', 'audit')
               AND p.prosecdef
        LOOP
            EXECUTE format('ALTER FUNCTION %s OWNER TO eventum_secdef', r.sig);
        END LOOP;

        GRANT eventum_owner TO eventum_secdef;
    END IF;
END
$secdef$;

-- ---- 16.2 Никаких прав по умолчанию ----------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA core, sec, eventum, site, audit FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA core, sec, eventum, site, audit FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA core, sec, eventum, site, audit FROM PUBLIC;

-- ---- 16.3 Рабочая роль приложения ---------------------------------------------------------------
GRANT USAGE ON SCHEMA core, sec, eventum, site, audit TO eventum_app;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA eventum, site TO eventum_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA sec          TO eventum_app;
GRANT USAGE, SELECT           ON ALL SEQUENCES IN SCHEMA eventum, site, sec TO eventum_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core, sec, eventum, site TO eventum_app;

-- Журналы: только дописывать. Изменить или стереть историю приложение не может.
GRANT INSERT ON audit.activity_log, audit.security_events, audit.data_access_log TO eventum_app;
GRANT SELECT ON audit.activity_log, audit.security_events, audit.data_access_log TO eventum_app;
--  Представления журнала — то, что показывает экран «Аудит». Их нужно выдать отдельно:
--  GRANT ... ON <перечень таблиц> представления не захватывает.
GRANT SELECT ON audit.v_recent_activity, audit.v_security_dashboard TO eventum_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO eventum_app;
REVOKE UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA audit FROM eventum_app;

-- Физическое удаление разрешено только там, где это безопасно и осмысленно.
REVOKE DELETE ON ALL TABLES IN SCHEMA eventum, site, sec FROM eventum_app;
GRANT  DELETE ON eventum.notifications, eventum.chat_mentions, eventum.chat_reads,
                 eventum.session_attendees, eventum.session_staff,
                 eventum.user_centers, eventum.user_programs,
                 eventum.staff_availability, eventum.staff_absences TO eventum_app;
GRANT  DELETE ON sec.auth_sessions, sec.password_reset_tokens, sec.mfa_recovery_codes TO eventum_app;

--  Содержимое файлов недоступно приложению напрямую: любое чтение обязано пройти через
--  eventum.document_download() / document_read_chunk(), которые проверяют права и пишут
--  в audit.data_access_log. Иначе скачивание медицинского документа не оставит следа.
REVOKE ALL ON eventum.document_chunks FROM eventum_app;

-- Парольную политику приложение только читает: менять её — задача администратора базы.
REVOKE INSERT, UPDATE ON sec.password_policy FROM eventum_app;
GRANT  SELECT ON sec.password_policy TO eventum_app;

-- Хеширование пароля доступно только через set_password / change_own_password.
REVOKE ALL ON FUNCTION sec.hash_password(text) FROM PUBLIC, eventum_app;

-- ---- 16.4 Аналитика: только обезличенное ------------------------------------------------------------
GRANT USAGE ON SCHEMA eventum, site, core TO eventum_readonly;
GRANT SELECT ON eventum.v_anonymous_statistics,
                site.v_donation_progress,
                site.v_public_donors TO eventum_readonly;
GRANT EXECUTE ON FUNCTION eventum.anonymous_statistics() TO eventum_readonly;
GRANT EXECUTE ON FUNCTION site.donation_progress()       TO eventum_readonly;
GRANT EXECUTE ON FUNCTION site.public_donors()           TO eventum_readonly;
GRANT EXECUTE ON FUNCTION core.health_check()            TO eventum_readonly;

--  Представления рабочей части (v_children_overview, v_center_load, v_dashboard_metrics)
--  аналитику не выдаются намеренно: они опираются на RLS и без сессии портала вернули бы
--  ему пустоту, а с сессией — персональные данные. Его источник — обезличенная статистика.

COMMENT ON VIEW eventum.v_anonymous_statistics IS
    'Единственный источник данных о детях для роли eventum_readonly: без имён, дат рождения и диагнозов';

-- ---- 16.5 Служба безопасности: только журналы ---------------------------------------------------------
GRANT USAGE  ON SCHEMA audit, sec, core, eventum TO eventum_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO eventum_auditor;
GRANT SELECT ON sec.login_attempts, audit.v_recent_activity, audit.v_security_dashboard TO eventum_auditor;
--  sec.users и sec.auth_sessions аудитору напрямую не выдаются: они под RLS и без
--  сессии портала вернули бы пустой результат. Сводные цифры он получает из панели
--  безопасности, а имена — из журнала, где они сохранены на момент события.
GRANT EXECUTE ON FUNCTION audit.security_dashboard() TO eventum_auditor, eventum_app;
GRANT EXECUTE ON FUNCTION core.health_check()        TO eventum_auditor, eventum_app;

-- ---- 16.6 Резервное копирование -------------------------------------------------------------------------
DO $backup_grant$
BEGIN
    -- pg_read_all_data появилась в PostgreSQL 14 и заменяет ручную раздачу SELECT.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_read_all_data') THEN
        GRANT pg_read_all_data TO eventum_backup;
    ELSE
        EXECUTE 'GRANT USAGE ON SCHEMA core, sec, eventum, site, audit TO eventum_backup';
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA core, sec, eventum, site, audit TO eventum_backup';
    END IF;
END
$backup_grant$;

-- ---- 16.7 Права на будущие объекты --------------------------------------------------------------------------
--  Без этого каждая новая таблица оказалась бы недоступна приложению до ручного GRANT.
ALTER DEFAULT PRIVILEGES FOR ROLE eventum_owner IN SCHEMA eventum, site, sec
    GRANT SELECT, INSERT, UPDATE ON TABLES TO eventum_app;
ALTER DEFAULT PRIVILEGES FOR ROLE eventum_owner IN SCHEMA eventum, site, sec, audit
    GRANT USAGE, SELECT ON SEQUENCES TO eventum_app;
ALTER DEFAULT PRIVILEGES FOR ROLE eventum_owner IN SCHEMA core, sec, eventum, site
    GRANT EXECUTE ON FUNCTIONS TO eventum_app;
ALTER DEFAULT PRIVILEGES FOR ROLE eventum_owner IN SCHEMA audit
    GRANT SELECT, INSERT ON TABLES TO eventum_app;
ALTER DEFAULT PRIVILEGES FOR ROLE eventum_owner IN SCHEMA audit
    GRANT SELECT ON TABLES TO eventum_auditor;

--  То же самое для объектов, созданных суперпользователем-установщиком: миграции
--  могут выполняться как от eventum_owner, так и от администратора сервера.
ALTER DEFAULT PRIVILEGES IN SCHEMA eventum, site, sec
    GRANT SELECT, INSERT, UPDATE ON TABLES TO eventum_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA eventum, site, sec, audit
    GRANT USAGE, SELECT ON SEQUENCES TO eventum_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, sec, eventum, site
    GRANT EXECUTE ON FUNCTIONS TO eventum_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit
    GRANT SELECT, INSERT ON TABLES TO eventum_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit
    GRANT SELECT ON TABLES TO eventum_auditor;

-- =====================================================================================
--  РАЗДЕЛ 17. НАЧАЛЬНЫЕ ДАННЫЕ
-- =====================================================================================
--  Справочники, реальные центры и программы фонда, роли и права.
--  Раздел идемпотентен: повторный запуск ничего не портит и не дублирует.
-- =====================================================================================

\echo '>>> [17] Начальные данные...'

-- ---- 17.1 Парольная политика ------------------------------------------------------------
INSERT INTO sec.password_policy (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ---- 17.2 Роли ----------------------------------------------------------------------------
INSERT INTO sec.roles (code, name_ru, name_kk, name_en, description, rank, is_staff, can_see_all_centers, is_system) VALUES
  ('admin',      'Администратор',      'Әкімші',            'Administrator',
   'Полный доступ ко всем данным и настройкам системы', 1, true, true, true),
  ('director',   'Руководитель',       'Басшы',             'Director',
   'Руководство фондом: все центры, отчётность, согласования', 5, true, true, true),
  ('curator',    'Куратор',            'Куратор',           'Curator',
   'Ведёт детей своего центра и координирует команду', 20, true, false, true),
  ('specialist', 'Специалист',         'Маман',             'Specialist',
   'Работает с детьми, в чьих командах состоит', 30, true, false, true),
  ('assistant',  'Ассистент',          'Көмекші',           'Assistant',
   'Помощь на занятиях, ограниченный доступ к записям', 40, true, false, false),
  ('accountant', 'Бухгалтер',          'Бухгалтер',         'Accountant',
   'Пожертвования, финансовые отчёты; персональные данные детей недоступны', 45, true, true, false),
  ('editor',     'Редактор сайта',     'Сайт редакторы',    'Site editor',
   'Публичный контент сайта; рабочая часть недоступна', 50, true, false, false),
  ('parent',     'Родитель',           'Ата-ана',           'Parent',
   'Доступ только к данным своего ребёнка', 90, false, false, true),
  ('auditor',    'Аудитор',            'Аудитор',           'Auditor',
   'Только чтение журналов; данные детей недоступны', 15, true, true, false)
ON CONFLICT (code) DO NOTHING;

-- ---- 17.3 Права ------------------------------------------------------------------------------
INSERT INTO sec.permissions (code, name_ru, category, is_sensitive) VALUES
  ('children.view_center',  'Видеть детей своего центра',           'children', true),
  ('children.create',       'Заводить карту ребёнка',               'children', true),
  ('children.edit',         'Редактировать карту ребёнка',          'children', true),
  ('children.erase',        'Обезличивать карту ребёнка',           'children', true),
  ('children.export',       'Выгружать данные о детях',             'children', true),
  ('logs.create',           'Добавлять записи о прогрессе',         'logs',     true),
  ('logs.moderate',         'Редактировать чужие записи',           'logs',     true),
  ('goals.manage',          'Управлять целями и планами',           'goals',    false),
  ('sessions.manage',       'Управлять расписанием занятий',        'sessions', false),
  ('team.manage',           'Назначать команду ребёнка',            'team',     true),
  ('documents.upload',      'Загружать документы',                  'documents',true),
  ('documents.manage',      'Управлять всеми документами',          'documents',true),
  ('consents.manage',       'Регистрировать согласия семей',        'consents', true),
  ('chat.moderate',         'Модерировать чат',                     'chat',     false),
  ('approvals.decide',      'Принимать решения по заявкам',         'approvals',true),
  ('users.view',            'Видеть список пользователей',          'users',    false),
  ('users.manage',          'Создавать и изменять пользователей',   'users',    true),
  ('security.manage',       'Управлять сессиями и блокировками',    'security', true),
  ('audit.view',            'Читать журнал аудита',                 'audit',    true),
  ('centers.manage',        'Управлять центрами',                   'centers',  false),
  ('leads.view',            'Видеть заявки с сайта',                'site',     true),
  ('leads.manage',          'Обрабатывать заявки с сайта',          'site',     true),
  ('donations.view',        'Видеть пожертвования',                 'finance',  true),
  ('donations.manage',      'Управлять пожертвованиями',            'finance',  true),
  ('content.manage',        'Редактировать контент сайта',          'site',     false),
  ('reports.publish',       'Публиковать отчёты фонда',             'site',     true)
ON CONFLICT (code) DO NOTHING;

-- ---- 17.4 Права ролей ---------------------------------------------------------------------------
--  Администратор — всё.
INSERT INTO sec.role_permissions (role_code, permission_code)
SELECT 'admin', code FROM sec.permissions
ON CONFLICT DO NOTHING;

--  Руководитель — всё, кроме управления пользователями и безопасностью.
INSERT INTO sec.role_permissions (role_code, permission_code)
SELECT 'director', code FROM sec.permissions
 WHERE code NOT IN ('users.manage', 'security.manage', 'children.erase')
ON CONFLICT DO NOTHING;

INSERT INTO sec.role_permissions (role_code, permission_code) VALUES
  ('curator', 'children.view_center'), ('curator', 'children.edit'),
  ('curator', 'logs.create'),          ('curator', 'goals.manage'),
  ('curator', 'sessions.manage'),      ('curator', 'team.manage'),
  ('curator', 'documents.upload'),     ('curator', 'consents.manage'),
  ('curator', 'users.view'),           ('curator', 'leads.view'),

  ('specialist', 'logs.create'),       ('specialist', 'goals.manage'),
  ('specialist', 'documents.upload'),  ('specialist', 'users.view'),

  ('assistant', 'logs.create'),        ('assistant', 'users.view'),

  ('accountant', 'donations.view'),    ('accountant', 'donations.manage'),
  ('accountant', 'leads.view'),

  ('editor', 'content.manage'),        ('editor', 'leads.view'),

  ('auditor', 'audit.view'),           ('auditor', 'users.view')
ON CONFLICT DO NOTHING;

-- Роль parent прав не получает вовсе: её доступ полностью описан RLS-политиками
-- (только свой ребёнок, только записи с visibility = 'parents').

-- ---- 17.5 Центры фонда ------------------------------------------------------------------------------
INSERT INTO eventum.centers (code, name, address, city, map_query, age_from, age_to, capacity, sort_order) VALUES
  ('kids',    'Urpaq Inclusive Kids',  'Звёздная, 39', 'Актобе', 'Актобе Звёздная 39',  2,  8, 60, 10),
  ('junior',  'Eventum Junior',        'Балалар, 36',  'Актобе', 'Актобе Балалар 36',   8, 18, 60, 20),
  ('group',   'Urpaq Inclusive Group', 'Звёздная, 35', 'Актобе', 'Актобе Звёздная 35',  5, 18, 40, 30),
  ('eventum', 'Eventum',               'Балалар, 21',  'Актобе', 'Актобе Балалар 21',   2, 18, 40, 40)
ON CONFLICT (code) DO NOTHING;

INSERT INTO eventum.center_translations (center_id, locale, name, address, format)
SELECT c.id, v.locale::core.locale_code, v.name, v.address, v.format
  FROM eventum.centers c
  JOIN (VALUES
    ('kids',    'ru', 'Urpaq Inclusive Kids',  'Звёздная, 39',        'Ранняя помощь и базовые навыки · 2–8 лет'),
    ('kids',    'kk', 'Urpaq Inclusive Kids',  'Звёздная көшесі, 39', 'Ерте қолдау және негізгі дағдылар · 2–8 жас'),
    ('kids',    'en', 'Urpaq Inclusive Kids',  '39 Zvezdnaya Street', 'Early support and core skills · ages 2–8'),
    ('junior',  'ru', 'Eventum Junior',        'Балалар, 36',         'Академические навыки и трудотерапия · 8+'),
    ('junior',  'kk', 'Eventum Junior',        'Балалар көшесі, 36',  'Академиялық дағдылар және еңбек терапиясы · 8+'),
    ('junior',  'en', 'Eventum Junior',        '36 Balalar Street',   'Academic skills and occupational therapy · 8+'),
    ('group',   'ru', 'Urpaq Inclusive Group', 'Звёздная, 35',        'Групповые программы и навыки самостоятельной жизни'),
    ('group',   'kk', 'Urpaq Inclusive Group', 'Звёздная көшесі, 35', 'Топтық бағдарламалар және дербес өмір дағдылары'),
    ('group',   'en', 'Urpaq Inclusive Group', '35 Zvezdnaya Street', 'Group programs and independent living skills'),
    ('eventum', 'ru', 'Eventum',               'Балалар, 21',         'Индивидуальные почасовые занятия'),
    ('eventum', 'kk', 'Eventum',               'Балалар көшесі, 21',  'Жеке сағаттық сабақтар'),
    ('eventum', 'en', 'Eventum',               '21 Balalar Street',   'Individual hourly sessions')
  ) AS v(code, locale, name, address, format) ON v.code = c.code
ON CONFLICT DO NOTHING;

-- ---- 17.6 Направления помощи -------------------------------------------------------------------------------
INSERT INTO eventum.programs (code, icon, default_duration_minutes, sort_order) VALUES
  ('aba',          'brain',   45, 10),
  ('sensory',      'spark',   45, 20),
  ('speech',       'message', 40, 30),
  ('neuropsych',   'brain',   45, 40),
  ('adaptive-pe',  'heart',   40, 50),
  ('daily-living', 'home',    60, 60),
  ('vocational',   'leaf',    60, 70),
  ('family',       'users',   60, 80)
ON CONFLICT (code) DO NOTHING;

INSERT INTO eventum.program_translations (program_id, locale, title, summary)
SELECT p.id, v.locale::core.locale_code, v.title, v.summary
  FROM eventum.programs p
  JOIN (VALUES
    ('aba',          'ru', 'ABA-терапия',              'Коммуникация, поведение, учебные и бытовые навыки на основе доказательных методов'),
    ('aba',          'kk', 'ABA терапиясы',            'Дәлелді әдістер негізінде коммуникация, мінез-құлық және дағдылар'),
    ('aba',          'en', 'ABA therapy',              'Evidence-based development of communication, behavior and daily living skills'),
    ('sensory',      'ru', 'Сенсорная интеграция',     'Сенсорная регуляция, моторика и адаптация'),
    ('sensory',      'kk', 'Сенсорлық интеграция',     'Сенсорлық реттеу, моторика және бейімделу'),
    ('sensory',      'en', 'Sensory integration',      'Sensory regulation, motor skills and adaptation'),
    ('speech',       'ru', 'Логопедические занятия',   'Развитие речи и коммуникации'),
    ('speech',       'kk', 'Логопедиялық сабақтар',    'Сөйлеу және қарым-қатынасты дамыту'),
    ('speech',       'en', 'Speech therapy',           'Speech and communication development'),
    ('neuropsych',   'ru', 'Нейропсихология',          'Внимание, память, эмоциональная регуляция'),
    ('neuropsych',   'kk', 'Нейропсихология',          'Зейін, есте сақтау, эмоционалды реттеу'),
    ('neuropsych',   'en', 'Neuropsychology',          'Attention, memory and emotional regulation'),
    ('adaptive-pe',  'ru', 'Адаптивная физкультура',   'Моторное развитие и сенсорная поддержка'),
    ('adaptive-pe',  'kk', 'Бейімделген дене шынықтыру','Моторикалық даму және сенсорлық қолдау'),
    ('adaptive-pe',  'en', 'Adaptive physical education','Motor development and sensory support'),
    ('daily-living', 'ru', 'Бытовые навыки',           'Самостоятельность в повседневной жизни'),
    ('daily-living', 'kk', 'Тұрмыстық дағдылар',       'Күнделікті өмірдегі дербестік'),
    ('daily-living', 'en', 'Daily living skills',      'Independence in everyday life'),
    ('vocational',   'ru', 'Трудовые навыки',          'Предпрофессиональная подготовка подростков'),
    ('vocational',   'kk', 'Еңбек дағдылары',          'Жасөспірімдерді кәсіпке дайындау'),
    ('vocational',   'en', 'Vocational skills',        'Pre-vocational training for teenagers'),
    ('family',       'ru', 'Сопровождение семьи',      'Консультации и поддержка родителей'),
    ('family',       'kk', 'Отбасын сүйемелдеу',       'Ата-аналарға кеңес және қолдау'),
    ('family',       'en', 'Family support',           'Counselling and parent support')
  ) AS v(code, locale, title, summary) ON v.code = p.code
ON CONFLICT DO NOTHING;

-- ---- 17.7 Типы записей в дневнике -----------------------------------------------------------------------------
INSERT INTO eventum.log_types (code, name_ru, name_kk, name_en, icon, sort_order) VALUES
  ('new-skill',    'Новый навык',      'Жаңа дағды',        'New skill',       'spark',     10),
  ('communication','Коммуникация',     'Қарым-қатынас',     'Communication',   'message',   20),
  ('daily-living', 'Бытовой навык',    'Тұрмыстық дағды',   'Daily living',    'home',      30),
  ('independence', 'Самостоятельность','Дербестік',         'Independence',    'check',     40),
  ('behavior',     'Поведение',        'Мінез-құлық',       'Behavior',        'clipboard', 50),
  ('academic',     'Учебные навыки',   'Оқу дағдылары',     'Academic skills', 'book',      60),
  ('family',       'Работа с семьёй',  'Отбасымен жұмыс',   'Family work',     'users',     70),
  ('incident',     'Инцидент',         'Оқыс жағдай',       'Incident',        'alert',     80),
  ('general',      'Общая запись',     'Жалпы жазба',       'General note',    'file',      90)
ON CONFLICT (code) DO NOTHING;

-- ---- 17.8 Направления сбора средств ------------------------------------------------------------------------------
INSERT INTO site.donation_directions (code, goal_amount, currency, sort_order) VALUES
  ('therapy-access',   NULL, 'USD', 10),
  ('sensory-equipment',NULL, 'USD', 20),
  ('playground',       NULL, 'USD', 30),
  ('greenhouse',       NULL, 'USD', 40),
  ('scholarships',     NULL, 'USD', 50)
ON CONFLICT (code) DO NOTHING;

INSERT INTO site.donation_direction_translations (direction_id, locale, title)
SELECT d.id, v.locale::core.locale_code, v.title
  FROM site.donation_directions d
  JOIN (VALUES
    ('therapy-access',    'ru', 'Терапевтическая помощь детям'),
    ('therapy-access',    'kk', 'Балаларға терапиялық көмек'),
    ('therapy-access',    'en', 'Therapy support for children'),
    ('sensory-equipment', 'ru', 'Оборудование для сенсорных залов'),
    ('sensory-equipment', 'kk', 'Сенсорлық залдарға жабдық'),
    ('sensory-equipment', 'en', 'Equipment for sensory rooms'),
    ('playground',        'ru', 'Инклюзивная детская площадка'),
    ('playground',        'kk', 'Инклюзивті балалар алаңы'),
    ('playground',        'en', 'Inclusive playground'),
    ('greenhouse',        'ru', 'Теплица и программы трудовых навыков'),
    ('greenhouse',        'kk', 'Жылыжай және еңбек дағдылары бағдарламалары'),
    ('greenhouse',        'en', 'Greenhouse and vocational programs'),
    ('scholarships',      'ru', 'Стипендии на обучение специалистов'),
    ('scholarships',      'kk', 'Мамандарды оқытуға стипендиялар'),
    ('scholarships',      'en', 'Scholarships for specialist training')
  ) AS v(code, locale, title) ON v.code = d.code
ON CONFLICT DO NOTHING;

-- ---- 17.9 Настройки сайта -----------------------------------------------------------------------------------------
INSERT INTO site.settings (key, value, description, is_public) VALUES
  ('payment_url',       '""'::jsonb,                    'HTTPS-адрес платёжного оператора. Пока пусто — сайт открывает WhatsApp.', true),
  ('phone',             '"77767504466"'::jsonb,         'Телефон и WhatsApp фонда', true),
  ('city',              '"Актобе, Казахстан"'::jsonb,   'Город', true),
  ('instagram_url',     '""'::jsonb,                    'Официальный профиль Instagram', true),
  ('instagram_endpoint','""'::jsonb,                    'Адрес прокси для ленты Instagram', false),
  ('default_locale',    '"ru"'::jsonb,                  'Язык по умолчанию', true),
  ('locales',           '["ru","kk","en"]'::jsonb,      'Доступные языки сайта', true),
  ('donation_currency', '"USD"'::jsonb,                 'Валюта формы пожертвований', true),
  ('donation_amounts',  '[5,20,50,100]'::jsonb,         'Быстрые суммы в форме', true),
  ('data_retention_years','7'::jsonb,                   'Срок хранения данных ребёнка после выпуска (уточнить у юриста)', false),
  ('document_max_bytes', '52428800'::jsonb,           'Максимальный размер файла — 50 МБ, как обещает интерфейс портала', true),
  ('document_chunk_bytes','1048576'::jsonb,           'Размер куска при загрузке файла — 1 МБ', false),
  ('document_storage_kind','"database"'::jsonb,       'Где хранить файлы: database или object_storage', false)
ON CONFLICT (key) DO NOTHING;

INSERT INTO site.stat_counters (code, value, suffix, label_ru, label_kk, label_en, sort_order) VALUES
  ('centers',    4,  NULL, 'центра в Актобе',              'Ақтөбедегі орталық',        'centers in Aktobe',            10),
  ('children',   0,  '+',  'детей в программах',           'бағдарламадағы балалар',    'children in programs',         20),
  ('team',       10, NULL, 'специалистов в профиле команды','команда профиліндегі маман','specialists in the team',      30),
  ('directions', 4,  NULL, 'ключевых направления помощи',  'негізгі көмек бағыты',      'key areas of support',         40)
ON CONFLICT (code) DO NOTHING;

-- ---- 17.10 Команда фонда (публичный раздел «Команда») ------------------------------------------------------------------
INSERT INTO site.team_members (code, full_name, sort_order) VALUES
  ('tatiana',   'Ким Татьяна Львовна',            10),
  ('nurlygul',  'Кужахметова Нурлыгуль Еркиновна',20),
  ('asem',      'Жулкаева Асем Ерболовна',        30),
  ('aliya',     'Хегай Алия Маликовна',           40),
  ('gleb',      'Шайхин Глеб Ермекович',          50),
  ('natali',    'Ким Натали Вячеславовна',        60),
  ('akmaral',   'Бурушева Акмарал Талгатовна',    70),
  ('alena',     'Аветикова Алена Ильинична',      80),
  ('anastasia', 'Адамович Анастасия Анатольевна', 90),
  ('marina',    'Ломако Марина Вячеславовна',    100)
ON CONFLICT (code) DO NOTHING;

INSERT INTO site.team_member_translations (member_id, locale, full_name, role_title, experience, achievement)
SELECT m.id, 'ru'::core.locale_code, v.full_name, v.role_title, v.experience, v.achievement
  FROM site.team_members m
  JOIN (VALUES
    ('tatiana',   'Ким Татьяна Львовна',            'Основатель фонда Urpaq Inclusive и сети центров',
     'Создание системы помощи детям и подросткам с особенностями развития, поддержка семей и развитие инклюзивного общества.',
     'Стратегическое руководство проектами фонда и сети центров Urpaq Inclusive и Eventum.'),
    ('nurlygul',  'Кужахметова Нурлыгуль Еркиновна','Исполнительный директор сети центров',
     'Управление деятельностью центров, координация команд и контроль качества помощи.',
     'Развитие программ и единой системы работы Urpaq Inclusive и Eventum.'),
    ('asem',      'Жулкаева Асем Ерболовна',        'Руководитель проектов развития',
     'Внедрение новых направлений, образовательных и социальных программ.',
     'Координация перспективных проектов развития сети центров.'),
    ('aliya',     'Хегай Алия Маликовна',           'Руководитель Kids, специалист раннего развития',
     'Ранняя помощь детям с особенностями развития и сопровождение семей на первых этапах.',
     'Руководство центром Kids и маршрутом ранней коррекционной помощи.'),
    ('gleb',      'Шайхин Глеб Ермекович',          'Куратор сенсорной интеграции',
     'Развитие сенсорной регуляции, моторных навыков и адаптации детей.',
     'Методическое сопровождение направления сенсорной интеграции.'),
    ('natali',    'Ким Натали Вячеславовна',        'Нейропсихолог',
     'Развитие когнитивных функций, внимания, памяти и эмоциональной регуляции.',
     'Нейропсихологическое сопровождение детей с особенностями развития.'),
    ('akmaral',   'Бурушева Акмарал Талгатовна',    'Куратор поведенческой терапии Junior',
     'Развитие самостоятельности, социальной адаптации и поведенческих навыков.',
     'Координация поведенческих программ для детей и подростков центра Junior.'),
    ('alena',     'Аветикова Алена Ильинична',      'Куратор логопедических программ',
     'Развитие речи, коммуникации и помощь при речевых и коммуникативных трудностях.',
     'Методическое сопровождение логопедических программ центра.'),
    ('anastasia', 'Адамович Анастасия Анатольевна', 'Куратор индивидуальных программ Eventum',
     'Индивидуальные занятия и развитие функциональных, коммуникативных и жизненных навыков.',
     'Координация индивидуального маршрута ребёнка в формате Eventum.'),
    ('marina',    'Ломако Марина Вячеславовна',     'Специалист адаптивной физкультуры',
     'Адаптивная физическая культура, развитие моторики и сенсорная поддержка.',
     'Сопровождение двигательного развития и адаптации детей.')
  ) AS v(code, full_name, role_title, experience, achievement) ON v.code = m.code
ON CONFLICT DO NOTHING;

-- ---- 17.11 Частые вопросы ----------------------------------------------------------------------------------------------
INSERT INTO site.faq_items (code, category, sort_order) VALUES
  ('age-range',    'general',   10),
  ('conditions',   'general',   20),
  ('directions',   'programs',  30),
  ('first-visit',  'general',   40),
  ('training',     'training',  50),
  ('donations',    'donations', 60)
ON CONFLICT (code) DO NOTHING;

INSERT INTO site.faq_translations (item_id, locale, question, answer)
SELECT f.id, 'ru'::core.locale_code, v.q, v.a
  FROM site.faq_items f
  JOIN (VALUES
    ('age-range',  'С какого возраста вы принимаете детей?',
     'Мы работаем с детьми раннего возраста, школьниками и подростками. Программа подбирается индивидуально после первичной консультации.'),
    ('conditions', 'С какими особенностями развития вы работаете?',
     'Мы сопровождаем детей с РАС, задержкой психоречевого и психического развития, синдромом Дауна, интеллектуальными нарушениями и другими особенностями развития.'),
    ('directions', 'Какие направления помощи доступны?',
     'ABA-терапия, логопедические занятия, сенсорная интеграция, нейропсихология, адаптивная физкультура, бытовые и трудовые навыки, сопровождение семьи.'),
    ('first-visit','Как проходит первый визит?',
     'Первичная консультация, оценка потребностей и составление индивидуального маршрута вместе с семьёй.'),
    ('training',   'Можно ли пройти обучение или стажировку?',
     'Да. Фонд принимает специалистов и студентов на стажировки, супервизии и тренинги. Расписание согласовывается после заявки.'),
    ('donations',  'Как фонд отчитывается о пожертвованиях?',
     'Публикуются утверждённые годовые и проектные отчёты. Имена доноров показываются только при согласии донора.')
  ) AS v(code, q, a) ON v.code = f.code
ON CONFLICT DO NOTHING;

-- ---- 17.12 Секции журнала аудита ------------------------------------------------------------------------------------------
--  Основные секции заведены в разделе 04, до первых записей. Здесь — запас на год вперёд.
SELECT audit.create_monthly_partitions(
         (date_trunc('month', current_date) + interval '1 month')::date, 12) AS created_partitions;

-- ---- 17.13 Учётные записи ------------------------------------------------------------------------------------------------
--  ВНИМАНИЕ — ЭТО ВАЖНО.
--
--  В README.txt проекта опубликованы демонстрационные пароли (admin / Urpaq2026! и др.).
--  Файл лежит в репозитории, значит эти пароли известны всем. Поэтому учётные записи
--  ниже создаются БЕЗ пароля: password_hash = NULL, войти по ним невозможно.
--
--  Пароль задаёт администратор после установки, по защищённому каналу:
--
--      SELECT sec.set_password(
--               (SELECT id FROM sec.users WHERE username = 'admin'),
--               '<надёжный пароль>',
--               NULL, 'initial', NULL, true);   -- true = сменить при первом входе
--
--  Пароль в этот файл не вписывать: он попадёт в git, в дампы и в журналы psql.

INSERT INTO sec.users (username, last_name, first_name, display_name, job_title,
                       role_code, primary_center_id, has_all_centers_access,
                       email, locale, must_change_password, password_hash)
SELECT v.username, v.last_name, v.first_name, v.display_name, v.job_title,
       v.role_code, c.id, v.all_centers, v.email, 'ru'::core.locale_code, true, NULL
  FROM (VALUES
    ('admin',      'Администратор', 'Системный', 'Администратор Urpaq', 'Администратор системы',
     'admin',      NULL,      true,  'admin@urpaq-inclusive.kz'),
    ('director',   'Ким',         'Татьяна',    'Татьяна Львовна',      'Основатель фонда',
     'director',   NULL,      true,  'director@urpaq-inclusive.kz'),
    ('curator.junior','Куратор',  'Ержан',      'Куратор Ержан',        'Куратор центра Junior',
     'curator',    'junior',  false, NULL),
    ('specialist.group','Специалист','Максим',  'Специалист Максим',    'Специалист центра Group',
     'specialist', 'group',   false, NULL),
    ('auditor',    'Аудитор',     'Внешний',    'Аудитор',              'Внешний аудитор',
     'auditor',    NULL,      true,  NULL)
  ) AS v(username, last_name, first_name, display_name, job_title, role_code, center_code, all_centers, email)
  LEFT JOIN eventum.centers c ON c.code = v.center_code
ON CONFLICT (username) DO NOTHING;


-- ---- 17.14 Списочные секции сайта ------------------------------------------------------------------------------
INSERT INTO site.content_blocks (section, code, icon, sort_order) VALUES
  ('trust', 'centers',        'home',  10),
  ('trust', 'team',           'users', 20),
  ('trust', 'methods',        'brain', 30),
  ('trust', 'learning',       'book',  40),
  ('trust', 'transparency',   'file',  50),
  ('standards', 'purpose',    NULL,    10),
  ('standards', 'budget',     NULL,    20),
  ('standards', 'coordinator',NULL,    30),
  ('standards', 'report',     NULL,    40),
  ('join_options', 'sponsor',       'heart',     10),
  ('join_options', 'partner',       'users',     20),
  ('join_options', 'media-partner', 'camera',    30),
  ('join_options', 'volunteer',     'briefcase', 40),
  ('opportunities', 'education',  'book',   10),
  ('opportunities', 'social',     'users',  20),
  ('opportunities', 'media',      'camera', 30),
  ('opportunities', 'partnership','heart',  40),
  ('training_audience', 'beginners',     NULL, 10),
  ('training_audience', 'teachers',      NULL, 20),
  ('training_audience', 'aba',           NULL, 30),
  ('training_audience', 'students',      NULL, 40),
  ('training_audience', 'international', NULL, 50),
  ('contact_topics', 'consultation', NULL, 10),
  ('contact_topics', 'program-info', NULL, 20),
  ('contact_topics', 'internship',   NULL, 30),
  ('contact_topics', 'volunteer',    NULL, 40),
  ('contact_topics', 'partnership',  NULL, 50),
  ('contact_topics', 'other',        NULL, 60)
ON CONFLICT (section, code) DO NOTHING;

INSERT INTO site.content_block_translations (block_id, locale, title, text)
SELECT b.id, 'ru'::core.locale_code, v.title, v.text
  FROM site.content_blocks b
  JOIN (VALUES
    ('trust','centers',      '4 специализированных центра', 'Все форматы помощи собраны в одной системе в Актобе.'),
    ('trust','team',         'Междисциплинарная команда',   'Специалисты разных направлений работают вокруг общего плана.'),
    ('trust','methods',      'Современные методы',          'Работа опирается на доказательные подходы и практическую оценку.'),
    ('trust','learning',     'Непрерывное обучение',        'Стажировки, супервизии и обмен профессиональным опытом.'),
    ('trust','transparency', 'Прозрачность',                'Отчёты и доноры публикуются только после подтверждения данных.'),
    ('standards','purpose',     'цель и аудитория',            NULL),
    ('standards','budget',      'утверждённый бюджет',         NULL),
    ('standards','coordinator', 'ответственный координатор',   NULL),
    ('standards','report',      'публичный итоговый отчёт',    NULL),
    ('join_options','sponsor',       'Спонсор',                 NULL),
    ('join_options','partner',       'Партнёр',                 NULL),
    ('join_options','media-partner', 'Информационный партнёр',  NULL),
    ('join_options','volunteer',     'Волонтёр',                NULL),
    ('opportunities','education',   'Образовательные события', 'Помощь в организации тренингов, встреч и материалов.'),
    ('opportunities','social',      'Социальные проекты',      'Поддержка мероприятий и программ самостоятельности.'),
    ('opportunities','media',       'Медиа и события',         'Фото, видео, дизайн и коммуникации с соблюдением согласий.'),
    ('opportunities','partnership', 'Партнёрская помощь',      'Сбор ресурсов и развитие благотворительных инициатив.'),
    ('training_audience','beginners',     'начинающим специалистам',       NULL),
    ('training_audience','teachers',      'педагогам и психологам',        NULL),
    ('training_audience','aba',           'ABA-терапистам',                NULL),
    ('training_audience','students',      'студентам профильных направлений', NULL),
    ('training_audience','international', 'международным волонтёрам',      NULL),
    ('contact_topics','consultation', 'Записаться на консультацию',  NULL),
    ('contact_topics','program-info', 'Уточнить программу центра',   NULL),
    ('contact_topics','internship',   'Подать заявку на стажировку', NULL),
    ('contact_topics','volunteer',    'Стать волонтёром',            NULL),
    ('contact_topics','partnership',  'Корпоративное партнёрство',   NULL),
    ('contact_topics','other',        'Другой вопрос',               NULL)
  ) AS v(section, code, title, text) ON v.section = b.section AND v.code = b.code
ON CONFLICT DO NOTHING;

-- ---- 17.15 Юридические документы ---------------------------------------------------------------------------------
--  Заводятся как ЧЕРНОВИКИ (is_current = false, approved_at пуст). Сайт сам пишет, что
--  политика и оферта фондом ещё не утверждены, — база это состояние честно повторяет и
--  не даст выставить неутверждённый текст как действующий.
INSERT INTO site.legal_documents (code, kind, version, effective_from, is_current) VALUES
  ('privacy-policy', 'privacy_policy', '1.0-draft', current_date, false),
  ('public-offer',   'public_offer',   '1.0-draft', current_date, false),
  ('consent-data',   'consent_form',   '1.0-draft', current_date, false),
  ('consent-photo',  'consent_form',   '1.0-draft', current_date, false)
ON CONFLICT (code, version) DO NOTHING;

INSERT INTO site.legal_document_translations (legal_id, locale, title, body)
SELECT d.id, 'ru'::core.locale_code, v.title, v.body
  FROM site.legal_documents d
  JOIN (VALUES
    ('privacy-policy', 'Политика конфиденциальности',
     'ЧЕРНОВИК. Юридически утверждённая политика фонда ещё не передана для публикации. Перед публичным запуском форм и платежей фонд обязан утвердить порядок обработки, хранения и удаления персональных данных, включая данные о здоровье детей.'),
    ('public-offer', 'Публичная оферта',
     'ЧЕРНОВИК. Официальная публичная оферта и правила возврата должны быть утверждены фондом и платёжным оператором. До этого момента сайт не подтверждает пожертвование самостоятельно и не показывает неподтверждённые платежи как реальные.'),
    ('consent-data', 'Согласие на обработку персональных данных',
     'ЧЕРНОВИК. Текст согласия законного представителя на обработку персональных данных ребёнка, включая сведения о здоровье. Подлежит утверждению юристом фонда.'),
    ('consent-photo', 'Согласие на публикацию фото и видео',
     'ЧЕРНОВИК. Текст согласия на публикацию изображений ребёнка в материалах фонда. Подлежит утверждению юристом фонда.')
  ) AS v(code, title, body) ON v.code = d.code
ON CONFLICT DO NOTHING;

-- ---- 17.16 Тексты интерфейса ---------------------------------------------------------------------------------------
--  Здесь заведён базовый словарь. Полный перенос делается одним вызовом из существующего
--  скрипта, без ручного набора сотен строк:
--
--      SELECT site.import_ui_strings('site',   'ru', '<объект locales.ru из foundation.html>'::jsonb);
--      SELECT site.import_ui_strings('site',   'kk', '<объект locales.kk>'::jsonb);
--      SELECT site.import_ui_strings('site',   'en', '<объект locales.en>'::jsonb);
--      SELECT site.import_ui_strings('portal', 'ru', '<объект tx.ru из staff-portal.html>'::jsonb);
--
--  Вложенные ключи разворачиваются сами: {"nav":{"about":"О фонде"}} → nav.about.

SELECT site.import_ui_strings('site', 'ru', jsonb_build_object(
  'brand',    jsonb_build_object('sub', 'общественный фонд'),
  'nav',      jsonb_build_object('about','О фонде','centers','Центры','help','Направления',
                                 'team','Команда','training','Обучение','reports','Отчётность','contacts','Контакты'),
  'actions',  jsonb_build_object('support','Поддержать','help','Получить помощь','training','Пройти обучение',
                                 'supportFund','Поддержать фонд','internship','Подать заявку на стажировку',
                                 'volunteer','Стать волонтёром'),
  'form',     jsonb_build_object('name','Имя','phone','Номер телефона','topic','Тема обращения',
                                 'message','Комментарий','send','Отправить заявку',
                                 'consent','Согласен(на) на обработку данных для ответа на обращение.'),
  'contacts', jsonb_build_object('phone','Телефон и WhatsApp','city','Город','whatsapp','Написать в WhatsApp',
                                 'formTitle','Записаться на консультацию'),
  'donate',   jsonb_build_object('title','Ваш вклад меняет качество помощи','formTitle','Выберите сумму',
                                 'custom','Другая сумма','anonymous','Анонимно','public','Показать имя',
                                 'pay','Перейти к оплате')
)) AS strings_ru;

SELECT site.import_ui_strings('site', 'kk', jsonb_build_object(
  'nav',     jsonb_build_object('about','Қор туралы','centers','Орталықтар','help','Бағыттар',
                                'team','Команда','training','Оқыту','reports','Есептілік','contacts','Байланыс'),
  'actions', jsonb_build_object('support','Қолдау','help','Көмек алу','training','Оқудан өту'),
  'form',    jsonb_build_object('name','Аты','phone','Телефон нөмірі','topic','Өтініш тақырыбы',
                                'message','Пікір','send','Өтінім жіберу')
)) AS strings_kk;

SELECT site.import_ui_strings('site', 'en', jsonb_build_object(
  'nav',     jsonb_build_object('about','About','centers','Centers','help','Programs',
                                'team','Team','training','Training','reports','Transparency','contacts','Contacts'),
  'actions', jsonb_build_object('support','Support','help','Get help','training','Join training'),
  'form',    jsonb_build_object('name','Name','phone','Phone number','topic','Topic',
                                'message','Comment','send','Send request')
)) AS strings_en;

SELECT site.import_ui_strings('portal', 'ru', jsonb_build_object(
  'documents',    'Документы',
  'uploadDocument','Добавить файл',
  'dropFiles',    'Перетащите файлы сюда',
  'fileLimit',    'Изображения, видео, PDF и документы до 50 МБ',
  'noDocuments',  'Пока документов нет',
  'fileSaved',    'Файл добавлен',
  'fileDeleted',  'Файл удалён',
  'fileTooLarge', 'Файл превышает лимит 50 МБ',
  'newLog',       'Новая запись',
  'todaySessions','Занятия сегодня',
  'requestAccess','Запросить доступ',
  'logout',       'Выход'
)) AS strings_portal_ru;

-- =====================================================================================
--  РАЗДЕЛ 18. ПРОВЕРКА УСТАНОВКИ
-- =====================================================================================

\echo ''
\echo '>>> Проверка установки:'

SELECT 'Схемы'          AS "Объект", count(*)::text AS "Создано"
  FROM information_schema.schemata WHERE schema_name IN ('core','sec','eventum','site','audit')
UNION ALL
SELECT 'Таблицы',        count(*)::text FROM information_schema.tables
 WHERE table_schema IN ('core','sec','eventum','site','audit') AND table_type = 'BASE TABLE'
UNION ALL
SELECT 'Представления',  count(*)::text FROM information_schema.views
 WHERE table_schema IN ('core','sec','eventum','site','audit')
UNION ALL
SELECT 'Функции',        count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname IN ('core','sec','eventum','site','audit')
UNION ALL
SELECT 'Триггеры',       count(*)::text FROM pg_trigger WHERE NOT tgisinternal
UNION ALL
SELECT 'RLS-политики',   count(*)::text FROM pg_policies
 WHERE schemaname IN ('sec','eventum','site')
UNION ALL
SELECT 'Индексы',        count(*)::text FROM pg_indexes
 WHERE schemaname IN ('core','sec','eventum','site','audit')
UNION ALL
SELECT 'Роли БД',        count(*)::text FROM pg_roles WHERE rolname LIKE 'eventum%'
UNION ALL
SELECT 'Центры',         count(*)::text FROM eventum.centers
UNION ALL
SELECT 'Направления',    count(*)::text FROM eventum.programs
UNION ALL
SELECT 'Роли портала',   count(*)::text FROM sec.roles
UNION ALL
SELECT 'Права',          count(*)::text FROM sec.permissions
UNION ALL
SELECT 'Пользователи',   count(*)::text FROM sec.users;

\echo ''
\echo '======================================================================'
\echo '  База данных EVENTUM установлена.'
\echo ''
\echo '  СЛЕДУЮЩИЕ ШАГИ (обязательные):'
\echo '   1. Сменить пароли ролей eventum_app / eventum_readonly /'
\echo '      eventum_auditor / eventum_backup — сейчас там заглушки CHANGE_ME.'
\echo '   2. Задать пароль администратора через sec.set_password().'
\echo '   3. Включить TLS: hostssl в pg_hba.conf, sslmode=verify-full в приложении.'
\echo '   4. Проверить log_statement = ddl (НЕ all — иначе пароли попадут в логи).'
\echo '   5. Настроить резервное копирование по регламенту из раздела 15.'
\echo '   6. Подключить приложение ролью eventum_app и вызывать sec.begin_request()'
\echo '      в начале каждого запроса — без этого RLS не пропустит ни одной строки.'
\echo '======================================================================'
