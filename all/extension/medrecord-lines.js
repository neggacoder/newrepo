/* Suerte / Aqbobek — развёртка HTML блока мед. записи в обычный текст.
 *
 * Живёт отдельным файлом по двум причинам:
 *   1. background.js — service worker, в нём нет DOMParser, поэтому разбор
 *      делает content.js (у него есть DOM, но парсер здесь не нужен вовсе);
 *   2. чистые функции без DOM тестируются node --test без браузера.
 *
 * Обратная операция (текст -> построчный <div>-HTML) уже есть в content.js
 * как buildEditorLinesHtml — дублировать её здесь не нужно.
 *
 * Развёртка ПРИБЛИЗИТЕЛЬНАЯ: точность до количества подряд идущих пустых
 * строк. Этого достаточно и для промпта ИИ, и для проверки «пуст ли блок».
 */
var AqMedrecLines = (function () {
  'use strict';

  var ENTITIES = {
    nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", laquo: '«', raquo: '»', mdash: '—', ndash: '–'
  };

  function decodeEntities(s) {
    return s
      .replace(/&#(\d+);/g, function (_m, code) { return String.fromCodePoint(Number(code)); })
      .replace(/&#x([0-9a-f]+);/gi, function (_m, code) { return String.fromCodePoint(parseInt(code, 16)); })
      .replace(/&([a-z]+);/gi, function (m, name) {
        var key = name.toLowerCase();
        return Object.prototype.hasOwnProperty.call(ENTITIES, key) ? ENTITIES[key] : m;
      });
  }

  // Убираем <script>/<style> ВМЕСТЕ с содержимым: страница подмешивает в блок
  // служебный <style id="omgcss">, и без этого блок выглядел бы непустым.
  function stripInvisible(s) {
    return s.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '');
  }

  function htmlBlockToText(html) {
    if (html == null) return '';
    var s = stripInvisible(String(html));
    s = s.replace(/<br\s*\/?>/gi, '\n');
    // Перенос даёт ОТКРЫВАЮЩИЙ блочный тег. Если бы переносы давали и закрывающие,
    // «<div>А</div><div>Б</div>» получило бы лишнюю пустую строку между А и Б.
    s = s.replace(/<(div|p|li|tr|h[1-6])\b[^>]*>/gi, '\n');
    s = s.replace(/<[^>]*>/g, '');
    s = decodeEntities(s);
    s = s.replace(/\r\n?/g, '\n');
    s = s.split('\n').map(function (line) {
      return line.replace(/[ \t ]+/g, ' ').trim();
    }).join('\n');
    s = s.replace(/\n{3,}/g, '\n\n');
    return s.trim();
  }

  // Ровно тот же критерий, которым сама страница проверяет заполненность блока
  // (см. file1.html:1690 — /[а-яА-Яa-zA-Z0-9]/ по тексту без тегов).
  function isBlockEmpty(html) {
    if (html == null) return true;
    var text = stripInvisible(String(html)).replace(/<[^>]*>/g, '');
    return !/[а-яА-ЯёЁa-zA-Z0-9]/.test(decodeEntities(text));
  }

  return { htmlBlockToText: htmlBlockToText, isBlockEmpty: isBlockEmpty };
})();

/* Экспорт для node --test. В браузере module не определён — ветка не выполняется. */
if (typeof module !== 'undefined' && module.exports) module.exports = AqMedrecLines;
