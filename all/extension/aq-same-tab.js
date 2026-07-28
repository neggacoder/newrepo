/* Suerte / Aqbobek — «всё в текущей вкладке»: патч window.open в MAIN-мире.
 *
 * ЗАЧЕМ. На Damumed переход часто повешен не на <a href>, а на голый
 * <div onclick="...">, чей скрытый обработчик зовёт window.open(url, '_blank').
 * Открывается НОВАЯ вкладка — и это ломает обе половины расширения:
 *   • запись шаблона: адрес страницы (address у шага) продолжает писаться от
 *     старой вкладки, цепочка шагов рвётся;
 *   • воспроизведение: исполнитель остаётся в старой вкладке и ждёт перехода,
 *     которого в ней уже не будет.
 * Переписать target у <a> нельзя — тега <a> тут нет. Поэтому перехватываем сам
 * window.open и превращаем «новая вкладка» в «переход текущей вкладки» (_self).
 *
 * ПОЧЕМУ ОТДЕЛЬНЫЙ ФАЙЛ И world:"MAIN". content.js работает в ИЗОЛИРОВАННОМ
 * мире: его window.open — не тот, который зовёт страница. Патчить надо в MAIN
 * (см. тот же довод в trySetKendoValue в content.js). И обязательно на
 * document_start — иначе страница успеет схватить ссылку на нативный open.
 *
 * КОГДА ВКЛЮЧЁН. Только пока content.js держит на <html> атрибут
 * data-aq-same-tab="on" (идёт обучение или воспроизведение плана). Вне этих
 * режимов врач работает с сайтом как обычно: новые вкладки открываются штатно.
 * Атрибут — самый дешёвый канал ISOLATED → MAIN: DOM общий для обоих миров.
 */
(function () {
  'use strict';

  var ATTR = 'data-aq-same-tab';
  var EVT = 'aq-same-tab-open';

  if (window.__aqSameTabInstalled) return;   // повторная инъекция (all_frames + bfcache)
  window.__aqSameTabInstalled = true;

  var nativeOpen = window.open;

  // Читаем флаг ЛЕНИВО, на каждом вызове: document_start отрабатывает раньше,
  // чем content.js (document_idle) успевает выставить атрибут.
  function enabled() {
    try {
      var html = document.documentElement;
      return !!(html && html.getAttribute(ATTR) === 'on');
    } catch (_e) { return false; }
  }

  // Новую вкладку открывает всё, кроме явных «в это же окно» имён.
  // Пустое имя/undefined — тоже новая вкладка (это и есть дефолт window.open).
  function opensNewTab(name) {
    var n = String(name == null ? '' : name).trim().toLowerCase();
    return !(n === '_self' || n === '_top' || n === '_parent');
  }

  function absolute(url) {
    try { return new URL(String(url), document.baseURI).href; }
    catch (_e) { return String(url); }
  }

  // Сообщаем изолированному миру, что перехватили открытие: content.js по этому
  // событию помечает последний записанный шаг как навигационный (navigates).
  function notify(url) {
    try {
      var html = document.documentElement;
      if (html) html.dispatchEvent(new CustomEvent(EVT, { bubbles: true, detail: String(url || '') }));
    } catch (_e) { /* не критично — это только подсказка рекордеру */ }
  }

  function go(url) {
    if (!url) return;
    var href = absolute(url);
    if (href === 'about:blank') return;
    notify(href);
    try { window.location.assign(href); } catch (_e) { window.location.href = href; }
  }

  /* Заглушка вместо объекта новой вкладки.
     Возвращать null нельзя: страница часто делает w.focus() или, что важнее,
     открывает пустое окно и ТОЛЬКО ПОТОМ присваивает ему адрес:
        var w = window.open(); ... w.location = url;
     Поэтому у заглушки живой сеттер location — он и уводит текущую вкладку. */
  function makeStub() {
    function noop() {}

    var loc = {
      assign: go,
      replace: function (u) { if (u) { notify(absolute(u)); try { window.location.replace(absolute(u)); } catch (_e) { go(u); } } },
      reload: noop,
      toString: function () { return window.location.href; }
    };
    Object.defineProperty(loc, 'href', {
      get: function () { return window.location.href; },
      set: function (v) { go(v); }
    });

    var stub = {
      closed: false,
      opener: window,
      name: '',
      focus: noop, blur: noop, print: noop, postMessage: noop,
      close: function () { stub.closed = true; },
      // Некоторые страницы пишут в document новой вкладки — молча проглатываем,
      // иначе TypeError уронит их обработчик целиком.
      document: { write: noop, writeln: noop, open: noop, close: noop, body: null }
    };
    Object.defineProperty(stub, 'location', {
      get: function () { return loc; },
      set: function (v) { go(v && v.href != null ? v.href : v); }
    });
    return stub;
  }

  window.open = function (url, name, features) {
    if (!enabled() || !opensNewTab(name)) return nativeOpen.apply(window, arguments);
    if (url) go(url);
    return makeStub();   // адрес могут присвоить позже — заглушка это переживёт
  };
  // Чтобы страница, проверяющая window.open.toString(), не заподозрила подмену.
  try { window.open.toString = function () { return 'function open() { [native code] }'; }; } catch (_e) {}

  /* Вторая половина проблемы: обычные <a target="_blank"> и <form target="_blank">.
     window.open их не касается — тут вкладку открывает сам браузер.

     Для ссылок НЕ трогаем разметку: отменяем действие по умолчанию и уходим
     сами. Слушаем на всплытии (bubble) и уважаем defaultPrevented — так все
     обработчики страницы успевают отработать до нас, и мы не уводим вкладку
     из-под кнопки, которая на самом деле делает что-то своё. Модификаторы
     (ctrl/shift/middle-click) пропускаем: это осознанное «открой в новой
     вкладке» от врача. */
  document.addEventListener('click', function (e) {
    if (!enabled() || e.defaultPrevented) return;
    if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
    var a = null;
    try { a = e.target && e.target.closest ? e.target.closest('a[target], area[target]') : null; }
    catch (_e) { a = null; }
    if (!a || !opensNewTab(a.getAttribute('target'))) return;
    var href = a.getAttribute('href');
    if (!href || /^\s*javascript:/i.test(href) || href.charAt(0) === '#') return;
    e.preventDefault();
    go(href);
  }, false);

  /* Для формы этот приём не годится (повторно отправить её из перехватчика
     нельзя), поэтому подменяем target и возвращаем на следующем такте.
     Порядок гарантирован спецификацией: алгоритм отправки формы выполняется
     в той же задаче сразу после рассылки события, а setTimeout — уже
     отдельная задача, то есть подмена точно доживёт до чтения target. */
  document.addEventListener('submit', function (e) {
    if (!enabled() || e.defaultPrevented) return;
    var form = e.target;
    if (!form || !form.getAttribute) return;
    var t = form.getAttribute('target');
    if (!t || !opensNewTab(t)) return;
    form.setAttribute('target', '_self');
    notify(form.getAttribute('action') || '');
    setTimeout(function () {
      try { form.setAttribute('target', t); } catch (_e) {}
    }, 0);
  }, false);
})();
