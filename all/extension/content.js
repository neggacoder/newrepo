/* Suerte / Aqbobek — content.js  (v11)
 * ─────────────────────────────────────────────────────────────────────────
 * Мини-виджет в углу страницы врача. Слушает wake-word (Web Speech API),
 * записывает голосовую команду (MediaRecorder), отправляет её на сервер Vox
 * для транскрипции (Whisper от OpenAI), затем туда же за инструкциями, и выполняет
 * полученные действия на странице (click / write / writeByClick), включая
 * многошаговые и многостраничные сценарии.
 *
 * Сервер ОДИН и локальный (vox_server на машине врача) — раньше их было два,
 * локальный и «мозг» на VPS.
 *
 * Дизайн DOM повторяет example.html; стили — panel.css.
 * Вся сеть идёт через background.js (mixed-content обход).
 * ───────────────────────────────────────────────────────────────────────── */
(function () {
  'use strict';
  if (window.__aqbobekInjected) return;
  window.__aqbobekInjected = true;

  /* ════════════════════════════════════════════════════════════════════
   *  КОНФИГ
   * ════════════════════════════════════════════════════════════════════ */
  const CONFIG_KEY = 'aqbobek_config';
  const LOG_KEY = 'aqbobek_log';
  const PENDING_KEY = 'aqbobek_pending_plan';
  const REC_KEY = 'aqbobek_recording';       // активный буфер записи (обучение)
  const SAME_TAB_ATTR = 'data-aq-same-tab';  // флаг для aq-same-tab.js (MAIN-мир)
  const SAME_TAB_EVT = 'aq-same-tab-open';   // он же сообщает о перехвате window.open

  const DEFAULTS = {
    triggers: {
      wake:     ['алиса', 'агент', 'работник', 'ассистент'],
      sleep:    ['спи', 'отдыхай', 'выключись'],
      send:     ['отправь', 'отправить', 'готово'],
      stop:     ['отмена', 'стоп', 'отмени'],
      settings: ['настройки', 'настройка']
    },
    silenceMs: 900,            // тишина перед авто-отправкой
    armTimeoutMs: 7000,        // сколько ждём голос после wake-word
    provider: 'qwen',          // qwen | openai | deepseek — только LLM; речь распознаёт всегда OpenAI
    // Ключ servers.local сохранён как есть: он уже лежит в chrome.storage у
    // установленных расширений. Бывший servers.main больше не читается.
    servers: {
      local: { url: 'http://127.0.0.1', port: 8000 }
    },
    confirmBeforeSend: true,   // плашка «Отправить голосовое?» Да/Нет/Дозаписать
    dynamicPages: [],          // конкретные СТРАНИЦЫ (URL/путь), где нужен скан локальным сервером
    dynamicDomains: [],        // целые САЙТЫ (по домену) — совпадение по hostname, без учёта пути
    listenOnStart: false,      // включать ли wake-word слушатель при загрузке
    lang: 'ru-RU',             // язык распознавания Web Speech
    theme: '',                 // тема панели (data-theme)
    narrator: false,           // озвучка ответов (TTS)
    debug: false,              // режим отладки: verbose-записи в лог (включается в настройках)
    volume: 1
  };

  let CFG = Object.assign({}, DEFAULTS);

  function deepMerge(base, over) {
    const out = Array.isArray(base) ? base.slice() : Object.assign({}, base);
    for (const k in (over || {})) {
      if (over[k] && typeof over[k] === 'object' && !Array.isArray(over[k]) && typeof base[k] === 'object') {
        out[k] = deepMerge(base[k], over[k]);
      } else if (over[k] !== undefined) {
        out[k] = over[k];
      }
    }
    return out;
  }

  function loadConfig() {
    return new Promise((resolve) => {
      chrome.storage.local.get(CONFIG_KEY, (store) => {
        CFG = deepMerge(DEFAULTS, store[CONFIG_KEY] || {});
        resolve(CFG);
      });
    });
  }
  function saveConfig() {
    chrome.storage.local.set({ [CONFIG_KEY]: CFG });
  }

  // Реагируем на изменения конфига из страницы настроек
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes[CONFIG_KEY]) {
      CFG = deepMerge(DEFAULTS, changes[CONFIG_KEY].newValue || {});
      applyConfigToUI();
    }
    /* Очередь шагов общая для всех вкладок. Если план доигрывают в ДРУГОЙ
       вкладке (так бывает, когда кнопка Damumed всё-таки открыла новую) или он
       вообще завершён — в этой вкладке ждать уже нечего, а бейдж «Ждёт: …»
       так и висел бы до перезагрузки страницы. Снимаем его по факту изменения
       очереди, а не по догадке. */
    if (area === 'local' && changes[PENDING_KEY]) {
      const p = changes[PENDING_KEY].newValue;
      const live = !!(p && p.steps && p.index < p.steps.length);
      _sameTabPending = live;
      _sameTabArmedAt = (p && p.armedAt) || _sameTabArmedAt;
      applySameTabMode();
      // Бейдж «Ждёт: …» имеет право рисовать только та вкладка, которая сама
      // двигает план. Если запись пришла ИЗ ДРУГОЙ вкладки (кнопка Damumed всё
      // же открыла новую, и план уехал туда) или план завершён — здесь ждать
      // уже нечего, а надпись иначе висела бы до перезагрузки страницы.
      if (!live || pendingMark(p) !== _pendingWriteMark) showChain(null);
    }
    if (area === 'local' && changes[REC_KEY]) {
      const rec = changes[REC_KEY].newValue;
      S.recording = !!(rec && rec.active);
      applySameTabMode();
      updateRecUi(rec && rec.steps ? rec.steps.length : 0);
    }
  });

  /* ════════════════════════════════════════════════════════════════════
   *  СВЯЗЬ С BACKGROUND (сеть)
   * ════════════════════════════════════════════════════════════════════ */
  function bg(type, payload) {
    const started = Date.now();
    dbg('→ ' + type, preview(payload));
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage(Object.assign({ type }, payload || {}), (res) => {
        const ms = Date.now() - started;
        if (chrome.runtime.lastError) {
          dbg('✗ ' + type + ' (' + ms + ' мс)', chrome.runtime.lastError.message);
          return reject(new Error(chrome.runtime.lastError.message));
        }
        if (!res) {
          dbg('✗ ' + type + ' (' + ms + ' мс)', 'нет ответа от background');
          return reject(new Error('Нет ответа от background'));
        }
        if (!res.ok) {
          dbg('✗ ' + type + ' (' + ms + ' мс)', res.error || 'ошибка сети');
          return reject(new Error(res.error || 'Ошибка сети'));
        }
        dbg('← ' + type + ' (' + ms + ' мс)', preview(res.data));
        resolve(res.data);
      });
    });
  }

  /* ════════════════════════════════════════════════════════════════════
   *  DOM-ШАБЛОН  (повторяет example.html)
   * ════════════════════════════════════════════════════════════════════ */
  const ICON = {
    leaf: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>',
    logo: '<svg viewBox="0 0 349 341" fill="none"><g transform="translate(0,341) scale(0.1,-0.1)" fill="currentColor" stroke="none"><path d="M1350 2490 l0 -380 -380 0 -380 0 0 -400 0 -400 380 0 380 0 0 -380 0 -380 400 0 400 0 0 365 c0 237 -4 365 -10 365 -5 0 -10 -4 -10 -8 0 -4 -20 -18 -45 -30 l-45 -22 -2 -277 -3 -278 -285 0 -285 0 -3 378 -2 377 -380 0 -380 0 0 290 0 290 380 0 380 0 2 378 3 377 285 0 285 0 3 -271 2 -271 55 15 55 15 0 314 0 313 -400 0 -400 0 0 -380z"></path><path d="M2395 2369 c-11 -6 -30 -25 -43 -43 l-22 -33 2 -596 3 -597 31 -31 c59 -58 164 -48 199 21 23 44 23 1186 0 1230 -27 52 -113 77 -170 49z m83 -91 c9 -9 12 -149 12 -569 0 -487 -2 -560 -15 -573 -24 -23 -43 -9 -50 37 -9 61 -1 1090 8 1105 10 15 29 16 45 0z"></path><path d="M2079 2105 c-14 -8 -35 -27 -45 -42 -17 -26 -19 -53 -22 -325 -3 -240 -6 -299 -18 -309 -11 -9 -17 -9 -29 1 -12 10 -15 48 -15 222 0 220 -6 254 -48 291 -11 10 -39 21 -63 24 -79 11 -139 -44 -139 -129 0 -83 29 -78 -455 -80 l-430 -3 -3 -47 -3 -48 440 0 c247 0 450 4 464 9 40 16 70 67 76 134 4 41 11 63 23 71 37 23 43 -4 48 -242 3 -125 9 -235 14 -244 13 -27 70 -58 107 -58 19 0 49 9 67 20 58 36 62 57 62 373 0 245 2 286 16 297 12 11 18 11 29 -1 12 -11 15 -62 15 -258 1 -137 6 -253 11 -263 13 -25 65 -24 79 1 6 12 10 115 10 266 0 210 -3 252 -17 282 -30 65 -112 92 -174 58z"></path></g></svg>',
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>',
    mic: '<svg viewBox="0 0 32 32" fill="none"><rect x="11" y="3" width="10" height="16" rx="5" fill="currentColor" opacity=".15" stroke="currentColor" stroke-width="1.8"></rect><path d="M16 19a6 6 0 0 0 6-6V9" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"></path><path d="M10 13v0a6 6 0 0 0 12 0" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"></path><line x1="16" y1="25" x2="16" y2="29" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"></line><line x1="12" y1="29" x2="20" y2="29" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"></line></svg>',
    send: '<svg viewBox="0 0 32 32" fill="none"><path d="M28 4L4 14l9 4 4 9 11-23Z" fill="currentColor" opacity=".18" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"></path><line x1="13" y1="18" x2="28" y2="4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"></line></svg>',
    stop: '<svg viewBox="0 0 24 24" fill="none"><rect x="4" y="4" width="16" height="16" rx="3" fill="currentColor"></rect></svg>',
    close: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2.5" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>',
    expand: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 3 21 3 21 9"></polyline><polyline points="9 21 3 21 3 15"></polyline><line x1="21" y1="3" x2="14" y2="10"></line><line x1="3" y1="21" x2="10" y2="14"></line></svg>',
    shrink: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 14 10 14 10 20"></polyline><polyline points="20 10 14 10 14 4"></polyline><line x1="10" y1="14" x2="3" y2="21"></line><line x1="21" y1="3" x2="14" y2="10"></line></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline></svg>',
    reqTab: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></svg>',
    scanTab: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"></path><rect x="7" y="7" width="10" height="10" rx="1"></rect></svg>',
    bolt: '<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon></svg>',
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>',
    wave: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path></svg>'
  };

  function template() {
    return `
<div id="aq-bubble"><div id="aq-bubble-ring"></div><div id="aq-bubble-logo">${ICON.logo}</div></div>
<div id="aq-corner"><div id="aq-corner-logo">${ICON.logo}</div><div id="aq-corner-reply"></div><div id="aq-corner-dot"></div></div>
<div id="aq-corner-hear" style="display:none"></div>
<div id="aq-chain-badge" style="display:none"><span id="aq-chain-badge-dot"></span><span id="aq-chain-badge-name"></span></div>
<div id="aq-rec-badge" style="display:none"><span id="aq-rec-badge-dot"></span><span id="aq-rec-badge-text"></span></div>
<div id="aq-panel">
  <div id="aq-head">
    <div id="aq-drag-dots"><em></em><em></em></div>
    <button id="aq-settings-btn" title="Настройки"><span class="aq-js-btn-icon">${ICON.gear}</span></button>
    <div id="aq-head-logo">${ICON.logo}</div>
    <span id="aq-head-title">Suerte</span>
    <div id="aq-dot"></div>
    <button id="aq-toggle-size" title="Развернуть / свернуть"><span class="ico-exp">${ICON.expand}</span><span class="ico-shr">${ICON.shrink}</span></button>
    <button id="aq-panel-close" title="Свернуть в угол">${ICON.close}</button>
    <div id="aq-pos-popup" style="display:none">
      <button class="aq-pos-opt" data-pos="bottom-right">↘ Правый нижний</button>
      <button class="aq-pos-opt" data-pos="bottom-left">↙ Левый нижний</button>
      <button class="aq-pos-opt" data-pos="top-right">↗ Правый верхний</button>
      <button class="aq-pos-opt" data-pos="top-left">↖ Левый верхний</button>
    </div>
  </div>
  <div id="aq-compact-zone">
    <div id="aq-input-wrap">
      <textarea id="aq-text" placeholder="Введите команду или нажмите микрофон..."></textarea>
      <div id="aq-right-btns">
        <button id="aq-mic-btn" title="Голосовой ввод">${ICON.mic}</button>
        <button id="aq-send-btn" title="Отправить">${ICON.send}<span>Отпр.</span></button>
      </div>
      <button id="aq-cancel-btn" title="Отменить" style="display:none">${ICON.stop}</button>
    </div>
    <div id="aq-voice-bar" style="display:none">
      <div id="aq-voice-bar-row">
        <span id="aq-voice-rec"><span id="aq-voice-rec-dot"></span>REC</span>
        <div id="aq-voice-waves"></div>
        <span id="aq-voice-timer">0:00</span>
      </div>
      <span id="aq-voice-interim"></span>
    </div>
    <div id="aq-mic-denied-bar" style="display:none">Нет доступа к микрофону — проверь настройки браузера</div>
    <div id="aq-listen-off-bar" style="display:none">Wake-word выключен — нажми СПИТ или Alt+M чтобы включить</div>
    <div id="aq-run-progress" style="display:none">
      <div id="aq-run-progress-header"><span id="aq-run-step-label"></span><span id="aq-run-step-count"></span></div>
      <div id="aq-run-progress-track"><div id="aq-run-progress-bar"></div></div>
      <div id="aq-run-route-summary"></div>
    </div>
    <div id="aq-last-reply" style="display:none">
      <div id="aq-last-reply-icon">${ICON.check}</div>
      <span id="aq-last-reply-text"></span>
    </div>
  </div>
  <div id="aq-expanded-zone">
    <div id="aq-tabs">
      <button class="aq-tab active" data-tab="request">${ICON.reqTab} Ответ</button>
      <button class="aq-tab" data-tab="scan">${ICON.scanTab} Сканер</button>
      <button class="aq-tab" data-tab="ocr">${ICON.scanTab} OCR</button>
      <button class="aq-tab" data-tab="templates">${ICON.bolt} Шаблоны</button>
    </div>
    <div id="aq-tab-body">
      <div class="aq-tab-panel active" id="tab-request"><div id="aq-chat"></div></div>
      <div class="aq-tab-panel" id="tab-scan">
        <div id="aq-stats">
          <div class="aq-stat"><span id="stat-fields">0</span><small>Поля</small></div>
          <div class="aq-stat"><span id="stat-btns">0</span><small>Кнопки</small></div>
          <div class="aq-stat"><span id="stat-all">0</span><small>Всего</small></div>
        </div>
        <button id="aq-scan-btn" class="aq-btn-green">${ICON.bolt} Сканировать страницу</button>
        <button id="aq-medrec-btn" class="aq-btn-green" style="display:none">${ICON.bolt} Заполнить мед. запись</button>
        <div id="aq-dom-list"></div>
      </div>
      <div class="aq-tab-panel" id="tab-ocr">
        <div id="aq-ocr-inner">
          <div id="aq-ocr-drop" tabindex="0" role="button" aria-label="Загрузить файл для OCR">
            <span id="aq-ocr-drop-icon">${ICON.scanTab}</span>
            <span id="aq-ocr-drop-title">Перетащите файл сюда</span>
            <span id="aq-ocr-drop-sub">или нажмите, чтобы выбрать &nbsp;·&nbsp; PDF, DOCX, PNG, JPG</span>
            <span id="aq-ocr-drop-file"></span>
          </div>
          <input id="aq-ocr-file" type="file" accept=".pdf,.docx,.png,.jpg,.jpeg,.tif,.tiff,.bmp" style="display:none">
          <div id="aq-ocr-steps">
            <div class="aq-ocr-step" data-step="upload" data-state="idle">
              <span class="aq-ocr-step-circle">${ICON.check}</span>
              <span class="aq-ocr-step-label">Загрузка файла</span>
            </div>
            <div class="aq-ocr-step" data-step="recognize" data-state="idle">
              <span class="aq-ocr-step-circle">${ICON.check}</span>
              <span class="aq-ocr-step-label">Распознавание текста</span>
            </div>
            <div class="aq-ocr-step" data-step="template" data-state="idle">
              <span class="aq-ocr-step-circle">${ICON.check}</span>
              <span class="aq-ocr-step-label">Подбор шаблона</span>
            </div>
            <div class="aq-ocr-step" data-step="done" data-state="idle">
              <span class="aq-ocr-step-circle">${ICON.check}</span>
              <span class="aq-ocr-step-label">Готово</span>
            </div>
          </div>
          <div id="aq-ocr-result"></div>
        </div>
      </div>
      <div class="aq-tab-panel" id="tab-templates">
        <div id="aq-train-zone">
          <button id="aq-train-btn" class="aq-btn-green">${ICON.wave} Начать обучение</button>
          <div id="aq-train-status" style="display:none">
            <span id="aq-train-rec-dot"></span>
            <span>Запись: <b id="aq-train-count">0</b> шаг(ов)</span>
            <button id="aq-train-cancel" title="Сбросить без сохранения">Отмена</button>
          </div>
        </div>
        <div id="aq-tpl-list"></div>
      </div>
    </div>
  </div>
  <div id="aq-footer">
    <span id="aq-status">Готов</span>
    <div id="aq-footer-right">
      <button id="aq-clear-ctx" title="Очистить память диалога">ctx</button>
      <span id="aq-wake-badge" style="display:none" title="Wake-word активен">${ICON.wave}</span>
      <button id="aq-listen-btn" title="Включить прослушку wake-word">
        <span id="aq-listen-icon">${ICON.leaf}</span><span id="aq-listen-dot"></span><span id="aq-listen-label">СПИТ</span>
      </button>
    </div>
  </div>
</div>
<div id="aq-rec-hud" data-phase="armed" data-corner="top-left" style="display:none">
  <div id="aq-rec-hud-head">
    <span id="aq-rec-hud-dot"></span>
    <span id="aq-rec-hud-label">Слушаю…</span>
    <span id="aq-rec-hud-timer">0:00</span>
  </div>
  <div id="aq-rec-hud-wave"></div>
  <div id="aq-rec-hud-interim"></div>
  <div id="aq-rec-hud-btns">
    <button id="aq-rec-hud-stop" title="Остановить и подтвердить">${ICON.stop}<span>Стоп</span></button>
    <button id="aq-rec-hud-cancel" title="Отмена">${ICON.close}</button>
  </div>
</div>
<div id="aq-confirm-card" class="aq-confirm-popup" data-corner="top-left" style="display:none"></div>
<div id="aq-resize-handle"></div>`;
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ИНЪЕКЦИЯ
   * ════════════════════════════════════════════════════════════════════ */
  const root = document.createElement('div');
  root.id = 'aqbobek-root';
  root.setAttribute('data-state', 'corner');
  root.setAttribute('data-size', 'compact');
  root.setAttribute('data-wake-indicator', 'on');
  root.setAttribute('data-listen', 'off');
  root.setAttribute('data-corner-pos', 'bottom-right');
  root.setAttribute('data-wake', '');
  root.innerHTML = template();

  // Внедряем в <html> (устойчивее к SPA, которые перерисовывают <body>)
  // и держим на плаву watchdog-ом, если фреймворк снесёт узел.
  function mount() {
    const host = document.documentElement || document.body;
    if (host && !host.contains(root)) host.appendChild(root);
  }
  mount();
  setInterval(mount, 2000);
  try {
    // На случай, если panel.css (внешний файл манифеста) не подхватился на
    // странице со строгим CSP — подстрахуемся минимальными инлайн-стилями,
    // чтобы угловой пузырь был виден в любом случае.
    root.style.cssText = 'position:fixed!important;z-index:2147483647!important;';
    console.info('%c[Suerte] виджет внедрён', 'color:#4ade80;font-weight:700', 'connected =', root.isConnected, '| url =', location.href);
  } catch (_e) {}

  const $ = (sel) => root.querySelector(sel);
  const el = {
    root,
    corner: $('#aq-corner'),
    panel: $('#aq-panel'),
    head: $('#aq-head'),
    dot: $('#aq-dot'),
    status: $('#aq-status'),
    text: $('#aq-text'),
    micBtn: $('#aq-mic-btn'),
    sendBtn: $('#aq-send-btn'),
    cancelBtn: $('#aq-cancel-btn'),
    voiceBar: $('#aq-voice-bar'),
    voiceInterim: $('#aq-voice-interim'),
    micDenied: $('#aq-mic-denied-bar'),
    listenOff: $('#aq-listen-off-bar'),
    runProgress: $('#aq-run-progress'),
    runStepLabel: $('#aq-run-step-label'),
    runStepCount: $('#aq-run-step-count'),
    runBar: $('#aq-run-progress-bar'),
    runRoute: $('#aq-run-route-summary'),
    lastReply: $('#aq-last-reply'),
    lastReplyText: $('#aq-last-reply-text'),
    chat: $('#aq-chat'),
    domList: $('#aq-dom-list'),
    medrecBtn: $('#aq-medrec-btn'),
    listenBtn: $('#aq-listen-btn'),
    listenLabel: $('#aq-listen-label'),
    wakeBadge: $('#aq-wake-badge'),
    ocrFile: $('#aq-ocr-file'),
    ocrDrop: $('#aq-ocr-drop'),
    ocrDropFile: $('#aq-ocr-drop-file'),
    ocrResult: $('#aq-ocr-result'),
    ocrSteps: $('#aq-ocr-steps'),
    chainBadge: $('#aq-chain-badge'),
    chainName: $('#aq-chain-badge-name'),
    trainBtn: $('#aq-train-btn'),
    trainStatus: $('#aq-train-status'),
    trainCount: $('#aq-train-count'),
    trainCancel: $('#aq-train-cancel'),
    tplList: $('#aq-tpl-list'),
    recBadge: $('#aq-rec-badge'),
    recBadgeText: $('#aq-rec-badge-text'),
    voiceTimer: $('#aq-voice-timer'),
    recHud: $('#aq-rec-hud'),
    recHudLabel: $('#aq-rec-hud-label'),
    recHudTimer: $('#aq-rec-hud-timer'),
    recHudWave: $('#aq-rec-hud-wave'),
    recHudInterim: $('#aq-rec-hud-interim'),
    recHudStop: $('#aq-rec-hud-stop'),
    recHudCancel: $('#aq-rec-hud-cancel'),
    confirmCard: $('#aq-confirm-card')
  };

  /* ════════════════════════════════════════════════════════════════════
   *  СОСТОЯНИЕ
   * ════════════════════════════════════════════════════════════════════ */
  const S = {
    listening: false,      // включён ли wake-word слушатель
    phase: 'idle',         // idle | armed | recording | confirm | sending
    recognizing: false,    // работает ли Web Speech сейчас
    mediaStream: null,
    recorder: null,
    chunks: [],
    carryBlob: null,
    analyser: null,
    audioCtx: null,
    vadRAF: null,
    silenceStart: 0,
    lastNoise: 0,
    armTimer: null,
    recognition: null,
    lastCommandText: '',
    runBusy: false,        // движок очереди шагов уже работает
    recording: false,      // включён ли режим «Обучение»
    recStartTs: 0,         // момент старта текущего куска записи
    recBaseSec: 0,         // накопленная длительность (при дозаписи)
    recDurationSec: 0,     // итоговая длительность последней записи
    confirmCleanup: null,  // очистка ресурсов плеера карточки
    ctx: []                // короткая память диалога
  };

  function setStatus(t) { el.status.textContent = t; }
  function setDot(cls) { el.dot.className = cls || ''; }
  function setAlice(s) {
    if (s) root.setAttribute('data-alice', s);
    else root.removeAttribute('data-alice');
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ЛОГ  (панель его не показывает — только копит; смотреть в настройках)
   * ════════════════════════════════════════════════════════════════════ */
  const LOG_MAX = 300;          // сколько записей храним в обычном режиме
  const LOG_MAX_DEBUG = 1000;   // ...и в режиме отладки
  const LOG_TEXT_MAX = 4000;    // длинные verbose-дампы не должны выедать квоту storage

  function log(kind, title, text) {
    const now = new Date();
    let body = text == null ? '' : String(text);
    if (body.length > LOG_TEXT_MAX) {
      body = body.slice(0, LOG_TEXT_MAX) + '\n… обрезано, всего ' + body.length + ' символов';
    }
    const item = {
      kind: kind,
      title: title,
      text: body,
      time: now.toLocaleTimeString('ru-RU') + '.' + String(now.getMilliseconds()).padStart(3, '0'),
      ts: now.getTime(),
      url: location.href
    };
    chrome.storage.local.get(LOG_KEY, (store) => {
      const arr = store[LOG_KEY] || [];
      arr.push(item);
      const cap = CFG.debug ? LOG_MAX_DEBUG : LOG_MAX;
      if (arr.length > cap) arr.splice(0, arr.length - cap);
      chrome.storage.local.set({ [LOG_KEY]: arr });
    });
  }

  /* Verbose-запись: молчит, пока в настройках выключен режим отладки. */
  function dbg(title, text) {
    if (!CFG.debug) return;
    log('info', title, text);
  }

  /* Короткая выжимка значения для verbose-лога: тела запросов бывают огромными. */
  function preview(value, max) {
    if (value == null) return '';
    let s;
    try { s = typeof value === 'string' ? value : JSON.stringify(value); }
    catch (_e) { s = String(value); }
    const cap = max || 600;
    return s.length > cap ? s.slice(0, cap) + '…' : s;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function pushChat(role, textVal) {
    const wrap = document.createElement('div');
    wrap.className = 'aq-chat-msg aq-chat-' + role;
    const b = document.createElement('div');
    b.className = 'aq-chat-bubble';
    b.textContent = textVal;
    wrap.appendChild(b);
    el.chat.appendChild(wrap);
    el.chat.scrollTop = el.chat.scrollHeight;
  }

  function showReply(textVal, isError) {
    el.lastReply.style.display = 'flex';
    el.lastReply.classList.toggle('error', !!isError);
    el.lastReplyText.textContent = textVal;
    pushChat(isError ? 'error' : 'agent', textVal);
    if (CFG.narrator && !isError) speak(textVal);
  }
  function speak(t) {
    try {
      const u = new SpeechSynthesisUtterance(t);
      u.lang = CFG.lang || 'ru-RU';
      u.volume = CFG.volume != null ? CFG.volume : 1;
      speechSynthesis.speak(u);
    } catch (_e) {}
  }

  /* ════════════════════════════════════════════════════════════════════
   *  UI: ТАБЫ, DRAG, RESIZE, КНОПКИ
   * ════════════════════════════════════════════════════════════════════ */
  function openPanel() { root.setAttribute('data-state', 'panel'); refreshRecHud(); }
  function toCorner() { root.setAttribute('data-state', 'corner'); refreshRecHud(); }

  el.corner.addEventListener('click', openPanel);
  $('#aq-panel-close').addEventListener('click', toCorner);
  $('#aq-toggle-size').addEventListener('click', () => {
    const sz = root.getAttribute('data-size') === 'expanded' ? 'compact' : 'expanded';
    root.setAttribute('data-size', sz);
  });

  root.querySelectorAll('.aq-tab').forEach((tab) => {
    tab.addEventListener('click', () => switchTab(tab.getAttribute('data-tab')));
  });
  function switchTab(name) {
    root.querySelectorAll('.aq-tab').forEach((t) => t.classList.toggle('active', t.getAttribute('data-tab') === name));
    root.querySelectorAll('.aq-tab-panel').forEach((p) => p.classList.toggle('active', p.id === 'tab-' + name));
  }

  // Настройки открываются ОТДЕЛЬНОЙ вкладкой (полноценный HTML), а не в iframe.
  // Защита от лавины: открытие вкладки необратимо и «складывается» — десять
  // вызовов дают десять вкладок. Зовут отсюда и голос, и кнопка, и сообщение
  // OPEN_SETTINGS из background, поэтому порог стоит здесь, а не у вызывающих.
  let _settingsOpenedAt = 0;
  const SETTINGS_COOLDOWN_MS = 3000;
  function openSettings() {
    const now = Date.now();
    if (now - _settingsOpenedAt < SETTINGS_COOLDOWN_MS) return;
    _settingsOpenedAt = now;
    bg('OPEN_SETTINGS_TAB').catch(() => {
      // запасной путь, если background недоступен (сработает при клике-жесте)
      window.open(chrome.runtime.getURL('settings.html'), '_blank');
    });
  }
  $('#aq-settings-btn').addEventListener('click', openSettings);
  $('#aq-clear-ctx').addEventListener('click', () => { S.ctx = []; setStatus('Память диалога очищена'); });

  // Позиция угла
  root.querySelectorAll('.aq-pos-opt').forEach((btn) => {
    btn.addEventListener('click', () => {
      root.classList.remove('aq-dragged');
      root.setAttribute('data-corner-pos', btn.getAttribute('data-pos'));
      $('#aq-pos-popup').style.display = 'none';
    });
  });

  // Drag за шапку
  (function enableDrag() {
    let sx, sy, ox, oy, dragging = false;
    el.head.addEventListener('mousedown', (e) => {
      if (e.target.closest('button')) return;
      dragging = true;
      const r = el.panel.getBoundingClientRect();
      sx = e.clientX; sy = e.clientY; ox = r.left; oy = r.top;
      e.preventDefault();
    });
    window.addEventListener('mousemove', (e) => {
      if (!dragging) return;
      root.classList.add('aq-dragged');
      root.style.setProperty('--aq-drag-left', (ox + e.clientX - sx) + 'px');
      root.style.setProperty('--aq-drag-top', (oy + e.clientY - sy) + 'px');
    });
    window.addEventListener('mouseup', () => { dragging = false; });
  })();

  // Resize
  (function enableResize() {
    const handle = $('#aq-resize-handle');
    if (!handle) return;
    let sx, sy, sw, sh, res = false;
    handle.addEventListener('mousedown', (e) => {
      res = true; const r = el.panel.getBoundingClientRect();
      sx = e.clientX; sy = e.clientY; sw = r.width; sh = r.height; e.preventDefault();
    });
    window.addEventListener('mousemove', (e) => {
      if (!res) return;
      el.panel.style.width = Math.max(280, sw + (e.clientX - sx)) + 'px';
      el.panel.style.height = Math.max(240, sh + (e.clientY - sy)) + 'px';
    });
    window.addEventListener('mouseup', () => { res = false; });
  })();

  // Ручной ввод
  el.sendBtn.addEventListener('click', () => {
    const t = el.text.value.trim();
    if (t) { el.text.value = ''; pushChat('user', t); dispatchCommand(t); }
  });
  el.text.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); el.sendBtn.click(); }
  });

  // Микрофон вручную запускает запись
  el.micBtn.addEventListener('click', () => {
    if (S.phase === 'idle') arm(true);
    else if (S.phase === 'recording') stopRecording('manual');
  });
  el.cancelBtn.addEventListener('click', () => cancelAll());

  // Плавающий HUD записи: Стоп (подтвердить) / Отмена
  el.recHudStop.addEventListener('click', () => {
    if (S.phase === 'recording') stopRecording('manual');
    else cancelAll();
  });
  el.recHudCancel.addEventListener('click', () => cancelAll());

  // Listen toggle (СПИТ / активен)
  el.listenBtn.addEventListener('click', toggleListen);
  function openBig() {
    root.setAttribute('data-state', 'panel');
    root.setAttribute('data-size', 'expanded');
    root.classList.remove('aq-dragged'); // вернуть к углу, если был перетащен
  }
  window.addEventListener('keydown', (e) => {
    // Alt+M — вкл/выкл прослушку; Alt+Q — открыть в большом (развёрнутом) режиме.
    // Используем e.code (физическая клавиша) — работает и на русской раскладке.
    if (e.altKey && (e.code === 'KeyM' || e.key === 'm' || e.key === 'M')) { e.preventDefault(); toggleListen(); }
    if (e.altKey && (e.code === 'KeyQ' || e.key === 'q' || e.key === 'Q')) { e.preventDefault(); openBig(); }
  });

  // Сканер — всегда через локальный сервер (/scan-dynamic)
  $('#aq-scan-btn').addEventListener('click', runLocalScan);
  el.medrecBtn.addEventListener('click', runMedrecordFill);
  el.trainBtn.addEventListener('click', () => { S.recording ? stopTraining() : startTraining(); });
  el.trainCancel.addEventListener('click', () => cancelTraining());
  // Кнопка имеет смысл только на карточке мед. записи — на остальных страницах прячем.
  if (isMedRecordPage()) el.medrecBtn.style.display = '';

  // OCR
  el.ocrFile.addEventListener('change', handleOcrFile);
  // Drag & drop зона
  el.ocrDrop.addEventListener('click', () => el.ocrFile.click());
  el.ocrDrop.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); el.ocrFile.click(); }
  });
  ['dragenter', 'dragover'].forEach((evt) => {
    el.ocrDrop.addEventListener(evt, (e) => {
      e.preventDefault(); e.stopPropagation();
      el.ocrDrop.classList.add('aq-drag-over');
    });
  });
  ['dragleave', 'dragend'].forEach((evt) => {
    el.ocrDrop.addEventListener(evt, (e) => {
      e.preventDefault(); e.stopPropagation();
      el.ocrDrop.classList.remove('aq-drag-over');
    });
  });
  el.ocrDrop.addEventListener('drop', (e) => {
    e.preventDefault(); e.stopPropagation();
    el.ocrDrop.classList.remove('aq-drag-over');
    const file = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
    if (file) handleOcrFile({ target: { files: [file], value: '' } });
  });

  // Сообщения от background/настроек
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === 'OPEN_SETTINGS') openSettings();
  });

  /* ════════════════════════════════════════════════════════════════════
   *  WEB SPEECH — wake / trigger слова
   * ════════════════════════════════════════════════════════════════════ */
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;

  /* Сегмент распознавания, в котором управляющее слово уже сработало (см.
     onSpeechResult). Сбрасывается на каждый новый SpeechRecognition: у нового
     объекта results нумеруются заново с нуля, и без сброса защёлка навсегда
     заблокировала бы управляющие слова после первого авто-рестарта (onend). */
  let _ctlSegment = -1;

  function startRecognition() {
    if (!SR) { setStatus('Web Speech не поддерживается'); return; }
    if (S.recognizing) return;
    _ctlSegment = -1;
    const rec = new SR();
    rec.lang = CFG.lang || 'ru-RU';
    rec.continuous = true;
    rec.interimResults = true;
    rec.onresult = onSpeechResult;
    rec.onend = () => {
      S.recognizing = false;
      // авто-рестарт пока включён listen
      if (S.listening) setTimeout(() => { if (S.listening) startRecognition(); }, 250);
    };
    rec.onerror = (e) => {
      if (e.error === 'not-allowed' || e.error === 'service-not-allowed') {
        el.micDenied.style.display = 'flex';
        setListen(false);
      }
    };
    try { rec.start(); S.recognizing = true; S.recognition = rec; }
    catch (_e) { /* уже запущен */ }
  }
  function stopRecognition() {
    S.listening = false;
    if (S.recognition) { try { S.recognition.stop(); } catch (_e) {} }
    S.recognizing = false;
  }

  function norm(s) { return (s || '').toLowerCase().replace(/[.,!?;:()"']/g, ' ').replace(/\s+/g, ' ').trim(); }
  function hasWord(text, words) {
    const t = ' ' + norm(text) + ' ';
    return (words || []).some((w) => w && t.includes(' ' + norm(w) + ' '));
  }

  function onSpeechResult(ev) {
    let interim = '', finalText = '';
    for (let i = ev.resultIndex; i < ev.results.length; i++) {
      const r = ev.results[i];
      if (r.isFinal) finalText += r[0].transcript; else interim += r[0].transcript;
    }
    const heard = (finalText || interim);
    if (S.phase === 'recording') {
      el.voiceInterim.textContent = heard;
      el.recHudInterim.textContent = heard;
      // Триггеры во время записи
      if (hasWord(heard, CFG.triggers.stop)) { stopRecording('cancel'); return; }
      if (hasWord(heard, CFG.triggers.send)) { stopRecording('send'); return; }
      return;
    }
    // Пока не записываем — ловим управляющие слова.
    // ОДИН РАЗ НА СЕГМЕНТ. Врач произносит слово однажды, а событий на эту фразу
    // приходит десятки: при interimResults=true распознаватель уточняет её по
    // нескольку раз в секунду, и слово остаётся в тексте до конца фразы. Без
    // защёлки «настройки» открывали новую вкладку на каждом уточнении — и чем
    // дольше врач говорил дальше, тем больше вкладок. Сработавшие wake/sleep
    // сами себя защищали (arm выходит не из idle, sleep глушит распознавание),
    // поэтому вылезало это только на настройках.
    if (ev.resultIndex <= _ctlSegment) return;

    /* ТОЛЬКО ВМЕСТЕ С WAKE-WORD. Слушатель работает всю смену и слышит разговор
       врача с пациентом: «настройки», сказанное в этом разговоре (или просто
       неверно расслышанное), открывало вкладку само по себе. Обращение к
       помощнику должно быть явным — как и для записи команды.
       Порядок важен: «агент, настройки» обязано открыть настройки, а не начать
       запись команды, поэтому wake проверяется ПОСЛЕДНИМ. */
    const woke = hasWord(heard, CFG.triggers.wake);
    if (!woke) return;
    if (hasWord(heard, CFG.triggers.settings)) { _ctlSegment = ev.resultIndex; openSettings(); return; }
    if (hasWord(heard, CFG.triggers.sleep)) { _ctlSegment = ev.resultIndex; setListen(false); return; }
    if (S.phase === 'idle' && S.listening) {
      _ctlSegment = ev.resultIndex;
      arm(false);
      return;
    }
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ЗАПИСЬ ГОЛОСА (MediaRecorder + VAD)
   * ════════════════════════════════════════════════════════════════════ */
  async function ensureStream() {
    if (S.mediaStream && S.mediaStream.active) return S.mediaStream;
    S.mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    return S.mediaStream;
  }

  // arm: услышали wake-word (или ручной микрофон) — ждём голос, затем пишем
  async function arm(manual) {
    if (S.phase !== 'idle') return;
    try {
      await ensureStream();
    } catch (_e) {
      el.micDenied.style.display = 'flex';
      return;
    }
    S.phase = 'armed';
    S.recBaseSec = 0;
    S.recStartTs = 0;
    setAlice('listening');
    setStatus(manual ? 'Говорите...' : 'Слушаю, говорите...');
    el.micBtn.classList.add('recording');
    idleBars();
    refreshRecHud();
    startVAD();
    // Если голос так и не начался — вернёмся в покой
    S.armTimer = setTimeout(() => { if (S.phase === 'armed') disarm(); }, CFG.armTimeoutMs);
  }
  function disarm() {
    clearTimeout(S.armTimer);
    stopVAD();
    S.phase = 'idle';
    setAlice(S.listening ? null : null);
    el.micBtn.classList.remove('recording');
    hideRecHud();
    setStatus(S.listening ? 'Слушаю wake-word' : 'Готов');
  }

  function beginRecording() {
    if (S.phase === 'recording') return;
    clearTimeout(S.armTimer);
    S.phase = 'recording';
    S.recStartTs = Date.now();
    setAlice('recording');
    el.voiceBar.style.display = 'flex';
    el.voiceInterim.textContent = '';
    el.recHudInterim.textContent = '';
    el.recHudTimer.textContent = fmtDur(S.recBaseSec);
    el.voiceTimer.textContent = fmtDur(S.recBaseSec);
    refreshRecHud();
    // при дозаписи сохраняем ранее записанный blob как первый чанк
    S.chunks = S.carryBlob ? [S.carryBlob] : [];
    S.carryBlob = null;
    const mime = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus' : 'audio/webm';
    S.recorder = new MediaRecorder(S.mediaStream, { mimeType: mime });
    S.recorder.ondataavailable = (e) => { if (e.data && e.data.size) S.chunks.push(e.data); };
    S.recorder.start(200);
    setStatus('Запись...');
  }

  // VAD: следим за уровнем сигнала — старт записи по шуму, стоп по тишине
  function startVAD() {
    S.audioCtx = S.audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    const src = S.audioCtx.createMediaStreamSource(S.mediaStream);
    S.analyser = S.audioCtx.createAnalyser();
    S.analyser.fftSize = 512;
    src.connect(S.analyser);
    const buf = new Uint8Array(S.analyser.frequencyBinCount);
    const freq = new Uint8Array(S.analyser.frequencyBinCount);
    S.lastNoise = Date.now();
    const START_TH = 0.02, SIL_TH = 0.012;
    const tick = () => {
      if (S.phase !== 'armed' && S.phase !== 'recording') return;
      S.analyser.getByteTimeDomainData(buf);
      let sum = 0;
      for (let i = 0; i < buf.length; i++) { const v = (buf[i] - 128) / 128; sum += v * v; }
      const rms = Math.sqrt(sum / buf.length);
      const now = Date.now();
      // Живой отклик — рисуем спектр и обновляем таймер каждый кадр
      S.analyser.getByteFrequencyData(freq);
      renderBarsFrom(freq);
      updateRecTimers();
      if (rms > START_TH) {
        S.lastNoise = now;
        if (S.phase === 'armed') beginRecording();
      }
      if (S.phase === 'recording') {
        if (rms < SIL_TH && (now - S.lastNoise) >= CFG.silenceMs) { stopRecording('silence'); return; }
      }
      S.vadRAF = requestAnimationFrame(tick);
    };
    S.vadRAF = requestAnimationFrame(tick);
  }
  function stopVAD() {
    if (S.vadRAF) cancelAnimationFrame(S.vadRAF);
    S.vadRAF = null;
  }
  /* ─ Живой визуальный отклик записи: эквалайзер + таймер + HUD ─ */
  function fmtDur(sec) {
    sec = Math.max(0, Math.floor(sec || 0));
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return m + ':' + String(s).padStart(2, '0');
  }

  // Плавающие элементы (HUD и карточка) встают в угол, ПРОТИВОПОЛОЖНЫЙ виджету
  function oppositeCorner() {
    const pos = root.getAttribute('data-corner-pos') || 'bottom-right';
    return ({
      'bottom-right': 'top-left',
      'bottom-left':  'top-right',
      'top-right':    'bottom-left',
      'top-left':     'bottom-right'
    })[pos] || 'top-left';
  }
  function positionFloater(node) { if (node) node.setAttribute('data-corner', oppositeCorner()); }

  // Генерируем бары эквалайзера (тег <i>, чтобы не конфликтовать со старыми правилами span)
  function buildBars(container, n) {
    if (!container) return [];
    container.innerHTML = '';
    const bars = [];
    for (let i = 0; i < n; i++) {
      const b = document.createElement('i');
      b.className = 'aq-eqbar';
      container.appendChild(b);
      bars.push(b);
    }
    return bars;
  }
  let HUD_BARS = [], INLINE_BARS = [];
  function initBars() {
    HUD_BARS = buildBars(el.recHudWave, 22);
    INLINE_BARS = buildBars(root.querySelector('#aq-voice-waves'), 16);
  }

  // Рисуем бары по спектру микрофона (нижне-средние частоты — речь)
  function renderBarsFrom(freq) {
    const paint = (bars) => {
      if (!bars.length) return;
      const usable = Math.max(bars.length, Math.floor(freq.length * 0.55));
      const per = Math.max(1, Math.floor(usable / bars.length));
      for (let i = 0; i < bars.length; i++) {
        let sum = 0;
        for (let j = 0; j < per; j++) sum += freq[i * per + j] || 0;
        const v = (sum / per) / 255;                         // 0..1
        const scale = Math.max(0.08, Math.min(1, v * 1.45));
        bars[i].style.transform = 'scaleY(' + scale.toFixed(3) + ')';
      }
    };
    paint(HUD_BARS);
    paint(INLINE_BARS);
  }
  function idleBars() {
    [HUD_BARS, INLINE_BARS].forEach((bars) => bars.forEach((b) => { b.style.transform = 'scaleY(0.08)'; }));
  }

  function updateRecTimers() {
    if (S.phase !== 'recording') return;
    const t = S.recBaseSec + (S.recStartTs ? (Date.now() - S.recStartTs) / 1000 : 0);
    const txt = fmtDur(t);
    el.recHudTimer.textContent = txt;
    el.voiceTimer.textContent = txt;
  }

  // Показ/скрытие плавающего HUD: он нужен, когда панель НЕ открыта
  function refreshRecHud() {
    const active = (S.phase === 'armed' || S.phase === 'recording');
    const panelOpen = root.getAttribute('data-state') === 'panel';
    positionFloater(el.recHud);
    if (active && !panelOpen) {
      el.recHud.setAttribute('data-phase', S.phase);
      el.recHudLabel.textContent = (S.phase === 'recording') ? 'Идёт запись' : 'Слушаю, говорите…';
      el.recHud.style.display = 'flex';
    } else {
      el.recHud.style.display = 'none';
    }
  }
  function hideRecHud() { el.recHud.style.display = 'none'; }

  function stopRecording(reason) {
    stopVAD();
    S.recDurationSec = S.recBaseSec + (S.recStartTs ? (Date.now() - S.recStartTs) / 1000 : 0);
    S.recStartTs = 0;
    el.micBtn.classList.remove('recording');
    if (!S.recorder || S.recorder.state === 'inactive') {
      // ничего не записали
      finishAfterStop(reason, null);
      return;
    }
    S.recorder.onstop = () => {
      const blob = new Blob(S.chunks, { type: S.recorder.mimeType });
      finishAfterStop(reason, blob);
    };
    try { S.recorder.stop(); } catch (_e) { finishAfterStop(reason, null); }
  }

  function finishAfterStop(reason, blob) {
    el.voiceBar.style.display = 'none';
    hideRecHud();
    idleBars();
    setAlice(null);
    if (reason === 'cancel' || !blob || blob.size < 800) {
      S.phase = 'idle';
      setStatus(reason === 'cancel' ? 'Отменено' : 'Пусто');
      return;
    }
    if (reason === 'send' || reason === 'silence' || reason === 'manual') {
      if (CFG.confirmBeforeSend) askConfirm(blob);
      else sendVoice(blob);
    }
  }

  function cancelAll() {
    clearTimeout(S.armTimer);
    stopVAD();
    if (S.recorder && S.recorder.state !== 'inactive') { try { S.recorder.stop(); } catch (_e) {} }
    S.phase = 'idle';
    el.voiceBar.style.display = 'none';
    closeConfirmCard();
    hideRecHud();
    idleBars();
    el.cancelBtn.style.display = 'none';
    el.micBtn.classList.remove('recording');
    setAlice(null);
    setStatus('Отменено');
  }

  /* Карточка подтверждения — плавающая, в противоположном от виджета углу.
     Показывает плеер записи (прослушать) + Отправить / Дозаписать / Отмена. */
  function closeConfirmCard() {
    if (S.confirmCleanup) { try { S.confirmCleanup(); } catch (_e) {} S.confirmCleanup = null; }
    el.confirmCard.style.display = 'none';
    el.confirmCard.innerHTML = '';
  }

  function askConfirm(blob) {
    S.phase = 'confirm';
    hideRecHud();
    const durSec = S.recDurationSec || 0;
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    const card = el.confirmCard;
    positionFloater(card);
    card.innerHTML =
      '<div class="aq-confirm-title"><span class="aq-confirm-icon">🎙</span> Запись готова</div>' +
      '<div class="aq-rec-player">' +
        '<button class="aq-rec-play" type="button" title="Прослушать">▶</button>' +
        '<div class="aq-rec-player-track"><div class="aq-rec-player-fill"></div></div>' +
        '<span class="aq-rec-player-time">' + fmtDur(durSec) + '</span>' +
      '</div>' +
      '<div class="aq-confirm-btns">' +
        '<button class="aq-confirm-btn aq-confirm-append" data-cf="more">Дозаписать</button>' +
        '<button class="aq-confirm-btn aq-confirm-yes" data-cf="yes">Отправить</button>' +
        '<button class="aq-confirm-btn aq-confirm-no" data-cf="no">Отмена</button>' +
      '</div>';
    card.style.display = 'block';

    const playBtn = card.querySelector('.aq-rec-play');
    const fill = card.querySelector('.aq-rec-player-fill');
    const timeEl = card.querySelector('.aq-rec-player-time');

    S.confirmCleanup = () => { try { audio.pause(); } catch (_e) {} URL.revokeObjectURL(url); };

    playBtn.addEventListener('click', () => {
      if (audio.paused) audio.play().catch(() => {}); else audio.pause();
    });
    audio.addEventListener('play',  () => { playBtn.textContent = '⏸'; });
    audio.addEventListener('pause', () => { playBtn.textContent = '▶'; });
    audio.addEventListener('timeupdate', () => {
      // Blob от MediaRecorder часто отдаёт duration=Infinity, поэтому берём нашу длительность
      const d = (durSec && isFinite(durSec)) ? durSec : (isFinite(audio.duration) ? audio.duration : 0);
      if (d) fill.style.width = Math.min(100, (audio.currentTime / d) * 100) + '%';
      timeEl.textContent = fmtDur(audio.currentTime);
    });
    audio.addEventListener('ended', () => {
      playBtn.textContent = '▶';
      fill.style.width = '0%';
      timeEl.textContent = fmtDur(durSec);
    });

    card.querySelector('.aq-confirm-btns').addEventListener('click', (e) => {
      const b = e.target.closest('[data-cf]'); if (!b) return;
      const act = b.getAttribute('data-cf');
      closeConfirmCard();
      if (act === 'yes') sendVoice(blob);
      else if (act === 'no') { S.phase = 'idle'; setStatus('Отменено'); }
      else if (act === 'more') resumeRecording(blob);
    });
  }
  async function resumeRecording(prevBlob) {
    // Дозапись: копим предыдущие чанки и продолжаем
    S.phase = 'armed';
    S.recBaseSec = S.recDurationSec || 0;   // продолжаем таймер с накопленного
    S.recStartTs = 0;
    setStatus('Дозапись...');
    try { await ensureStream(); } catch (_e) { return; }
    // сохраняем предыдущий blob — он станет первым чанком в beginRecording
    S.carryBlob = prevBlob || null;
    setAlice('listening');
    idleBars();
    refreshRecHud();
    startVAD();
    S.armTimer = setTimeout(() => { if (S.phase === 'armed') beginRecording(); }, 150);
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ОТПРАВКА ГОЛОСА → ТРАНСКРИПЦИЯ → КОМАНДА
   * ════════════════════════════════════════════════════════════════════ */
  function blobToB64(blob) {
    return new Promise((resolve, reject) => {
      const fr = new FileReader();
      fr.onload = () => resolve(String(fr.result).split(',')[1]);
      fr.onerror = reject;
      fr.readAsDataURL(blob);
    });
  }

  async function sendVoice(blob) {
    S.phase = 'sending';
    setAlice('sending');
    setDot('loading');
    setStatus('Распознаю речь...');
    try {
      const b64 = await blobToB64(blob);
      const res = await bg('SRV_TRANSCRIBE', { audioB64: b64, mime: blob.type || 'audio/webm', provider: CFG.provider });
      const textVal = (res && res.text || '').trim();
      setAlice(null);
      if (!textVal) { setDot('error'); showReply('Не удалось распознать речь', true); S.phase = 'idle'; return; }
      pushChat('user', textVal);
      log('info', 'Голос распознан', textVal);
      await dispatchCommand(textVal);
    } catch (e) {
      setAlice(null); setDot('error');
      showReply('Ошибка транскрипции: ' + e.message, true);
      log('error', 'Транскрипция', e.message);
      S.phase = 'idle';
    }
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ДИСПЕТЧЕР КОМАНДЫ  (динамический сайт → скан → сервер)
   * ════════════════════════════════════════════════════════════════════ */
  // Динамическая СТРАНИЦА (не весь сайт): сверяем конкретный URL/путь.
  // Достаём чистый hostname из произвольной строки: "https://akt.dmed.kz/x" → "akt.dmed.kz",
  // "dmed.kz" остаётся как есть.
  function extractHostname(raw) {
    const s = (raw || '').trim();
    if (!s) return '';
    try { return new URL(s).hostname.toLowerCase(); }
    catch (_e) {
      try { return new URL('https://' + s.replace(/^\/+/, '')).hostname.toLowerCase(); }
      catch (_e2) { return s.replace(/^\w+:\/\//, '').split('/')[0].toLowerCase(); }
    }
  }

  function isDynamicPage() {
    const here = (location.origin + location.pathname).replace(/\/+$/, '');
    const pages = (CFG.dynamicPages && CFG.dynamicPages.length) ? CFG.dynamicPages : (CFG.dynamicSites || []);
    const pageMatch = pages.some((p) => {
      const e = (p || '').trim().replace(/\/+$/, '');
      if (!e) return false;
      // совпадение по полному URL, по origin+path или по префиксу пути
      return here === e || here.startsWith(e) || location.href.indexOf(e) !== -1;
    });
    if (pageMatch) return true;

    // Динамические САЙТЫ: сверяем только домен (hostname), путь не важен —
    // совпадает — значит скан включён на любой странице этого сайта.
    const domains = CFG.dynamicDomains || [];
    if (!domains.length) return false;
    const hostHere = location.hostname.toLowerCase();
    return domains.some((d) => {
      const dh = extractHostname(d);
      if (!dh) return false;
      // точное совпадение домена или совпадение поддомена (akt.dmed.kz для dmed.kz)
      return hostHere === dh || hostHere.endsWith('.' + dh);
    });
  }

  /* Класс активной вкладки medicalHistory. У этой SPA адрес не меняется при
     переключении вкладок, поэтому «где сейчас врач» видно только по меню.
     Берём big-screen копию меню: normal-screen — её дубликат для узких экранов.
     Тот же приём повторяет _active_tab в user_server/first_scan.py. */
  function readActiveTab() {
    const nav = document.querySelector('ul.mh-navigation.big-screen') ||
                document.querySelector('ul.mh-navigation');
    if (!nav) return null;
    const active = nav.querySelector('.active');
    return (active && active.classList[0]) || null;
  }

  /* Карточка пациента с сервера врача. Её отсутствие — не ошибка: команда
     должна работать и без неё (сервер может быть выключен). */
  async function fetchPatientCard() {
    const ids = AqPatientIds.extractPatientIds(location.href);
    if (!Object.keys(ids).length) {
      dbg('Карточка пациента', 'на странице нет идентификаторов пациента');
      return null;
    }
    try {
      const resp = await bg('SRV_PATIENT_GET', { ids });
      if (resp && resp.found) {
        dbg('Карточка пациента', 'найдена: ' + (resp.patient.full_name || resp.patient.key));
        return resp.patient;
      }
      dbg('Карточка пациента', 'ещё не заведена');
    } catch (e) {
      dbg('Карточка пациента', 'сервер недоступен: ' + e.message);
    }
    return null;
  }

  async function dispatchCommand(textVal) {
    S.lastCommandText = textVal;
    S.ctx.push({ role: 'user', text: textVal });
    setDot('loading');
    setStatus('Отправляю запрос...');
    try {
      let scan = null;
      if (isDynamicPage()) {
        setStatus('Сканирую страницу...');
        const ctx = collectPageContext();
        scan = await bg('SRV_SCAN', { html: ctx.html, values: ctx.values, url: location.href, iframe_html: ctx.iframeHtml });
        dbg('Скан страницы', ((scan && scan.elements) || []).length + ' элементов');
      } else {
        dbg('Скан пропущен', 'страница не в списке динамических: ' + location.href);
      }
      const patient = await fetchPatientCard();
      const activeTab = readActiveTab();
      if (activeTab) dbg('Активная вкладка', activeTab);
      setStatus('Думаю...');
      const resp = await bg('SRV_COMMAND', {
        text: textVal, provider: CFG.provider, url: location.href,
        // Заголовок страницы — единственное человеческое имя, по которому
        // сервер потом узнаёт эту страницу в своей карте. Стоит ~5 токенов.
        title: document.title || '',
        scan, patient, active_tab: activeTab
      });
      setDot('');
      // Сработал записанный шаблон, а не разбор команды. Показываем какой:
      // молча выполненный НЕ ТОТ сценарий врач заметит уже по последствиям.
      if (resp && resp._nav && resp._nav.name) {
        showReply('Перехожу: ' + resp._nav.name);
        log('info', 'Прямой переход', resp._nav.kind + ' → ' + resp._nav.url);
      }
      if (resp && resp._skill && resp._skill.name) {
        const sk = resp._skill;
        const kept = Math.max(0, (sk.slots_total || 0) - (sk.slots || 0));
        // Незаполненное поле сохраняет текст ИЗ ЗАПИСИ — то есть текст прошлого
        // пациента. Промолчать об этом нельзя: врач должен либо продиктовать
        // текст, либо осознанно оставить заготовку.
        showReply('Шаблон: ' + sk.name +
          (kept ? ' — полей из записи (не продиктовано): ' + kept : ''), kept > 0);
        log('info', 'Навык', sk.name +
            ' (совпадение ' + Math.round((sk.score || 0) * 100) + '%' +
            ', продиктовано полей: ' + (sk.slots || 0) + '/' + (sk.slots_total || 0) + ')');
      }
      await startRun(resp);
    } catch (e) {
      setDot('error');
      showReply('Ошибка: ' + e.message, true);
      log('error', 'Команда', e.message);
      setStatus('Ошибка');
    }
  }

  /* ════════════════════════════════════════════════════════════════════
   *  РЕЖИМ «ОБУЧЕНИЕ» — запись действий в шаблон
   * ════════════════════════════════════════════════════════════════════ */
  function getRecording() {
    return new Promise((r) => chrome.storage.local.get(REC_KEY, (s) => r(s[REC_KEY] || null)));
  }
  function setRecording(rec) {
    return new Promise((r) => chrome.storage.local.set({ [REC_KEY]: rec }, r));
  }
  function clearRecording() {
    return new Promise((r) => chrome.storage.local.remove(REC_KEY, r));
  }
  // Граница страниц для многостраничного плана — как address у шага.
  function recAddress() { return location.origin + location.pathname; }

  /* ─── Режим «всё в текущей вкладке» ───────────────────────────────────
     Кнопки Damumed нередко открывают страницу через window.open(url,'_blank').
     Новая вкладка ломает и запись (address шагов остаётся от старой страницы),
     и воспроизведение (исполнитель ждёт перехода в старой вкладке). Патч в
     MAIN-мире (aq-same-tab.js) заворачивает такие открытия в переход текущей
     вкладки, но включается только по этому атрибуту — чтобы вне обучения и
     воспроизведения обычная работа врача с сайтом не менялась. */
  let _sameTabPending = false;              // есть незавершённый план
  let _sameTabArmedAt = 0;                  // когда план последний раз двигался

  /* Отпечаток последней записи очереди ИЗ ЭТОЙ вкладки. storage.onChanged
     приходит во все вкладки, включая ту, что писала, а очередь общая — по
     отпечатку вкладка отличает «двигаю план я» от «план двигают без меня». */
  let _pendingWriteMark = '';
  function pendingMark(p) {
    return p ? String(p.runId) + ':' + String(p.index) + ':' + String(p.armedAt) : '';
  }
  function applySameTabMode() {
    // Врач может бросить план на середине (закрыть панель, уйти со страницы) —
    // тогда clearPending уже никто не позовёт. Держать патч включённым дольше
    // окна ожидания перехода нельзя: иначе обычные ссылки сайта навсегда
    // перестанут открываться в новой вкладке. Срок тот же, что у resumeRun.
    if (_sameTabPending && (Date.now() - _sameTabArmedAt) > RESUME_WINDOW_MS) {
      _sameTabPending = false;
      showChain(null);   // вместе с режимом снимаем и «Ждёт: …» от брошенного плана
    }
    const on = S.recording || _sameTabPending;
    const html = document.documentElement;
    if (!html) return;
    if (on) html.setAttribute(SAME_TAB_ATTR, 'on');
    else html.removeAttribute(SAME_TAB_ATTR);
  }

  /* Патч перехватил открытие «новой вкладки» — значит, только что нажатая
     кнопка навигационная. Помечаем последний записанный шаг navigates:true:
     исполнитель по этому флагу знает, что после шага надо ждать страницу, и не
     полагается на сравнение address соседних шагов. */
  function markLastStepNavigates() {
    _recWriteChain = _recWriteChain.then(async () => {
      const rec = await getRecording();
      if (!rec || !rec.active) return;
      const steps = (rec.steps || []).slice();
      const last = steps[steps.length - 1];
      if (!last || last.method !== 'click' || last.navigates === true) return;
      steps[steps.length - 1] = Object.assign({}, last, { navigates: true });
      await setRecording(Object.assign({}, rec, { steps }));
    }).catch(() => {});
    return _recWriteChain;
  }

  // Момент последнего ЗАПИСАННОГО клика. Без него markLastStepNavigates
  // повесил бы флаг на чужой, ни к чему не относящийся шаг: если кликнутый узел
  // не прошёл isActionableClick, шага для него нет, а событие о перехвате всё
  // равно придёт — и «ждать страницу» стало бы предыдущему шагу (стоп на 120 с).
  let _recClickAt = 0;
  const REC_CLICK_LINK_MS = 2000;   // open вызывается через миллисекунды после клика

  function onSameTabOpen(e) {
    const url = (e && typeof e.detail === 'string') ? e.detail : '';
    log('info', 'Открытие в новой вкладке перехвачено', url || '(адрес присвоят позже)');
    if (!S.recording || S.runBusy) return;
    if (!_recClickAt || (Date.now() - _recClickAt) > REC_CLICK_LINK_MS) return;
    _recClickAt = 0;
    markLastStepNavigates();
  }

  // Селектор для записи. Обычные элементы — чистый структурный путь (tag+nth-child,
  // без id/dataset/классов). ИСКЛЮЧЕНИЕ: построчный редактор damumed — contenteditable
  // <body id="editor_N"> внутри iframe: структурно это просто "body", что резолвер
  // спутает с body верхнего документа. У него стабильный (не динамический) id — им и
  // адресуем, иначе воспроизведение записи в редактор гарантированно ломается.
  function recSelector(node) {
    if (isLineEditorBody(node) && node.id) return '#' + CSS.escape(node.id);
    return AqRecorder.structuralSelector(node);
  }

  // Записываем шаг: буфер живёт в storage (переживает переход между страницами).
  // Сериализуем запись: события (change поля + click кнопки) могут идти впритык,
  // а get→set в chrome.storage асинхронный — без очереди второй set затрёт первый
  // из устаревшего чтения и шаг потеряется. Цепочка промисов гарантирует, что
  // каждый read-modify-write завершится до следующего.
  let _recWriteChain = Promise.resolve();
  function recordStep(step) {
    _recWriteChain = _recWriteChain.then(async () => {
      const rec = await getRecording();
      if (!rec || !rec.active) return;
      const steps = AqRecorder.pushStep(rec.steps || [], step);
      await setRecording(Object.assign({}, rec, { steps }));
      updateRecUi(steps.length);
    }).catch(() => {});
    return _recWriteChain;
  }

  // Гарды у всех трёх: включена запись, событие РЕАЛЬНОЕ (isTrusted отсекает
  // синтетические события исполнителя clickEl/setNativeValue), не наш UI, не идёт
  // воспроизведение плана (S.runBusy). Обработчики синхронные — recordStep уходит
  // в storage асинхронно (fire-and-forget).
  function recGuard(t) {
    return S.recording && t && !root.contains(t) && !S.runBusy;
  }

  // Действенный клик пишем на pointerdown, а не click: click срабатывает уже
  // после навигации (например, кнопка «Далее» уводит со страницы) — асинхронный
  // get→set в storage может не успеть, и последний шаг теряется. pointerdown
  // происходит на нажатии, до отпускания и до перехода — окно для записи есть.
  // Селектор «явной кнопки» — тот же и для поиска предка (closest), и для проверки
  // «внутри узла есть настоящие кнопки» (querySelector) в resolveClickTarget.
  const ACTIONABLE_SEL = 'button, a[href], [role="button"], [onclick], ' +
    'input[type="button"], input[type="submit"], input[type="reset"], ' +
    'input[type="checkbox"], input[type="radio"]';

  function onRecPointerDown(e) {
    if (!e.isTrusted || !recGuard(e.target)) return;
    if (e.button != null && e.button !== 0) return;   // только левая кнопка (не контекстное меню/средняя)
    // Клик часто попадает во вложенную иконку — выбор действенного узла (и
    // подъём к нему) вынесен в AqRecorder, чтобы покрываться тестами.
    const node = AqRecorder.resolveClickTarget(e.target, recClickEnv(e.target));
    if (!AqRecorder.isActionableClick(node, { pointer: hasPointerCursor(node) })) return;
    _recClickAt = Date.now();   // якорь для onSameTabOpen — шаг ниже точно появится
    recordStep(AqRecorder.buildClickStep(node, recAddress(), recSelector));
  }

  // DOM-часть resolveClickTarget: всё, чего нет в модуле без DOM.
  function recClickEnv(target) {
    let explicit = null;
    try { explicit = target && target.closest ? target.closest(ACTIONABLE_SEL) : null; }
    catch (_e) { explicit = null; }
    return {
      explicit,
      pointer: hasPointerCursor,
      parent: (n) => (n ? n.parentElement : null),
      tag: (n) => (n && n.tagName ? n.tagName.toLowerCase() : ''),
      hasActionable: (n) => {
        try { return !!(n && n.querySelector && n.querySelector(ACTIONABLE_SEL)); }
        catch (_e) { return false; }
      }
    };
  }

  function hasPointerCursor(node) {
    if (!node || node.nodeType !== 1) return false;
    try {
      const win = (node.ownerDocument && node.ownerDocument.defaultView) || window;
      return win.getComputedStyle(node).cursor === 'pointer';
    } catch (_e) { return false; }
  }

  function onRecChange(e) {
    if (!e.isTrusted || !recGuard(e.target)) return;
    const t = e.target;
    if (!AqRecorder.isTextEntry(t)) return;
    const val = ('value' in t) ? t.value : t.textContent;
    if (val == null || String(val).trim() === '') return;   // пустой ввод не пишем
    recordStep(AqRecorder.buildWriteStep(t, val, recAddress(), recSelector));
  }

  function onRecBlur(e) {
    if (!e.isTrusted || !recGuard(e.target)) return;
    const t = e.target;
    if (!t.isContentEditable) return;   // change покрывает input/select; blur — для editor_N
    const val = (t.innerText != null ? t.innerText : t.textContent);
    if (val == null || String(val).trim() === '') return;
    recordStep(AqRecorder.buildWriteStep(t, val, recAddress(), recSelector));
  }

  // editor_N живёт в iframe: события из него НЕ всплывают в верхний документ,
  // поэтому те же слушатели навешиваем на каждый доступный contentDocument.
  const _recFramedDocs = new WeakSet();
  function attachRecorderFrames() {
    let frames = [];
    try { frames = Array.prototype.slice.call(document.querySelectorAll('iframe, frame')); } catch (_e) { frames = []; }
    frames.forEach((f) => {
      let doc = null;
      try { doc = f.contentDocument; } catch (_e) { doc = null; }
      if (!doc || _recFramedDocs.has(doc)) return;   // кросс-домен/недоступен — тихо пропускаем
      _recFramedDocs.add(doc);
      doc.addEventListener('pointerdown', onRecPointerDown, true);
      doc.addEventListener('change', onRecChange, true);
      doc.addEventListener('blur', onRecBlur, true);
      // Событие из MAIN-мира не покидает свой документ — слушаем в каждом фрейме.
      doc.addEventListener(SAME_TAB_EVT, onSameTabOpen, true);
    });
  }

  function installRecorder() {
    document.addEventListener('pointerdown', onRecPointerDown, true);
    document.addEventListener('change', onRecChange, true);
    document.addEventListener('blur', onRecBlur, true);
    document.addEventListener(SAME_TAB_EVT, onSameTabOpen, true);
    // Врач может открыть редактор уже после старта записи — довешиваем iframe при фокусе.
    document.addEventListener('focusin', () => { if (S.recording) attachRecorderFrames(); }, true);
    attachRecorderFrames();
  }

  async function updateRecUi(count) {
    if (typeof count !== 'number') {
      const rec = await getRecording();
      count = rec && rec.steps ? rec.steps.length : 0;
    }
    el.trainCount.textContent = count;
    el.trainBtn.innerHTML = S.recording
      ? `${ICON.check} Остановить и сохранить`
      : `${ICON.wave} Начать обучение`;
    el.trainStatus.style.display = S.recording ? 'flex' : 'none';
    // Плавающий бейдж «● REC N» — виден и при свёрнутой панели.
    if (S.recording) {
      el.recBadge.style.display = 'flex';
      el.recBadgeText.textContent = 'REC ' + count;
    } else {
      el.recBadge.style.display = 'none';
    }
  }

  async function startTraining() {
    await setRecording({ active: true, startedAt: Date.now(), steps: [] });
    S.recording = true;
    applySameTabMode();
    attachRecorderFrames();
    updateRecUi(0);
    setStatus('Обучение: идёт запись');
  }

  async function stopTraining() {
    const rec = await getRecording();
    if (!rec) { S.recording = false; applySameTabMode(); updateRecUi(0); return; }
    const steps = rec.steps || [];
    if (!steps.length) {
      await clearRecording();
      S.recording = false;
      applySameTabMode();
      updateRecUi(0);
      setStatus('Нечего сохранять');
      return;
    }
    const name = prompt('Название шаблона:', 'Записанный шаблон');
    if (name === null) return;                           // отмена диалога — запись продолжается
    try {
      setStatus('Сохраняю шаблон и подбираю голосовые фразы…');
      const res = await bg('SRV_TEMPLATE_SAVE', { name: name || 'Без имени', steps, provider: CFG.provider });
      if (res && res.ok) {
        await clearRecording();
        S.recording = false;
        applySameTabMode();
        updateRecUi(0);
        renderTemplateList();
        setStatus('Шаблон сохранён на сервере: ' + res.name + ' (#' + res.id + ', ' + steps.length + ' шаг.)');
        // Врач должен сразу увидеть, ЧЕМ теперь запускать шаблон голосом:
        // фразы придумала модель, угадать их иначе невозможно.
        if (res.skill && (res.skill.triggers || []).length) {
          showReply('Теперь можно голосом: «' + res.skill.triggers.join('», «') + '»');
          log('info', 'Навык', res.name + ' — слотов: ' + ((res.skill.slots || []).length));
        }
      } else if (res && res.ok === false) {
        showReply(res.reason || 'Сервер отклонил шаблон', true);
      }
    } catch (e) {
      showReply('Сервер недоступен — шаблон не сохранён. Проверьте, что сервер запущен.', true);
    }
  }

  async function cancelTraining() {
    await clearRecording();
    S.recording = false;
    applySameTabMode();
    updateRecUi(0);
    setStatus('Обучение отменено');
  }

  // Скачиваем шаблон файлом «<id>.json» в структуре server/templates/20.json.
  // Список с сервера не несёт createdAt — передаём пустую строку (toTemplateFile
  // сама решает, что подставить).
  function downloadTemplate(tpl) {
    const file = AqRecorder.toTemplateFile(tpl.name, tpl.id, tpl.steps, '');
    const blob = new Blob([JSON.stringify(file, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = tpl.id + '.json';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  async function runTemplate(tpl) {
    openPanel();
    setStatus('Запуск шаблона: ' + tpl.name);
    await startRun({ steps: tpl.steps });
  }

  /* Пересобрать навык у уже записанного шаблона. Слоты код достроит и без
     этого, но подписи полей у них нейтральные, а образец стиля пуст — один
     вызов ИИ делает их человеческими, не заставляя переписывать шаблон. */
  async function reenrichTemplate(tpl) {
    setStatus('Обновляю навык: ' + tpl.name + '…');
    try {
      const res = await bg('SRV_TEMPLATE_REENRICH', { id: tpl.id, provider: CFG.provider });
      if (res && res.ok) {
        const trg = (res.skill && res.skill.triggers) || [];
        showReply(trg.length
          ? 'Теперь можно голосом: «' + trg.join('», «') + '»'
          : 'Навык обновлён, но фраз модель не предложила');
        setStatus('Навык обновлён: ' + res.name);
        renderTemplateList();
      } else {
        showReply((res && res.reason) || 'Не удалось обновить навык', true);
        setStatus('Готов');
      }
    } catch (e) {
      showReply('Сервер недоступен — навык не обновлён.', true);
      setStatus('Готов');
    }
  }

  async function deleteTemplate(id) {
    try { await bg('SRV_TEMPLATE_DELETE', { id }); } catch (e) { showReply('Не удалось удалить: ' + e.message, true); }
    renderTemplateList();
  }

  async function renderTemplateList() {
    el.tplList.innerHTML = '';
    let list = [];
    try {
      const res = await bg('SRV_TEMPLATE_LIST');
      list = (res && res.templates) || [];
    } catch (e) {
      el.tplList.innerHTML = '<div class="aq-tpl-empty">Сервер недоступен — список шаблонов не загружен.</div>';
      return;
    }
    if (!list.length) {
      el.tplList.innerHTML = '<div class="aq-tpl-empty">Пока нет шаблонов. Нажмите «Начать обучение».</div>';
      return;
    }
    list.forEach((tpl) => {
      const row = document.createElement('div');
      row.className = 'aq-tpl-item';
      // Врач должен видеть, чем шаблон запускается голосом и сколько в нём
      // диктуемых полей: иначе непонятно, почему текст не подставился.
      const sk = tpl.skill || {};
      const fields = (tpl.steps || []).filter((s) => s && s.method === 'write').length;
      const meta = [`${(tpl.steps || []).length} шаг(ов)`];
      if (fields) meta.push(`${fields} поле(й) под диктовку`);
      if ((sk.triggers || []).length) meta.push('«' + sk.triggers.slice(0, 2).join('», «') + '»');
      else meta.push('без голосовых фраз — нажмите ↻');
      row.innerHTML =
        `<div class="aq-tpl-info"><div class="aq-tpl-name">${escapeHtml(tpl.name)} <span class="aq-tpl-id">#${escapeHtml(String(tpl.id))}</span></div>` +
        `<div class="aq-tpl-meta">${escapeHtml(meta.join(' · '))}</div></div>` +
        `<div class="aq-tpl-actions">` +
        `<button class="aq-tpl-run" title="Выполнить">▶</button>` +
        `<button class="aq-tpl-skill" title="Обновить голосовые фразы и подписи полей">↻</button>` +
        `<button class="aq-tpl-dl" title="Скачать .json">⤓</button>` +
        `<button class="aq-tpl-del" title="Удалить">✕</button></div>`;
      row.querySelector('.aq-tpl-run').addEventListener('click', () => runTemplate(tpl));
      row.querySelector('.aq-tpl-skill').addEventListener('click', () => reenrichTemplate(tpl));
      row.querySelector('.aq-tpl-dl').addEventListener('click', () => downloadTemplate(tpl));
      row.querySelector('.aq-tpl-del').addEventListener('click', () => deleteTemplate(tpl.id));
      el.tplList.appendChild(row);
    });
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ИСПОЛНИТЕЛЬ ДЕЙСТВИЙ  (click / write / writeByClick, много-шаг/страниц)
   * ════════════════════════════════════════════════════════════════════ */
  function normalizePlan(resp) {
    if (!resp) return [];
    if (Array.isArray(resp)) return resp;
    if (Array.isArray(resp.steps)) return resp.steps;
    if (resp.selector || resp.method) return [resp];
    if (resp.reply || resp.message) { showReply(resp.reply || resp.message); }
    return [];
  }

  /* Постоянная очередь шагов в chrome.storage — переживает переход между
     страницами (и полный reload, и SPA-навигацию). */
  const RESUME_WINDOW_MS = 120000;   // окно ожидания перехода/загрузки страницы
  const STEP_WAIT_MS = 4000;             // ждать элемент на обычном шаге (в пределах уже загруженной страницы)
  const STEP_WAIT_AFTER_NAV_MS = 15000;  // первый шаг ПОСЛЕ перехода: страница ещё дорисовывает динамику — ждём дольше
  const READY_WAIT_MS = 12000;           // ждать document.readyState=complete после перехода (условие, не догадка)
  function getPending() {
    return new Promise((r) => chrome.storage.local.get(PENDING_KEY, (s) => r(s[PENDING_KEY] || null)));
  }
  function setPending(p) {
    // Флаг ВЫВОДИМ из самой очереди, а не взводим: setPending зовётся и перед
    // последним шагом (index уже == steps.length), и в ветках resumeRun, из
    // которых мы можем выйти по return — «включили и забыли» оставило бы режим
    // висеть на вкладке до перезагрузки.
    _sameTabPending = !!(p && p.steps && p.index < p.steps.length);
    _sameTabArmedAt = Date.now();
    _pendingWriteMark = pendingMark(p);   // «эту запись сделали мы» — см. onChanged
    applySameTabMode();
    return new Promise((r) => chrome.storage.local.set({ [PENDING_KEY]: p }, r));
  }
  function clearPending() {
    _sameTabPending = false;
    applySameTabMode();
    return new Promise((r) => chrome.storage.local.remove(PENDING_KEY, r));
  }
  function normAddr(u) {
    try { const a = new URL(u, location.href); return a.origin + a.pathname.replace(/\/+$/, ''); }
    catch (_e) { return String(u || '').replace(/\/+$/, ''); }
  }
  function sameAddr(a, b) {
    if (!a || !b) return true;   // нет адреса ⇒ считаем той же страницей (без границы)
    return normAddr(a) === normAddr(b);
  }

  function samePage(addr) {
    if (!addr) return true;
    try {
      const a = new URL(addr, location.href);
      return a.origin + a.pathname === location.origin + location.pathname;
    } catch (_e) { return addr === location.href; }
  }

  async function startRun(resp) {
    const steps = normalizePlan(resp);
    if (!steps.length) {
      // сервер вернул только текст — он уже показан в normalizePlan
      if (!(resp && (resp.reply || resp.message))) showReply('Готово');
      setStatus('Готов');
      return;
    }
    // Новый план вытесняет любой прежний (в т.ч. недоделанную цепочку)
    await setPending({ runId: Date.now(), steps, index: 0, armedAt: Date.now(), waitingNav: false, expectAddress: null });
    if (steps.length > 1) log('info', 'План принят', steps.length + ' шаг(ов)');
    await driveRun('fresh');
  }

  /* Двигатель очереди. Исполняет шаги по одному и СОХРАНЯЕТ остаток В ПАМЯТЬ
     ПЕРЕД каждым шагом (index уже указывает на следующий). Поэтому, если шаг
     вызывает переход и страница выгружается — остаток уцелеет и продолжится на
     новой странице через resumeRun(). Ручная навигация ничего не запускает:
     возобновление разрешено только при waitingNav (осознанный переход). */
  async function driveRun(source) {
    if (S.runBusy) return;
    S.runBusy = true;
    // Прогон, начатый после перехода (resumeRun), исполняет первый шаг на свежей
    // странице, которая могла ещё не дорисовать нужный элемент — даём ему больший
    // бюджет поиска. Последующие шаги идут по уже загруженной странице.
    let postNav = (source === 'resume');
    try {
      let p = await getPending();
      if (!p || !p.steps) return;
      el.runProgress.style.display = 'block';

      while (p && p.index < p.steps.length) {
        const step = p.steps[p.index];
        const total = p.steps.length;
        const human = p.index + 1;

        // Не на той странице для текущего шага — вооружаемся и ждём перехода.
        // (index 0 всегда исполняется на текущей странице — как первый сегмент.)
        if (p.index > 0 && step.address && !samePage(step.address)) {
          await setPending({ ...p, armedAt: Date.now(), waitingNav: true, expectAddress: step.address });
          showChain(step.address);
          setStatus('Жду страницу…');
          showReply('Выполнено ' + p.index + '/' + total + '. Продолжу на: ' + shortUrl(step.address));
          hideRunProgressSoon();
          return;
        }

        // Ожидается ли переход ПОСЛЕ этого шага? (следующий шаг — на другой странице,
        // либо сервер явно пометил шаг как навигационный: step.navigates === true)
        const next = p.steps[p.index + 1];
        const nextAddr = next && next.address;
        const willNavigate = (step.navigates === true) ||
          (!!next && !!nextAddr && !sameAddr(nextAddr, step.address || location.href));
        const expectAddr = willNavigate ? (nextAddr || step.next_address || null) : null;

        el.runStepLabel.textContent = describeStep(step);
        el.runStepCount.textContent = human + '/' + total;
        el.runBar.style.width = Math.round((human / total) * 100) + '%';

        // КЛЮЧЕВОЕ: сохраняем ПЕРЕД шагом — index указывает на следующий,
        // waitingNav взведён, если ждём перехода.
        const advanced = { ...p, index: p.index + 1, armedAt: Date.now(),
                           waitingNav: willNavigate, expectAddress: expectAddr };
        await setPending(advanced);

        try {
          await runStep(step, postNav ? STEP_WAIT_AFTER_NAV_MS : STEP_WAIT_MS);
        } catch (e) {
          log('error', 'Шаг ' + human, e.message);
          showReply('Ошибка на шаге ' + human + ': ' + e.message, true);
        }
        postNav = false;   // расширенное ожидание — только первому шагу после перехода

        if (willNavigate) {
          // Остаток уже в памяти — ждём фактического перехода (reload или SPA).
          showChain(expectAddr || location.href);
          setStatus('Переход на страницу…');
          showReply('Шаг ' + human + '/' + total + ' выполнен. Перехожу дальше…');
          log('info', 'Ожидаю переход', 'после шага ' + human + '/' + total);
          hideRunProgressSoon();
          return;
        }

        await sleep(220);
        p = advanced;
      }

      // Все шаги выполнены
      await clearPending();
      showChain(null);
      showReply('Все шаги выполнены');
      setStatus('Готов');
      hideRunProgressSoon();
    } finally {
      S.runBusy = false;
    }
  }

  function hideRunProgressSoon() {
    setTimeout(() => { el.runProgress.style.display = 'none'; }, 900);
  }
  function showChain(addr) {
    // Пустой/нечитаемый адрес — не бейдж «Ждёт: », а просто нечего показывать.
    const name = addr ? shortUrl(addr) : '';
    if (!name) { el.chainBadge.style.display = 'none'; return; }
    el.chainBadge.style.display = 'flex';
    el.chainName.textContent = 'Ждёт: ' + name;
  }
  function shortUrl(u) {
    try {
      const a = new URL(u, location.href);
      // pathname у корня — «/», по нему шаг не опознать: показываем хост.
      return (a.pathname && a.pathname !== '/') ? a.pathname : a.host;
    } catch (_e) { return String(u || '').trim(); }
  }

  function describeStep(st) {
    if (st.method === 'goto') return 'Переход: ' + shortUrl(st.value || st.address || '');
    if (st.method === 'click') return 'Клик: ' + (st.selector || '');
    return 'Ввод: ' + (st.value != null ? String(st.value).slice(0, 24) : '');
  }

  async function runStep(st, waitMs) {
    const t0 = Date.now();
    dbg('Шаг: ' + (st.method || '?'),
        'селектор: ' + (st.selector || '') + (st.value != null ? '\nзначение: ' + preview(st.value, 200) : ''));

    /* Прямой переход по адресу. Селектора у такого шага нет — искать нечего,
       поэтому выходим ДО resolveElWait. Сервер строит такие шаги из накопленной
       карты страниц и из ids.jsonl: один переход вместо цепочки кликов по меню,
       и он не ломается, когда Damumed переставит кнопку.
       Уходим только на свой origin: план приходит с локального сервера, но
       увести вкладку врача на произвольный сайт он всё равно не должен. */
    if (st.method === 'goto') {
      const dest = String(st.value || st.address || '');
      let target = null;
      try { target = new URL(dest, location.href); } catch (_e) { target = null; }
      if (!target || target.origin !== location.origin) {
        throw new Error('Переход отклонён (чужой адрес): ' + dest);
      }
      if (target.href === location.href) {
        log('info', 'Переход', 'уже на этой странице: ' + shortUrl(target.href));
        return;
      }
      log('success', 'Переход', shortUrl(target.href));
      location.assign(target.href);
      return;
    }

    // Обычная document.querySelector-попытка бывает "слишком ранней": iframe-редактор
    // (editor_N_frame) на damumed может ещё не быть вставлен/инициализирован в момент
    // выполнения шага, а первый шаг ПОСЛЕ перехода вообще исполняется до того, как
    // страница дорисовала динамический контент. Поэтому опрашиваем resolveEl каждые
    // 150мс до истечения бюджета (waitMs), прежде чем считать элемент отсутствующим.
    const node = await resolveElWait(st.selector, waitMs || STEP_WAIT_MS);
    if (!node) {
      dbg('Селектор не найден', st.selector + ' — искали ' + (Date.now() - t0) + ' мс');
      diagnoseSelector(st.selector);
      throw new Error('Элемент не найден: ' + st.selector);
    }
    dbg('Селектор найден', st.selector + ' за ' + (Date.now() - t0) + ' мс');
    node.scrollIntoView({ block: 'center', behavior: 'instant' in node ? 'instant' : 'auto' });

    if (st.method === 'click') {
      clickEl(node);
      log('success', 'Клик', st.selector);
      return;
    }
    // method === 'write'
    const val = st.value != null ? String(st.value) : '';

    // Особое поле построчного редактора (damumed): <body id="editor_N" contenteditable="true">
    // внутри <iframe id="editor_N_frame">. Реальный ввод с клавиатуры сам оборачивает каждую
    // новую строку в <div>, а голое node.innerHTML = val ломает эту структуру (весь текст
    // схлопывается в одну "строку" для скриптов страницы, читающих DOM построчно).
    // Поэтому перехватываем запись в такое поле независимо от переданного type_write и сами
    // строим нужную построчную HTML-структуру.
    if (isLineEditorBody(node)) {
      node.focus();
      node.innerHTML = buildEditorLinesHtml(val);
      placeCaretAtEnd(node);
      node.dispatchEvent(new Event('input', { bubbles: true }));
      node.dispatchEvent(new Event('change', { bubbles: true }));
      log('success', 'Построчный ввод', st.selector + ' ← ' + val.slice(0, 40));
      return;
    }

    if (st.type_write === 'changeInnerHTML') {
      node.innerHTML = val;
      node.dispatchEvent(new Event('input', { bubbles: true }));
      log('success', 'HTML', st.selector);
    } else if (st.type_write === 'writeByClick') {
      // div, слушающий клавиатуру: фокусируем кликом, затем макрос pyAutoGui
      node.focus();
      clickEl(node);
      await sleep(120);
      await bg('SRV_MACRO', { value: val });
      log('success', 'Макрос-ввод', st.selector + ' ← ' + val);
    } else {
      // обычный input/textarea — сначала пробуем через API kendo-виджета
      // (если он есть на элементе), иначе — обычная нативная запись value.
      const viaKendo = await trySetKendoValue(node, val);
      if (viaKendo) {
        log('success', 'Kendo-ввод', st.selector + ' ← ' + val);
      } else {
        setNativeValue(node, val);
        log('success', 'Ввод', st.selector + ' ← ' + val);
      }
    }
  }

  /* ─── Особое построчное contenteditable-поле (damumed editor_N) ─────────── */

  // Опознаём поле по его собственной DOM-разметке, а не по строке селектора:
  // так это работает для editor_0, editor_1, editor_2... без привязки к номеру.
  function isLineEditorBody(node) {
    return !!node && node.nodeType === 1 && node.tagName === 'BODY' &&
      node.isContentEditable && /^editor_\d+$/.test(node.id || '');
  }

  // Строит innerHTML по правилу редактора:
  //  - первая строка ВСЕГДА голым текстом (без <div>), пустая первая строка -> <div><br></div>
  //  - каждая следующая строка оборачивается в <div>...</div>
  //  - пустая строка (не первая) -> <div><br></div>
  function buildEditorLinesHtml(text) {
    const lines = String(text == null ? '' : text).split(/\r\n|\r|\n/);
    let html = '';
    lines.forEach((line, i) => {
      if (i === 0) {
        html += line === '' ? '<div><br></div>' : escapeHtml(line);
      } else {
        html += line === '' ? '<div><br></div>' : '<div>' + escapeHtml(line) + '</div>';
      }
    });
    return html;
  }

  // Ставим курсор в конец после программной вставки — иначе он остаётся там,
  // где был до этого (обычно в начале), что неудобно для последующего ручного редактирования врачом.
  function placeCaretAtEnd(node) {
    try {
      const docWin = node.ownerDocument.defaultView || window;
      const range = node.ownerDocument.createRange();
      range.selectNodeContents(node);
      range.collapse(false);
      const sel = docWin.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    } catch (_e) { /* не критично, если не получилось — контент уже вставлен */ }
  }

  /* ─── Поиск элемента, в т.ч. сквозь iframe ───────────────────────────────
     document.querySelector НЕ пересекает границу iframe (там отдельный DOM-документ),
     поэтому селекторы вида "iframe#editor_0_frame > body#editor_0" на верхнем документе
     ничего не находят. resolveEl() сначала пробует обычный путь (быстрый, работает для
     99% полей вне iframe), а если не нашёл — разбирает селектор на сегменты и на каждой
     границе, где сегмент-префикс указывает на <iframe>/<frame>, "проваливается" в его
     contentDocument и продолжает поиск остатка селектора уже там. Работает рекурсивно —
     то есть и для вложенных iframe. */
  function resolveEl(selector) {
    if (!selector) return null;
    try {
      const direct = document.querySelector(selector);
      if (direct) return direct;
    } catch (_e) { /* возможно, селектор осмысленен только после спуска в iframe */ }
    try { return resolveAcrossFrames(document, selector); } catch (_e) { return null; }
  }

  // Опрашивает resolveEl, пока элемент не появится или не истечёт таймаут — нужно для
  // редакторов, чей iframe/body монтируется в DOM не мгновенно (см. runStep).
  async function resolveElWait(selector, timeoutMs) {
    const start = Date.now();
    let node = resolveEl(selector);
    while (!node && (Date.now() - start) < timeoutMs) {
      await sleep(150);
      node = resolveEl(selector);
    }
    return node;
  }

  // Проходит селектор сегмент за сегментом и логирует, ГДЕ именно поиск оборвался —
  // чтобы отличить "элемента правда нет" от "iframe есть, но contentDocument недоступен"
  // (кросс-домен/сендбокс) или "это не iframe вовсе". Не бросает исключений сама.
  // Собирает "карту" обхода: сколько iframe встретили, сколько из них были доступны
  // (contentDocument не null), и не нашёлся ли селектор ни в одном из них. Используется
  // только для лога — сама resolveAcrossFrames уже решила, что элемента нет.
  function diagnoseSelector(selector) {
    try {
      const report = { checkedDocs: 0, framesTotal: 0, framesBlocked: 0, framesFound: [] };
      walkDiagnose(document, selector, report, '(верхний документ)');
      if (report.framesTotal === 0) {
        log('warn', 'Диагностика селектора', 'iframe на странице не найдено вовсе, а в верхнем документе элемента нет: ' + selector);
      } else if (report.framesBlocked > 0 && report.framesBlocked === report.framesTotal) {
        log('warn', 'Диагностика селектора', 'Найдено iframe: ' + report.framesTotal + ', но ни один недоступен (contentDocument = null — кросс-домен/sandbox/не загрузился): ' + selector);
      } else {
        log('warn', 'Диагностика селектора', 'Проверено документов: ' + report.checkedDocs + ' (из них iframe: ' + report.framesTotal +
          ', недоступно: ' + report.framesBlocked + '). Ни в одном не нашёлся: ' + selector);
      }
    } catch (e) {
      log('warn', 'Диагностика селектора', 'Ошибка диагностики: ' + e.message);
    }
  }

  function walkDiagnose(doc, selector, report, label) {
    report.checkedDocs++;
    let direct = null;
    try { direct = doc.querySelector(selector); } catch (_e) { /* синтаксически невалиден целиком в этом доке — не страшно */ }
    if (direct) { report.framesFound.push(label); return true; }

    let frames = [];
    try { frames = Array.prototype.slice.call(doc.querySelectorAll('iframe, frame')); } catch (_e) { frames = []; }
    for (let idx = 0; idx < frames.length; idx++) {
      report.framesTotal++;
      const frame = frames[idx];
      let innerDoc = null;
      try { innerDoc = frame.contentDocument; } catch (_e) { innerDoc = null; }
      if (!innerDoc) { report.framesBlocked++; continue; }
      if (walkDiagnose(innerDoc, selector, report, label + ' → iframe#' + (idx + 1))) return true;
    }
    return false;
  }

  function resolveAcrossFrames(doc, selector) {
    if (!selector) return null;
    try {
      const direct = doc.querySelector(selector);
      if (direct) return direct;
    } catch (_e) { /* ignore, попробуем спуститься по сегментам/фреймам ниже */ }

    // 1) Явная цепочка сегментов: селектор САМ описывает путь через iframe,
    //    например "iframe#x > body#y". Работает только если у iframe есть
    //    подходящий id/класс, по которому его можно найти обычным querySelector.
    const segs = splitSelectorSegments(selector);
    if (segs.length >= 2) {
      for (let i = segs.length - 1; i >= 1; i--) {
        const prefixSel = rebuildSelector(segs.slice(0, i));
        let host = null;
        try { host = doc.querySelector(prefixSel); } catch (_e) { continue; }
        if (!host || !/^i?frame$/i.test(host.tagName)) continue;

        let innerDoc = null;
        try { innerDoc = host.contentDocument; } catch (_e) { innerDoc = null; }
        if (!innerDoc) continue; // кросс-домен либо фрейм ещё не загружен

        const restSegs = segs.slice(i);
        restSegs[0] = { combinator: null, selector: restSegs[0].selector }; // без ведущего комбинатора
        const restSel = rebuildSelector(restSegs);
        const found = resolveAcrossFrames(innerDoc, restSel);
        if (found) return found;
      }
    }

    // 2) Общий обход: сам iframe часто БЕЗ id/класса (как в редакторе TINY.editor
    //    на damumed — <iframe> создаётся без атрибутов, а id вроде "editor_0" library
    //    присваивает только внутреннему <body> через свою конфигурацию). В таком случае
    //    в селекторе нет и не может быть пути через iframe ("#editor_0" — один сегмент).
    //    Поэтому рекурсивно пробуем ТОТ ЖЕ селектор внутри document каждого вложенного
    //    iframe/frame — независимо от того, есть ли у них id.
    let frames = [];
    try { frames = Array.prototype.slice.call(doc.querySelectorAll('iframe, frame')); } catch (_e) { frames = []; }
    for (const frame of frames) {
      let innerDoc = null;
      try { innerDoc = frame.contentDocument; } catch (_e) { innerDoc = null; }
      if (!innerDoc) continue; // кросс-домен либо ещё не загрузился
      const found = resolveAcrossFrames(innerDoc, selector);
      if (found) return found;
    }
    return null;
  }

  // Разбивает цепочку селекторов на сегменты вида { combinator, selector },
  // не путая пробелы/скобки внутри [attr="со значением с пробелом"] или кавычек.
  function splitSelectorSegments(sel) {
    const segments = [];
    let buf = '';
    let depth = 0;
    let quote = null;
    let pendingCombinator = null;
    for (let i = 0; i < sel.length; i++) {
      const ch = sel[i];
      if (quote) { buf += ch; if (ch === quote) quote = null; continue; }
      if (ch === '"' || ch === "'") { quote = ch; buf += ch; continue; }
      if (ch === '[') { depth++; buf += ch; continue; }
      if (ch === ']') { depth = Math.max(0, depth - 1); buf += ch; continue; }
      if (depth > 0) { buf += ch; continue; }
      if (ch === '>' || ch === '~' || ch === '+') {
        if (buf.trim()) { segments.push({ combinator: pendingCombinator, selector: buf.trim() }); buf = ''; }
        pendingCombinator = ch;
        continue;
      }
      if (/\s/.test(ch)) {
        if (buf.trim()) {
          let j = i; while (j < sel.length && /\s/.test(sel[j])) j++;
          const next = sel[j];
          if (next === '>' || next === '~' || next === '+') {
            segments.push({ combinator: pendingCombinator, selector: buf.trim() });
            buf = ''; pendingCombinator = null; // сам комбинатор возьмётся из ветки выше
          } else {
            segments.push({ combinator: pendingCombinator, selector: buf.trim() });
            buf = ''; pendingCombinator = ' ';
          }
        }
        continue;
      }
      buf += ch;
    }
    if (buf.trim()) segments.push({ combinator: pendingCombinator, selector: buf.trim() });
    return segments;
  }

  function rebuildSelector(segs) {
    return segs.map((s, idx) => {
      if (idx === 0 || !s.combinator) return s.selector;
      return (s.combinator === ' ' ? ' ' : ' ' + s.combinator + ' ') + s.selector;
    }).join('');
  }
  function clickEl(node) {
    ['pointerdown', 'mousedown', 'mouseup', 'click'].forEach((type) => {
      node.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
    });
  }
  function setNativeValue(node, value) {
    const proto = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value');
    node.focus();
    if (setter && setter.set) setter.set.call(node, value); else node.value = value;
    node.dispatchEvent(new Event('input', { bubbles: true }));
    node.dispatchEvent(new Event('change', { bubbles: true }));
  }

  /* ─── Kendo-виджеты (kendoNumericTextBox, kendoDropDownList, kendoComboBox,
     kendoDatePicker и т.д.) ──────────────────────────────────────────────
     Kendo хранит "реальное" значение виджета не в самом <input>, а во внутреннем
     JS-объекте, привязанном к элементу через jQuery.data(). Пока мы пишем только
     в input.value (см. setNativeValue), виджет об этом не знает и продолжает
     использовать своё старое значение — оно "подхватывается" только когда
     пользователь кликает по полю (виджет в этот момент сам перечитывает DOM).
     Корректный способ — дёрнуть API самого виджета: value(x) плюс trigger('change').

     ВАЖНО: content script (этот файл) выполняется в ИЗОЛИРОВАННОМ JS-мире —
     он видит DOM страницы, но НЕ видит её JS-объекты. window.jQuery здесь —
     это не та jQuery, которую использует сама страница (и Kendo), поэтому
     $(node).data('kendoNumericTextBox') из этого файла никогда ничего не найдёт,
     даже если на странице реально есть kendo. Первая версия этой функции была
     именно такой и потому молча всегда возвращала false.
     Чтобы реально достучаться до объекта виджета, нужно выполнить код в
     MAIN-мире страницы. Изолированный content script не может это сделать сам —
     зато это может background (service worker) через chrome.scripting.executeScript
     с { world: 'MAIN' } (права 'scripting' + host_permissions у нас уже есть).
     Поэтому: помечаем нужный элемент временной уникальной меткой-атрибутом,
     просим background выполнить функцию во всех фреймах вкладки (виджет может
     быть внутри iframe), там находим элемент по метке и работаем с его
     jQuery.data() уже в правильном контексте. */
  async function trySetKendoValue(node, rawValue) {
    const marker = 'kx' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    const prevMarker = node.getAttribute('data-aq-kendo-target');
    node.setAttribute('data-aq-kendo-target', marker);
    try {
      const res = await bg('SET_KENDO_VALUE', { marker, value: rawValue });
      if (res && res.applied) return true;
      // Не получилось — логируем ПРИЧИНУ в панель расширения (вкладка "Лог"),
      // чтобы не гадать вслепую, а видеть, что конкретно пошло не так.
      log('warn', 'Kendo', (res && res.reason) || 'Неизвестная причина отказа');
      return false;
    } catch (_e) {
      log('warn', 'Kendo', 'Ошибка вызова background: ' + (_e && _e.message));
      return false;
    } finally {
      if (prevMarker == null) node.removeAttribute('data-aq-kendo-target');
      else node.setAttribute('data-aq-kendo-target', prevMarker);
    }
  }
  function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

  // Ждём, пока страница догрузится (readyState=complete) ИЛИ истечёт лимит.
  // Условие вместо гадания фиксированной паузой (см. resumeRun): на полной
  // перезагрузке DOM с динамикой появляется уже после старта content.js.
  async function waitForReady(timeoutMs) {
    const start = Date.now();
    while (document.readyState !== 'complete' && (Date.now() - start) < timeoutMs) {
      await sleep(100);
    }
  }

  /* Возобновление плана после перехода (полный reload ИЛИ SPA-навигация).
     Срабатывает ТОЛЬКО если переход был осознанным (waitingNav=true) — так
     ручная навигация врача по сайту ничего случайно не запускает. */
  async function resumeRun(source) {
    const p = await getPending();
    if (!p || !p.steps || p.index >= p.steps.length) return;
    const fresh = (Date.now() - (p.armedAt || 0)) < RESUME_WINDOW_MS;
    if (!fresh) { await clearPending(); showChain(null); return; }
    if (!p.waitingNav) return;                                        // не наш переход — не вмешиваемся
    // Ещё не дошли. Бейдж «Ждёт: …» здесь НЕ рисуем: эта ветка отрабатывает при
    // загрузке ЛЮБОЙ страницы Damumed, пока в очереди висит план, — в том числе
    // на вкладке, которая к плану отношения не имеет. Такая вкладка сама очередь
    // не пишет, снять надпись ей потом нечем, и «Ждёт: …» оставалось висеть до
    // перезагрузки. Ждущую страницу показывает только та вкладка, что ведёт план.
    if (p.expectAddress && !samePage(p.expectAddress)) return;
    // Мы на нужной странице — снимаем флаг ожидания и продолжаем
    await setPending({ ...p, waitingNav: false });
    // content.js стартует на document_idle — раньше, чем страница дорисует динамику.
    // Ждём ФАКТИЧЕСКОЕ условие (страница догрузилась), а не фиксированную паузу-догадку;
    // остаток «медленного» рендера добирает увеличенный бюджет resolveElWait на первом шаге.
    await waitForReady(READY_WAIT_MS);
    await sleep(300);                                               // небольшой буфер на первичный рендер после complete
    const still = await getPending();
    if (!still || still.runId !== p.runId) return;                   // нас опередил новый запуск
    openPanel();
    log('info', 'Продолжаю план', 'шаг ' + (p.index + 1) + '/' + p.steps.length);
    await driveRun('resume');
  }

  // SPA-роутеры меняют URL без перезагрузки, а content.js не переинъектируется —
  // поэтому следим за сменой location и дёргаем возобновление.
  function installUrlWatcher() {
    let last = location.href;
    const fire = () => {
      if (location.href === last) return;
      last = location.href;
      setTimeout(() => resumeRun('urlchange'), 350);
    };
    window.addEventListener('popstate', fire);
    window.addEventListener('hashchange', fire);
    // Страховка для роутеров, не бросающих события истории. Заодно — единственный
    // тик, на котором протухший план снимает режим «в текущей вкладке» и бейдж
    // «Ждёт: …» (второй таймер ради этого заводить незачем).
    setInterval(() => { fire(); applySameTabMode(); }, 800);
  }

  /* ════════════════════════════════════════════════════════════════════
   *  СКАНЕР СТРАНИЦЫ
   * ════════════════════════════════════════════════════════════════════ */
  function cssPath(node) {
    if (node.id) return '#' + CSS.escape(node.id);
    const parts = [];
    let e = node;
    while (e && e.nodeType === 1 && parts.length < 6) {
      let sel = e.nodeName.toLowerCase();
      if (e.parentNode) {
        const sibs = Array.from(e.parentNode.children).filter((c) => c.nodeName === e.nodeName);
        if (sibs.length > 1) sel += ':nth-child(' + (Array.from(e.parentNode.children).indexOf(e) + 1) + ')';
      }
      parts.unshift(sel);
      if (e.id) { parts[0] = '#' + CSS.escape(e.id); break; }
      e = e.parentElement;
    }
    return parts.join(' > ');
  }

  // ────────────────────────────────────────────────────────────────────
  // Подготовка HTML к отправке в сканер: экономим токены на сервере.
  // ────────────────────────────────────────────────────────────────────
  const SCAN_HTML_MAX_CHARS = 220000; // жёсткий потолок длины HTML на скан

  function trimHtmlForScan(docEl) {
    if (!docEl) return '';
    let clone;
    try { clone = docEl.cloneNode(true); } catch (_e) { return ''; }

    // 1) Сам виджет расширения — никогда не должен попадать в скан
    //    (иначе сервер сканирует собственную панель вместо страницы врача).
    clone.querySelectorAll('#aqbobek-root').forEach((n) => n.remove());

    // 2) Мёртвый вес, бесполезный для сканера полей/кнопок, но раздувающий HTML
    clone.querySelectorAll('script, style, link, meta, noscript, svg, template').forEach((n) => n.remove());

    // 3) HTML-комментарии
    try {
      const walker = document.createTreeWalker(clone, NodeFilter.SHOW_COMMENT, null);
      const toRemove = [];
      let node;
      while ((node = walker.nextNode())) toRemove.push(node);
      toRemove.forEach((n) => n.remove());
    } catch (_e) {}

    // 4) Тяжёлые/неинформативные атрибуты: style, on*-обработчики, data:-URI, srcset
    clone.querySelectorAll('*').forEach((n) => {
      if (n.hasAttribute('style')) n.removeAttribute('style');
      if (n.hasAttribute('srcset')) n.removeAttribute('srcset');
      Array.from(n.attributes || []).forEach((attr) => {
        // onclick сохраняем: серверные динамические сканеры (first_scan.py, _JS_COMMON/
        // _JS_MEDICAL_RECORD и др.) находят кнопки/действия ТОЛЬКО по a[onclick], button[onclick]
        // и по содержимому самой строки onclick (buildOnclickSelector/actionSelector). Без него
        // такие сканеры (например medical_record) возвращают 0 элементов. Прочие on*-обработчики
        // по-прежнему вырезаем ради экономии токенов.
        if (/^on/i.test(attr.name) && attr.name.toLowerCase() !== 'onclick') n.removeAttribute(attr.name);
        else if ((attr.name === 'src' || attr.name === 'href' || attr.name === 'poster') && /^data:/i.test(attr.value || '')) {
          n.setAttribute(attr.name, '');
        }
      });
    });

    let html = clone.outerHTML || '';
    // 5) Схлопываем переносы строк и повторяющиеся пробелы между тегами
    html = html.replace(/[\t\n\r]+/g, ' ').replace(/ {2,}/g, ' ');

    // 6) Жёсткий потолок длины — на случай очень тяжёлых страниц
    if (html.length > SCAN_HTML_MAX_CHARS) {
      html = html.slice(0, SCAN_HTML_MAX_CHARS) + ' <!-- […обрезано для экономии токенов…] -->';
    }
    return html;
  }

  function collectPageContext() {
    const values = {};
    const items = [];
    const nodes = document.querySelectorAll('input, textarea, select, button, a[href], [role="button"], [contenteditable="true"]');
    nodes.forEach((n) => {
      if (root.contains(n)) return;
      const path = cssPath(n);
      const tag = n.tagName.toLowerCase();
      let type = tag;
      if (tag === 'input') type = (n.type || 'text');
      const val = ('value' in n ? n.value : n.textContent || '').toString().trim().slice(0, 200);
      if (val) values[path] = val;
      const label = (n.getAttribute('placeholder') || n.getAttribute('aria-label') || n.getAttribute('title') || (n.textContent || '').trim()).slice(0, 80);
      items.push({ tag, type, path, value: val, label });
    });
    return { html: trimHtmlForScan(document.documentElement), values, items, url: location.href, iframeHtml: findEditorFrameDocumentHtml() };
  }

  // document.documentElement.outerHTML главной страницы НЕ включает содержимое iframe
  // (это физически отдельный документ) — а серверный сканер дневника (first_scan.py:
  // scan_diary) читает текущий текст поля editor_N именно из HTML этого iframe.
  // Ищем ПЕРВЫЙ contenteditable body#editor_N в любом (в т.ч. вложенном) iframe и
  // отдаём outerHTML его documentElement — ровно то, что ждёт серверный код.
  function findEditorFrameDocumentHtml() {
    function walk(doc) {
      let frames = [];
      try { frames = Array.prototype.slice.call(doc.querySelectorAll('iframe, frame')); } catch (_e) { frames = []; }
      for (const frame of frames) {
        let innerDoc = null;
        try { innerDoc = frame.contentDocument; } catch (_e) { innerDoc = null; }
        if (!innerDoc) continue;
        let body = null;
        try { body = innerDoc.body; } catch (_e) { body = null; }
        if (isLineEditorBody(body)) {
          try { return trimHtmlForScan(innerDoc.documentElement); } catch (_e) { /* falls through to nested search */ }
        }
        const nested = walk(innerDoc);
        if (nested) return nested;
      }
      return null;
    }
    try { return walk(document); } catch (_e) { return null; }
  }

  /* ── Заполнение мед. записи (Damumed, editMedicalRecord) ─────────────────
     Данные уже есть на странице: 16 блоков лежат в JS-модели, а последняя
     мед. запись достаётся тем же API, что питает грид на medicalHistory.
     Поэтому никаких переходов — врач остаётся на странице.
     Разворачиваем HTML в текст ЗДЕСЬ: у service worker нет DOM. */
  function isMedRecordPage() {
    return /\/patientMedicalRecord\/editMedicalRecord/i.test(location.pathname);
  }

  /* Обновляем карточку пациента тем, что уже собрали. Тихо: врач не просил
     сохранять, и ошибка локального сервера не должна прерывать заполнение. */
  async function savePatientCard(ids, history) {
    const known = {};
    if (ids && ids.patientAdmissionRegisterID) known.patientAdmissionRegisterID = String(ids.patientAdmissionRegisterID);
    if (ids && ids.medicalHistoryID) known.medicalHistoryID = String(ids.medicalHistoryID);
    if (!known.patientAdmissionRegisterID) return;   // писать некуда

    try {
      const resp = await bg('SRV_PATIENT_SAVE', {
        ids: known,
        full_name: AqPatientIds.extractFullNameFromTitle(document.title) || null,
        records: history.slice(0, 3)
      });
      dbg('Карточка пациента', resp && resp.ok ? 'сохранена: ' + resp.key : 'не сохранена: ' + ((resp && resp.reason) || '?'));
    } catch (e) {
      dbg('Карточка пациента', 'не сохранена: ' + e.message);
    }
  }

  /* ── Журнал ids.jsonl ────────────────────────────────────────────────
     Пассивный сбор: врач на …/medicalHistory/medicalHistory и активна
     вкладка «Медицинские записи» (есть .mh-medicalrecords.active) — снимаем
     три id + ФИО из div.patient-info и шлём на локальный сервер.
     Ту же самую запись повторно не шлём. */
  let lastIdsSent = '';

  function collectPatientIdsEntry() {
    let mhId = null;
    try { mhId = new URL(location.href).searchParams.get('id'); } catch (_e) {}
    if (mhId && !/^\d+$/.test(mhId)) mhId = null;

    let edit = null;
    let editFromDropdown = false;
    document.querySelectorAll('a[onclick*="onEditButtonClick"]').forEach((a) => {
      if (editFromDropdown || root.contains(a)) return;
      const parsed = AqPatientIds.editIdFromOnclick(a.getAttribute('onclick'));
      if (!parsed) return;
      if (parsed.fromDropdown) { edit = parsed.id; editFromDropdown = true; }
      else if (!edit) edit = parsed.id;
    });

    let watch = null;
    document.querySelectorAll('a[onclick*="onViewButtonClick"]').forEach((a) => {
      if (watch || root.contains(a)) return;
      watch = AqPatientIds.watchIdFromOnclick(a.getAttribute('onclick'));
    });

    const h5 = document.querySelector('.patient-info h5');
    const name = h5 ? AqPatientIds.fioFromText(h5.textContent) : '';

    if (!mhId && !edit) return null;   // без якорного id серверу писать некуда
    return {
      medicalHistory: mhId ? Number(mhId) : null,
      editMedicalRecord: edit ? Number(edit) : null,
      watch: watch ? Number(watch) : null,
      name
    };
  }

  async function harvestPatientIds() {
    if (!/\/medicalHistory\/medicalHistory/i.test(location.pathname)) return;
    if (!document.querySelector('.mh-medicalrecords.active')) return;
    const entry = collectPatientIdsEntry();
    if (!entry) return;
    const key = JSON.stringify(entry);
    if (key === lastIdsSent) return;
    try {
      const resp = await bg('SRV_IDS_SAVE', { entry });
      if (resp && resp.ok) {
        lastIdsSent = key;
        dbg('Журнал id', (resp.changed ? 'записан: ' : 'уже известен: ') + (entry.name || entry.medicalHistory));
      }
    } catch (e) {
      dbg('Журнал id', 'сервер недоступен: ' + e.message);
    }
  }

  function installPatientIdsWatcher() {
    setInterval(harvestPatientIds, 3000);
  }

  async function runMedrecordFill() {
    setDot('loading');
    setStatus('Собираю мед. запись...');
    try {
      const collected = await bg('MEDREC_COLLECT', {});

      const blocks = (collected.blocks || []).map((b) => ({
        id: b.id,
        name: b.name,
        text: AqMedrecLines.htmlBlockToText(b.html),
        empty: AqMedrecLines.isBlockEmpty(b.html)
      }));
      const history = (collected.history || [])
        .map((h) => ({ type: h.type, date: h.date, text: AqMedrecLines.htmlBlockToText(h.html) }))
        .filter((h) => h.text);

      const emptyCount = blocks.filter((b) => b.empty).length;
      dbg('Сбор мед. записи',
        blocks.length + ' блок(ов), пустых ' + emptyCount +
        ', записей истории ' + history.length +
        ', источник ' + collected.source + (collected.cached ? ' (из кэша)' : ''));

      // История уже собрана — заодно обновляем карточку пациента на локальном
      // сервере. Падение сохранения не должно мешать основному сценарию.
      await savePatientCard(collected.ids, history);

      if (!blocks.length) { showReply('Блоки мед. записи не найдены', true); setDot(''); setStatus('Готов'); return; }
      if (!emptyCount) { showReply('Все блоки уже заполнены'); setDot(''); setStatus('Готов'); return; }
      if (!history.length) { showReply('У пациента нет предыдущих мед. записей', true); setDot(''); setStatus('Готов'); return; }

      setStatus('Думаю...');
      const resp = await bg('MEDREC_PLAN', { blocks, history, url: location.href, provider: CFG.provider });
      setDot('');
      await startRun(resp);
    } catch (e) {
      setDot('error');
      showReply('Ошибка: ' + e.message, true);
      log('error', 'Мед. запись', e.message);
      setStatus('Ошибка');
    }
  }

  // Ручной сканер: ВСЕГДА через локальный сервер (/scan-dynamic). Для известных
  // страниц (doctor) сервер вернёт «умные» элементы (кнопка -> чья это кнопка),
  // для прочих — общий разбор. Локальный JS-скан страницы больше не используется.
  async function runLocalScan() {
    setDot('loading');
    setStatus('Сканирую через сервер...');
    try {
      const ctx = collectPageContext();
      const resp = await bg('SRV_SCAN', { html: ctx.html, values: ctx.values, url: location.href, iframe_html: ctx.iframeHtml });
      renderServerScan(resp);
      setDot('');
    } catch (e) {
      setDot('error');
      setStatus('Ошибка сканера: ' + e.message);
      log('error', 'Сканер', e.message);
    }
  }

  // Рендер серверного ответа /scan-dynamic (тот же формат, что у /scan):
  // elements[] = { description, selector, method, type_write, value, address }.
  function renderServerScan(resp) {
    const elements = (resp && resp.elements) || [];
    const writes = elements.filter((e) => e.method === 'write').length;
    const clicks = elements.filter((e) => e.method === 'click').length;
    $('#stat-fields').textContent = writes;
    $('#stat-btns').textContent = clicks;
    $('#stat-all').textContent = elements.length;
    el.domList.innerHTML = '';
    elements.slice(0, 200).forEach((it) => {
      const row = document.createElement('div');
      row.className = 'aq-dom-item type-' + (it.method === 'click' ? 'button' : 'input');
      row.innerHTML = `<span class="aq-dom-badge">${escapeHtml(it.method || '')}</span>
        <div class="aq-dom-info"><div class="aq-dom-name">${escapeHtml(it.description || '')}</div>
        ${it.value ? `<div class="aq-dom-value">${escapeHtml(it.value)}</div>` : ''}
        <div class="aq-dom-path">${escapeHtml(it.selector || '')}</div></div>`;
      row.addEventListener('click', () => {
        const n = resolveEl(it.selector);
        if (n) { n.scrollIntoView({ block: 'center', behavior: 'smooth' }); n.style.outline = '2px solid #4ade80'; setTimeout(() => n.style.outline = '', 1200); }
      });
      el.domList.appendChild(row);
    });
    const tag = resp && resp.scanner ? ' [' + resp.scanner + ']' : '';
    setStatus('Скан сервера' + tag + ': ' + elements.length + ' элементов');
    if (resp && resp.warning) log('warn', 'Сканер', resp.warning);
  }

  /* ════════════════════════════════════════════════════════════════════
   *  OCR
   * ════════════════════════════════════════════════════════════════════ */
  const OCR_STEPS = ['upload', 'recognize', 'template', 'done'];

  // Состояния шага: 'idle' (полый круг) | 'active' (крутится) | 'done' (галочка) | 'error'
  function setOcrStep(step, state) {
    if (!el.ocrSteps) return;
    const node = el.ocrSteps.querySelector('[data-step="' + step + '"]');
    if (node) node.setAttribute('data-state', state);
  }

  function resetOcrSteps() {
    if (!el.ocrSteps) return;
    OCR_STEPS.forEach((s) => setOcrStep(s, 'idle'));
  }

  // Помечает все шаги вплоть до (не включая) errorStep как выполненные,
  // а сам errorStep — как ошибочный.
  function failOcrStepsFrom(step) {
    const idx = OCR_STEPS.indexOf(step);
    if (idx === -1) return;
    OCR_STEPS.forEach((s, i) => {
      if (i < idx) setOcrStep(s, 'done');
      else if (i === idx) setOcrStep(s, 'error');
    });
  }

  async function handleOcrFile(e) {
    const file = e.target.files && e.target.files[0];
    if (!file) return;
    resetOcrSteps();
    if (el.ocrDropFile) el.ocrDropFile.textContent = file.name;
    el.ocrDrop.classList.add('aq-has-file');
    el.ocrResult.textContent = 'Распознаю документ...';
    setDot('loading');
    setOcrStep('upload', 'active');
    try {
      const b64 = await blobToB64(file);
      setOcrStep('upload', 'done');

      setOcrStep('recognize', 'active');
      const res = await bg('SRV_OCR', { fileB64: b64, name: file.name, mime: file.type, langs: 'kaz+rus+eng' });
      const text = (res && res.text || '').trim();
      el.ocrResult.textContent = text || '(пусто)';
      log('info', 'OCR', file.name + ' → ' + text.slice(0, 120));
      setOcrStep('recognize', 'done');

      // Отправляем в главный сервер с меткой [OCR]
      setOcrStep('template', 'active');
      setStatus('Подбираю шаблон...');
      const tpl = await bg('SRV_OCR_TEMPLATE', { text: '[OCR] ' + text, provider: CFG.provider });
      setOcrStep('template', 'done');

      setOcrStep('done', 'active');
      setDot('');
      showReply('Шаблон: ' + (tpl.id != null ? tpl.id : '—'));
      if (tpl.data) el.ocrResult.textContent += '\n\n[Шаблон #' + tpl.id + ']\n' + JSON.stringify(tpl.data, null, 2);
      setOcrStep('done', 'done');
    } catch (err) {
      setDot('error');
      // Определяем, на каком шаге произошла ошибка, по текущему состоянию
      const current = OCR_STEPS.find((s) => {
        const node = el.ocrSteps && el.ocrSteps.querySelector('[data-step="' + s + '"]');
        return node && node.getAttribute('data-state') === 'active';
      }) || 'upload';
      failOcrStepsFrom(current);
      el.ocrResult.textContent = 'Ошибка OCR: ' + err.message;
      log('error', 'OCR', err.message);
    } finally {
      e.target.value = '';
    }
  }

  /* ════════════════════════════════════════════════════════════════════
   *  LISTEN toggle
   * ════════════════════════════════════════════════════════════════════ */
  function setListen(on) {
    S.listening = on;
    root.setAttribute('data-listen', on ? 'on' : 'off');
    root.setAttribute('data-wake', on ? 'on' : '');
    el.listenLabel.textContent = on ? 'СЛУШАЮ' : 'СПИТ';
    el.wakeBadge.style.display = on ? 'flex' : 'none';
    el.listenOff.style.display = on ? 'none' : 'flex';
    if (on) { el.micDenied.style.display = 'none'; startRecognition(); setStatus('Слушаю wake-word'); }
    else { stopRecognition(); setStatus('Готов'); }
  }
  function toggleListen() { setListen(!S.listening); }

  /* ════════════════════════════════════════════════════════════════════
   *  ПРИМЕНЕНИЕ КОНФИГА К UI
   * ════════════════════════════════════════════════════════════════════ */
  function applyConfigToUI() {
    if (CFG.theme) root.setAttribute('data-theme', CFG.theme); else root.removeAttribute('data-theme');
  }

  /* ════════════════════════════════════════════════════════════════════
   *  ИНИЦИАЛИЗАЦИЯ
   * ════════════════════════════════════════════════════════════════════ */
  loadConfig().then(() => {
    applyConfigToUI();
    initBars();
    positionFloater(el.recHud);
    positionFloater(el.confirmCard);
    setListen(!!CFG.listenOnStart);
    installUrlWatcher();
    installPatientIdsWatcher();
    // Вкладка могла открыться посреди плана (в т.ч. как «новая вкладка» от
    // перехваченной кнопки) — очередь шагов лежит в storage и общая для всех
    // вкладок, поэтому режим «в текущей вкладке» восстанавливаем сразу.
    getPending().then((p) => {
      _sameTabPending = !!(p && p.steps && p.index < p.steps.length);
      _sameTabArmedAt = (p && p.armedAt) || Date.now();
      applySameTabMode();
    });
    resumeRun('init');
    installRecorder();
    getRecording().then((rec) => {
      S.recording = !!(rec && rec.active);
      applySameTabMode();
      updateRecUi(rec && rec.steps ? rec.steps.length : 0);
    });
    renderTemplateList();
    setStatus('Готов');
  });
})();
