/* Suerte — админ-панель (клиент). Токен в sessionStorage, Bearer-заголовок. */
'use strict';
const $ = (s) => document.querySelector(s);
const API = '/admin';
let TOKEN = sessionStorage.getItem('aq_admin_token') || '';
let curPath = '';       // текущая папка в файловом браузере
let curFile = '';       // открытый файл

function show(screen) {
  ['loading', 'setup', 'login', 'dash'].forEach((s) => $('#screen-' + s).classList.toggle('hidden', s !== screen));
}
async function api(path, opts) {
  opts = opts || {};
  opts.headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
  if (TOKEN) opts.headers['Authorization'] = 'Bearer ' + TOKEN;
  const res = await fetch(API + path, opts);
  const txt = await res.text();
  let data; try { data = JSON.parse(txt); } catch { data = { raw: txt }; }
  if (res.status === 401) { TOKEN = ''; sessionStorage.removeItem('aq_admin_token'); show('login'); throw new Error(data.detail || 'Не авторизован'); }
  if (!res.ok) throw new Error(data.detail || ('HTTP ' + res.status));
  return data;
}

/* ── Инициализация ── */
(async function init() {
  try {
    const st = await api('/state');
    if (!st.configured) return show('setup');
    if (TOKEN) { try { await api('/status'); openDash(); return; } catch (_e) {} }
    show('login');
  } catch (e) { show('login'); }
})();

/* ── Setup ── */
$('#setup-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const p = $('#setup-pass').value, p2 = $('#setup-pass2').value, pin = $('#setup-pin').value;
  const err = $('#setup-err'); err.textContent = '';
  if (p.length < 8) return err.textContent = 'Пароль минимум 8 символов';
  if (p !== p2) return err.textContent = 'Пароли не совпадают';
  if (!/^\d{4,8}$/.test(pin)) return err.textContent = 'PIN — 4–8 цифр';
  try {
    await api('/setup', { method: 'POST', body: JSON.stringify({ password: p, pin }) });
    show('login');
  } catch (ex) { err.textContent = ex.message; }
});

/* ── Login ── */
$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const err = $('#login-err'); err.textContent = '';
  $('#login-btn').disabled = true;
  try {
    const r = await api('/login', { method: 'POST', body: JSON.stringify({ password: $('#login-pass').value, pin: $('#login-pin').value }) });
    TOKEN = r.token; sessionStorage.setItem('aq_admin_token', TOKEN);
    $('#login-pass').value = ''; $('#login-pin').value = '';
    openDash();
  } catch (ex) { err.textContent = ex.message; }
  finally { $('#login-btn').disabled = false; }
});

/* ── Dashboard ── */
function openDash() {
  show('dash');
  refreshStatus();
  loadLogs();
  loadFiles('');
  loadUsage();
  loadAiSettings();
}
$('#btn-logout').addEventListener('click', () => { TOKEN = ''; sessionStorage.removeItem('aq_admin_token'); show('login'); });

document.querySelectorAll('.tab').forEach((t) => t.addEventListener('click', () => {
  document.querySelectorAll('.tab').forEach((x) => x.classList.remove('active'));
  document.querySelectorAll('.sec').forEach((x) => x.classList.remove('active'));
  t.classList.add('active');
  document.querySelector(`.sec[data-sec="${t.dataset.sec}"]`).classList.add('active');
  // График считался по нулевой ширине скрытой секции — пересчитаем по реальной
  if (t.dataset.sec === 'usage' && LAST_BY_DAY.length) renderChart(LAST_BY_DAY);
}));

/* ── Служба ── */
async function refreshStatus() {
  try {
    const s = await api('/status');
    $('#svc-active').textContent = s.active;
    const badge = $('#svc-badge');
    badge.textContent = s.active;
    badge.className = 'badge ' + (s.active === 'active' ? 'active' : 'dead');
  } catch (e) { $('#svc-active').textContent = e.message; }
}
$('#btn-refresh-status').addEventListener('click', refreshStatus);
document.querySelectorAll('[data-svc]').forEach((b) => b.addEventListener('click', async () => {
  const action = b.dataset.svc;
  if (action === 'stop' && !confirm('Остановить сервер? Помощник перестанет работать у всех врачей.')) return;
  $('#svc-note').textContent = '...';
  try {
    const r = await api('/service', { method: 'POST', body: JSON.stringify({ action }) });
    $('#svc-note').textContent = r.note || ('Готово: ' + action);
    setTimeout(refreshStatus, 1500);
  } catch (e) { $('#svc-note').textContent = 'Ошибка: ' + e.message; }
}));

/* ── Логи ── */
async function loadLogs() {
  const lines = +$('#log-lines').value || 200;
  $('#log-out').textContent = 'Загрузка...';
  try { const r = await api('/logs?lines=' + lines); $('#log-out').textContent = r.text || '(пусто)'; }
  catch (e) { $('#log-out').textContent = 'Ошибка: ' + e.message; }
}
$('#btn-refresh-logs').addEventListener('click', loadLogs);

/* ── Токены ─────────────────────────────────────────────────────────────
   Состояние вкладки в одном месте: период (days=0 — всё время), метрика
   графика, страница и фильтры журнала вызовов. */
const USAGE = { days: 7, metric: 'cost_usd', page: 0, perPage: 50, provider: '', q: '', model: '' };
let LAST_BY_DAY = [];

const fmtN = (n) => Number(n || 0).toLocaleString('ru-RU');
const fmtUsd = (n) => '$' + Number(n || 0).toFixed(4);
const usageSec = () => document.querySelector('.sec[data-sec="usage"]');

function isoDay(d) {
  const p = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
// Границы периода для журнала: те же, что у summary. Всё время — без границ.
function periodRange() {
  if (!USAGE.days) return null;
  const to = new Date();
  const from = new Date(to.getTime() - (USAGE.days - 1) * 86400000);
  return { from: isoDay(from), to: isoDay(to) };
}

async function loadUsage() {
  const sec = usageSec();
  sec.classList.add('stale');          // держим прошлый рендер приглушённым, без мигания скелетоном
  try {
    const r = await api('/usage/summary?days=' + USAGE.days);
    renderKpi(r);
    renderBudget(r.budget);
    renderDays(r.by_day);
    renderChart(r.by_day);
    renderModels(r.by_model);

    const db = r.db || {};
    $('#usage-db-note').textContent = db.exists
      ? `База: ${db.path} · ${fmtSize(db.size)} · ${fmtN(db.rows)} записей · обновлена ${db.modified}`
      : 'База usage.db ещё не создана — вызовов LLM не было.';
    await loadCalls(0);
  } catch (e) {
    $('#usage-stats').innerHTML = '';
    $('#usage-db-note').textContent = 'Ошибка: ' + e.message;
  } finally {
    sec.classList.remove('stale');
  }
}

function renderKpi(r) {
  const p = r.period || {}, t = r.totals || {};
  $('#usage-stats').innerHTML = `
    <div class="stat"><span class="stat-n">${fmtN(p.calls)}</span><span class="stat-l">вызовов</span></div>
    <div class="stat"><span class="stat-n">${fmtN(p.total_tokens)}</span><span class="stat-l">токенов</span></div>
    <div class="stat"><span class="stat-n">${fmtN(p.prompt_tokens)}</span><span class="stat-l">prompt</span></div>
    <div class="stat"><span class="stat-n">${fmtN(p.completion_tokens)}</span><span class="stat-l">completion</span></div>
    <div class="stat"><span class="stat-n">${fmtUsd(p.cost_usd)}</span><span class="stat-l">стоимость</span></div>`;
  $('#usage-total-note').textContent =
    `За всё время: ${fmtN(t.calls)} вызовов · ${fmtN(t.total_tokens)} токенов · ${fmtUsd(t.cost_usd)}`;
}

function renderBudget(b) {
  b = b || {};
  const bar = $('#budget-bar');
  if (!b.limit_usd) {
    $('#budget-figures').textContent =
      `Потрачено за месяц ${fmtUsd(b.spent_usd)} · лимит не задан`;
    bar.style.width = '0%';
    bar.className = 'budget-bar';
    $('#budget-input').value = '';
    return;
  }
  const pct = b.pct || 0;
  $('#budget-figures').textContent =
    `Потрачено ${fmtUsd(b.spent_usd)} из ${fmtUsd(b.limit_usd)} · ${pct.toFixed(1)}%`;
  bar.style.width = Math.max(0, Math.min(100, pct)) + '%';
  bar.className = 'budget-bar' + (pct >= 100 ? ' over' : pct >= 80 ? ' warn' : '');
  $('#budget-input').value = b.limit_usd;
}

/* Таблица-двойник графика: те же значения, но доступные без наведения. */
function renderDays(byDay) {
  LAST_BY_DAY = byDay || [];
  const tb = $('#chart-table tbody');
  tb.innerHTML = '';
  if (!LAST_BY_DAY.length) {
    tb.innerHTML = '<tr><td colspan="4" class="muted">Вызовов за период не было.</td></tr>';
    return;
  }
  LAST_BY_DAY.forEach((d) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="mono">${esc(d.day)}</td><td class="num">${fmtN(d.calls)}</td>` +
      `<td class="num">${fmtN(d.total_tokens)}</td><td class="num">${fmtUsd(d.cost_usd)}</td>`;
    tb.appendChild(tr);
  });
}

/* ── График расхода по дням ──────────────────────────────────────────────
   Спеки марок — из skill dataviz: столбец ≤24px, верх скруглён на 4px,
   основание прямое; 2px зазора поверхности между соседями; сетка — сплошная
   волосяная линия; подписан только максимум; наведение продублировано
   таблицей-двойником и доступно с клавиатуры. */
const CHART_MAX_BARS = 92;   // дальше — схлопываем в недели, иначе цель наведения меньше 24px

function niceTicks(max, count) {
  if (!(max > 0)) return [0, 1];
  const raw = max / count;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const norm = raw / mag;
  // Пороги — геометрические середины лестницы 1/2/5/10 (√2, √10, √50): иначе
  // norm=2.2 округляется вверх до 5 и на оси остаётся всего два деления.
  const step = (norm < 1.4142 ? 1 : norm < 3.1623 ? 2 : norm < 7.0711 ? 5 : 10) * mag;
  // Умножаем на индекс, а не накапливаем сложением, и подрезаем двоичный мусор:
  // иначе 3 * 0.2 даёт 0.6000000000000001 и это уезжает в подпись оси.
  const at = (i) => Number((i * step).toPrecision(12));
  const out = [];
  for (let i = 0; at(i) <= max + step / 2; i++) out.push(at(i));
  if (out[out.length - 1] < max) out.push(at(out.length));
  return out;
}

// Верх скруглён, основание прямое: столбец растёт от единой базовой линии.
function barPath(x, yTop, w, h, r) {
  r = Math.min(r, w / 2, h);
  return `M${x},${yTop + h} L${x},${yTop + r} Q${x},${yTop} ${x + r},${yTop} ` +
         `L${x + w - r},${yTop} Q${x + w},${yTop} ${x + w},${yTop + r} L${x + w},${yTop + h} Z`;
}

function bucketWeeks(days) {
  const out = [];
  for (let i = 0; i < days.length; i += 7) {
    const chunk = days.slice(i, i + 7);
    out.push({
      day: chunk[0].day,
      week: true,
      calls: chunk.reduce((s, d) => s + d.calls, 0),
      total_tokens: chunk.reduce((s, d) => s + d.total_tokens, 0),
      cost_usd: chunk.reduce((s, d) => s + d.cost_usd, 0)
    });
  }
  return out;
}

const ddmm = (iso) => iso.slice(8) + '.' + iso.slice(5, 7);

function renderChart(byDay) {
  const box = $('#usage-chart');
  const caption = $('#chart-caption');
  box.innerHTML = '';
  const raw = byDay || [];
  if (!raw.length) { caption.textContent = ''; box.innerHTML = '<p class="muted">Вызовов за период не было.</p>'; return; }

  const weekly = raw.length > CHART_MAX_BARS;
  const data = weekly ? bucketWeeks(raw) : raw;
  caption.textContent = weekly
    ? `Период длиннее ${CHART_MAX_BARS} дней — столбцы сгруппированы по неделям. Точные дневные значения — в таблице ниже.`
    : '';

  const metric = USAGE.metric;
  const W = Math.max(320, box.clientWidth || 900), H = 236;
  const PAD = { t: 18, r: 12, b: 30, l: 62 };          // низ включает полосу подписей оси X
  const plotW = W - PAD.l - PAD.r, plotH = H - PAD.t - PAD.b;

  const max = data.reduce((m, d) => Math.max(m, d[metric] || 0), 0);
  const ticks = niceTicks(max, 4);
  const top = ticks[ticks.length - 1] || 1;
  const band = plotW / data.length;
  const barW = Math.max(1, Math.min(24, band - 2));    // 2px зазора поверхности между соседями
  const yOf = (v) => PAD.t + plotH - (v / top) * plotH;
  const peak = data.reduce((bi, d, i) => ((d[metric] || 0) > (data[bi][metric] || 0) ? i : bi), 0);
  const fmtV = (v) => metric === 'cost_usd' ? '$' + v.toFixed(v < 10 ? 2 : 0) : fmtN(v);

  const parts = [`<svg class="chart-svg" viewBox="0 0 ${W} ${H}" width="100%" height="${H}" role="img" aria-label="Расход по дням">`];

  ticks.forEach((v) => {
    const y = yOf(v);
    parts.push(`<line class="grid" x1="${PAD.l}" y1="${y}" x2="${W - PAD.r}" y2="${y}"/>`);
    parts.push(`<text class="ax" x="${PAD.l - 10}" y="${y + 4}" text-anchor="end">${fmtV(v)}</text>`);
  });

  const every = Math.ceil(data.length / 10);
  data.forEach((d, i) => {
    const v = d[metric] || 0;
    const cx = PAD.l + i * band + band / 2;
    if (v > 0) {
      const h = Math.max(2, plotH - (yOf(v) - PAD.t));
      parts.push(`<path class="bar" d="${barPath(cx - barW / 2, PAD.t + plotH - h, barW, h, 4)}"/>`);
    }
    if (i % every === 0 || i === data.length - 1) {
      parts.push(`<text class="ax" x="${cx}" y="${H - 10}" text-anchor="middle">${ddmm(d.day)}</text>`);
    }
    if (i === peak && v > 0) {
      parts.push(`<text class="peak" x="${cx}" y="${yOf(v) - 7}" text-anchor="middle">${fmtV(v)}</text>`);
    }
    // Зона наведения шире столбца — мышью и с клавиатуры в неё попадают без прицеливания
    parts.push(`<rect class="hit" x="${PAD.l + i * band}" y="${PAD.t}" width="${band}" height="${plotH}" ` +
               `tabindex="0" data-i="${i}" role="button" aria-label="${esc(d.day)}: ${esc(fmtV(v))}"/>`);
  });
  parts.push('</svg>');
  box.innerHTML = parts.join('') + '<div class="chart-tip" hidden></div>';

  const tip = box.querySelector('.chart-tip');
  box.querySelectorAll('.hit').forEach((rect) => {
    const show = () => {
      const d = data[+rect.dataset.i];
      tip.hidden = false;
      tip.innerHTML = `<b>${esc(d.week ? 'неделя с ' + ddmm(d.day) : d.day)}</b><br>` +
        `${fmtN(d.calls)} вызовов<br>${fmtN(d.total_tokens)} токенов<br>${fmtUsd(d.cost_usd)}`;
      const rb = rect.getBoundingClientRect(), bb = box.getBoundingClientRect();
      const left = rb.left - bb.left + rb.width / 2 - tip.offsetWidth / 2;
      tip.style.left = Math.max(0, Math.min(bb.width - tip.offsetWidth, left)) + 'px';
    };
    const hide = () => { tip.hidden = true; };
    rect.addEventListener('mouseenter', show);
    rect.addEventListener('focus', show);
    rect.addEventListener('mouseleave', hide);
    rect.addEventListener('blur', hide);
  });
}

function renderModels(rows) {
  const tb = $('#model-table tbody');
  tb.innerHTML = '';
  if (!rows || !rows.length) {
    tb.innerHTML = '<tr><td colspan="8" class="muted">Нет данных за период.</td></tr>';
    return;
  }
  rows.forEach((r) => {
    const share = (r.share * 100).toFixed(1);
    const tr = document.createElement('tr');
    tr.className = 'clickable';
    tr.innerHTML =
      `<td>${esc(r.provider)}</td>` +
      `<td>${esc(r.model)}${r.priced ? '' : ' <span class="tag-warn" title="Цена этой модели не задана в config.json — стоимость не посчитана">без цены</span>'}</td>` +
      `<td class="num">${fmtN(r.calls)}</td>` +
      `<td class="num">${fmtN(r.prompt_tokens)}</td>` +
      `<td class="num">${fmtN(r.completion_tokens)}</td>` +
      `<td class="num">${fmtN(r.total_tokens)}</td>` +
      `<td class="num">${fmtUsd(r.cost_usd)}</td>` +
      `<td class="share-cell"><span class="share"><span class="share-bar" style="width:${share}%"></span></span><small>${share}%</small></td>`;
    tr.addEventListener('click', () => {
      USAGE.model = r.model;
      USAGE.provider = r.provider;
      $('#calls-provider').value = r.provider;
      renderFilterChip();
      loadCalls(0);
    });
    tb.appendChild(tr);
  });
}

function renderFilterChip() {
  const box = $('#calls-filter-chip');
  box.innerHTML = USAGE.model
    ? `<span class="chip">модель: ${esc(USAGE.model)}<button type="button" title="Снять фильтр">✕</button></span>`
    : '';
  const btn = box.querySelector('button');
  if (btn) btn.addEventListener('click', () => { USAGE.model = ''; renderFilterChip(); loadCalls(0); });
}

function callsQuery(limit, offset) {
  const p = new URLSearchParams();
  if (limit) p.set('limit', limit);
  if (offset) p.set('offset', offset);
  if (USAGE.provider) p.set('provider', USAGE.provider);
  if (USAGE.model) p.set('model', USAGE.model);
  if (USAGE.q) p.set('q', USAGE.q);
  const r = periodRange();
  if (r) { p.set('from', r.from); p.set('to', r.to); }
  return p.toString();
}

async function loadCalls(page) {
  USAGE.page = Math.max(0, page);
  const tb = $('#calls-table tbody');
  try {
    const r = await api('/usage/calls?' + callsQuery(USAGE.perPage, USAGE.page * USAGE.perPage));
    tb.innerHTML = '';
    if (!r.rows.length) {
      tb.innerHTML = '<tr><td colspan="8" class="muted">Нет вызовов по этим условиям.</td></tr>';
    }
    r.rows.forEach((c) => {
      const tr = document.createElement('tr');
      tr.innerHTML =
        `<td class="mono">${esc(c.ts)}</td><td>${esc(c.provider)}</td><td>${esc(c.model)}</td>` +
        `<td>${esc(c.endpoint || '—')}</td><td class="num">${fmtN(c.prompt_tokens)}</td>` +
        `<td class="num">${fmtN(c.completion_tokens)}</td><td class="num">${fmtN(c.total_tokens)}</td>` +
        `<td class="num">${c.priced ? fmtUsd(c.cost_usd) : '—'}</td>`;
      tb.appendChild(tr);
    });
    const first = r.total ? USAGE.page * USAGE.perPage + 1 : 0;
    const last = Math.min(r.total, (USAGE.page + 1) * USAGE.perPage);
    $('#calls-range').textContent = `${first}–${last} из ${fmtN(r.total)}`;
    $('#calls-prev').disabled = USAGE.page === 0;
    $('#calls-next').disabled = last >= r.total;
  } catch (e) {
    tb.innerHTML = `<tr><td colspan="8" class="muted">Ошибка: ${esc(e.message)}</td></tr>`;
  }
}

/* CSV лежит за Bearer-заголовком, поэтому обычной ссылкой его не скачать. */
async function downloadCsv() {
  const note = $('#calls-note');
  note.textContent = 'Готовлю файл...';
  try {
    const res = await fetch(API + '/usage/calls.csv?' + callsQuery(0, 0),
      { headers: { Authorization: 'Bearer ' + TOKEN } });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const url = URL.createObjectURL(await res.blob());
    const a = document.createElement('a');
    a.href = url; a.download = 'token_usage.csv';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    note.textContent = 'Файл выгружен';
  } catch (e) { note.textContent = 'Не удалось выгрузить CSV: ' + e.message; }
}

async function saveBudget(e) {
  e.preventDefault();
  const note = $('#budget-note');
  note.textContent = 'Сохранение...';
  try {
    await api('/usage/budget', {
      method: 'POST',
      body: JSON.stringify({ monthly_budget_usd: +$('#budget-input').value || 0 })
    });
    note.textContent = 'Сохранено';
    loadUsage();
  } catch (ex) { note.textContent = 'Ошибка: ' + ex.message; }
}

$('#btn-refresh-usage').addEventListener('click', loadUsage);
$('#budget-form').addEventListener('submit', saveBudget);
$('#btn-usage-csv').addEventListener('click', downloadCsv);
$('#calls-prev').addEventListener('click', () => loadCalls(USAGE.page - 1));
$('#calls-next').addEventListener('click', () => loadCalls(USAGE.page + 1));
$('#calls-provider').addEventListener('change', (e) => { USAGE.provider = e.target.value; loadCalls(0); });

let callsQTimer = null;
$('#calls-q').addEventListener('input', (e) => {
  clearTimeout(callsQTimer);
  const v = e.target.value.trim();
  callsQTimer = setTimeout(() => { USAGE.q = v; loadCalls(0); }, 250);
});

document.querySelectorAll('#usage-period .seg-btn').forEach((b) => b.addEventListener('click', () => {
  document.querySelectorAll('#usage-period .seg-btn').forEach((x) => x.classList.remove('active'));
  b.classList.add('active');
  USAGE.days = +b.dataset.days;
  loadUsage();
}));

document.querySelectorAll('#chart-metric .seg-btn').forEach((b) => b.addEventListener('click', () => {
  document.querySelectorAll('#chart-metric .seg-btn').forEach((x) => x.classList.remove('active'));
  b.classList.add('active');
  USAGE.metric = b.dataset.metric;
  renderChart(LAST_BY_DAY);      // данные уже есть — сервер дёргать незачем
}));

// Ширина столбцов зависит от ширины карточки: перерисовываем при ресайзе окна
let chartResizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(chartResizeTimer);
  chartResizeTimer = setTimeout(() => { if (LAST_BY_DAY.length) renderChart(LAST_BY_DAY); }, 150);
});

/* ── Файлы ── */
const IC_DIR = '<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>';
const IC_FILE = '<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';

async function loadFiles(path) {
  try {
    const r = await api('/files?path=' + encodeURIComponent(path));
    curPath = r.path;
    $('#file-path').textContent = '/' + (r.path || '');
    const list = $('#file-list'); list.innerHTML = '';
    if (r.path) {
      const up = document.createElement('div');
      up.className = 'file-item dir'; up.innerHTML = IC_DIR + '<span>..</span>';
      up.addEventListener('click', () => loadFiles(parentPath(r.path)));
      list.appendChild(up);
    }
    r.items.forEach((it) => {
      const row = document.createElement('div');
      row.className = 'file-item' + (it.dir ? ' dir' : '');
      row.innerHTML = (it.dir ? IC_DIR : IC_FILE) + `<span>${esc(it.name)}</span>` +
        (it.dir ? '' : (it.writable ? `<span class="sz">${fmtSize(it.size)}</span>` : `<span class="ro">только чтение</span>`));
      row.addEventListener('click', () => {
        const full = (r.path ? r.path + '/' : '') + it.name;
        if (it.dir) loadFiles(full); else openFile(full);
      });
      list.appendChild(row);
    });
  } catch (e) { $('#file-list').innerHTML = '<div class="muted">' + esc(e.message) + '</div>'; }
}
function parentPath(p) { const i = p.lastIndexOf('/'); return i >= 0 ? p.slice(0, i) : ''; }

async function openFile(path) {
  try {
    const r = await api('/file?path=' + encodeURIComponent(path));
    curFile = r.path;
    $('#edit-name').textContent = '/' + r.path;
    $('#edit-area').value = r.content;
    $('#edit-area').readOnly = !r.writable;
    $('#btn-save').disabled = !r.writable;
    $('#edit-note').textContent = r.writable ? 'Редактируемый файл' : 'Только для чтения';
  } catch (e) { $('#edit-note').textContent = 'Ошибка: ' + e.message; }
}
$('#btn-save').addEventListener('click', async () => {
  if (!curFile) return;
  $('#edit-note').textContent = 'Сохранение...';
  try {
    await api('/file', { method: 'POST', body: JSON.stringify({ path: curFile, content: $('#edit-area').value }) });
    $('#edit-note').textContent = 'Сохранено';
    loadFiles(curPath);
  } catch (e) { $('#edit-note').textContent = 'Ошибка: ' + e.message; }
});

/* ── Смена пароля ── */
$('#chpw-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const err = $('#chpw-err'); err.textContent = '';
  try {
    await api('/change-password', { method: 'POST', body: JSON.stringify({
      old_password: $('#chpw-old').value, new_password: $('#chpw-new').value, new_pin: $('#chpw-pin').value || undefined
    }) });
    err.style.color = 'var(--ok)'; err.textContent = 'Сохранено';
    e.target.reset();
  } catch (ex) { err.style.color = 'var(--red)'; err.textContent = ex.message; }
});

/* ── Модели ИИ ── */
async function loadAiSettings() {
  const err = $('#ai-err'); const note = $('#ai-note');
  err.textContent = ''; note.textContent = '';
  try {
    const r = await api('/ai-settings');
    $('#ai-provider').value = r.provider || 'qwen';
    $('#ai-ollama-url').value = r.ollama_url || '';
    $('#ai-ollama-model').value = r.ollama_model || '';
    $('#ai-openai-model').value = r.openai_model || '';
    $('#ai-deepseek-model').value = r.deepseek_model || '';
    $('#ai-timeout').value = r.request_timeout || 120;
    $('#ai-openai-key').value = '';
    $('#ai-deepseek-key').value = '';
    $('#ai-openai-key-note').textContent = r.openai_api_key_set ? `сохранён: ${r.openai_api_key_masked}` : 'не задан';
    $('#ai-deepseek-key-note').textContent = r.deepseek_api_key_set ? `сохранён: ${r.deepseek_api_key_masked}` : 'не задан';
  } catch (e) { err.textContent = 'Не удалось загрузить: ' + e.message; }
}
$('#btn-refresh-ai').addEventListener('click', loadAiSettings);

$('#ai-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const err = $('#ai-err'); const note = $('#ai-note');
  err.textContent = ''; note.textContent = 'Сохранение...';
  const body = {
    provider: $('#ai-provider').value,
    ollama_url: $('#ai-ollama-url').value,
    ollama_model: $('#ai-ollama-model').value,
    openai_model: $('#ai-openai-model').value,
    deepseek_model: $('#ai-deepseek-model').value,
    request_timeout: $('#ai-timeout').value
  };
  const okKey = $('#ai-openai-key').value.trim();
  const dsKey = $('#ai-deepseek-key').value.trim();
  if (okKey) body.openai_api_key = okKey;
  if (dsKey) body.deepseek_api_key = dsKey;
  try {
    const r = await api('/ai-settings', { method: 'POST', body: JSON.stringify(body) });
    note.textContent = 'Сохранено: ' + (r.updated || []).join(', ');
    loadAiSettings();
  } catch (ex) { note.textContent = ''; err.textContent = ex.message; }
});

/* ── utils ── */
function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function fmtSize(n) { if (n == null) return ''; if (n < 1024) return n + 'B'; if (n < 1048576) return (n / 1024).toFixed(1) + 'K'; return (n / 1048576).toFixed(1) + 'M'; }
