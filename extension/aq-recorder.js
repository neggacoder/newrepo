/* Suerte / Aqbobek — чистая логика режима «Обучение» (рекордер действий).
 *
 * Без DOM/window/chrome: узел и cssPath приходят параметрами, чтобы модуль
 * юнит-тестировался в Node. content.js навешивает слушатели и передаёт сюда
 * найденные узлы; здесь — только «что это за узел» и «как из него собрать шаг».
 * Формат шага — ровно исполнительский (runStep в content.js) и совпадает с
 * server/templates/20.json (example_output.steps).
 */
var AqRecorder = (function () {
  'use strict';

  // Типы <input>, которые считаем текстовым вводом (их пишем как write).
  var TEXT_INPUT_TYPES = {
    text: 1, search: 1, tel: 1, url: 1, email: 1, password: 1, number: 1,
    date: 1, 'datetime-local': 1, month: 1, week: 1, time: 1, color: 1, range: 1
  };
  // Кнопочные типы <input> — это клик, а не ввод.
  var BUTTON_INPUT_TYPES = { button: 1, submit: 1, reset: 1, checkbox: 1, radio: 1, image: 1 };

  function tag(node) { return node && node.tagName ? node.tagName.toLowerCase() : ''; }
  function inputType(node) { return (node.getAttribute('type') || 'text').toLowerCase(); }

  function isTextEntry(node) {
    if (!node || node.nodeType !== 1) return false;
    var t = tag(node);
    if (t === 'textarea' || t === 'select') return true;
    if (t === 'input') return !!TEXT_INPUT_TYPES[inputType(node)];
    if (node.isContentEditable) return true;
    return false;
  }

  // hints.pointer — у узла вычисленный cursor:pointer. Damumed часто вешает
  // переход не на <a> и не на onclick-атрибут, а на голый <div> со скрытым
  // обработчиком (addEventListener/jQuery): по разметке такой узел неотличим от
  // обычного текста, и раньше он молча не попадал в запись. Единственный
  // надёжный внешний признак — курсор-рука. getComputedStyle тут недоступен
  // (модуль без DOM, чтобы тестироваться в Node), поэтому признак приходит
  // снаружи параметром — так же, как cssPath.
  function isActionableClick(node, hints) {
    if (!node || node.nodeType !== 1) return false;
    if (isTextEntry(node)) return false;              // клик, просто фокусирующий поле, не пишем
    var t = tag(node);
    if (t === 'button' || t === 'a') return true;
    if (node.getAttribute('role') === 'button') return true;
    if (node.hasAttribute('onclick')) return true;
    if (t === 'input') return !!BUTTON_INPUT_TYPES[inputType(node)];
    if (hints && hints.pointer && t !== 'html' && t !== 'body') return true;
    return false;
  }

  // Теги-контейнеры раскладки: кнопкой не бывают никогда, выше них не поднимаемся.
  var CLIMB_STOP_TAGS = {
    td: 1, th: 1, tr: 1, tbody: 1, thead: 1, tfoot: 1, table: 1,
    ul: 1, ol: 1, li: 1, form: 1, body: 1, html: 1
  };
  var CLIMB_LIMIT = 4;

  /* Какой узел попадёт в шаг, если клик пришёл в target.
   *
   * env — всё «из DOM» приходит снаружи (модуль намеренно без DOM, см. шапку файла):
   *   explicit         — ближайший предок-«явная кнопка» (<a href>, <button>,
   *                      [onclick], [role=button], input-кнопка) либо null;
   *                      при клике прямо по кнопке это сам target;
   *   pointer(node)    — у узла вычисленный cursor:pointer;
   *   parent(node)     — родительский элемент;
   *   tag(node)        — имя тега в нижнем регистре;
   *   hasActionable(n) — внутри узла есть явная кнопка/ссылка.
   *
   * ПОЧЕМУ ПРИ НАЙДЕННОМ explicit ПОДЪЁМА НЕТ. cursor — НАСЛЕДУЕМОЕ свойство CSS:
   * если курсор-руку задали на карточке-контейнере, его «видят» и все её потомки.
   * Подъём «пока у родителя pointer» тогда измеряет не границы кнопки, а высоту
   * цепочки наследования. На Damumed это ровно упирается в лимит: от
   * <a>Выбрать</a> до div.panel-heading (пассивной обёртки без обработчика) —
   * четыре уровня. Записанный шаг кликал в пустоту, и шаблон вставал на первом шаге.
   * Поэтому подъём остался ТОЛЬКО для того случая, ради которого заводился:
   * явной кнопки нет вообще, есть голый div со скрытым обработчиком.
   *
   * ПОЧЕМУ НЕДОБРАТЬ ВВЕРХ БЕЗОПАСНЕЕ, ЧЕМ ПЕРЕБРАТЬ. Исполнитель (clickEl в
   * content.js) шлёт события с bubbles:true: клик по ПОТОМКУ всплывает и всё
   * равно доходит до делегированного обработчика на предке. А клик по ПРЕДКУ
   * настоящей кнопки не срабатывает никогда — вниз события не идут. Ошибка
   * «остановились слишком рано» самовосстанавливается, «поднялись слишком
   * высоко» — нет; отсюда и все стопы ниже.
   */
  function resolveClickTarget(target, env) {
    if (!target) return target;
    var e = env || {};
    if (e.explicit) return e.explicit;                 // клик по настоящей кнопке — берём её как есть
    var pointer = e.pointer || function () { return false; };
    if (!pointer(target)) return target;

    var out = target;
    var p = e.parent ? e.parent(target) : null;
    for (var i = 0; i < CLIMB_LIMIT && p; i++) {
      if (CLIMB_STOP_TAGS[e.tag ? e.tag(p) : '']) break;
      if (!pointer(p)) break;
      // Внутри есть настоящие кнопки/ссылки — значит это раскладка ВОКРУГ них,
      // а не одна большая кнопка. Иначе шаг уехал бы на карточку целиком.
      if (e.hasActionable && e.hasActionable(p)) break;
      out = p;
      p = e.parent(p);
    }
    return out;
  }

  // innerText, а не textContent: textContent втягивает содержимое <style>/<script>
  // ВНУТРИ узла. У contenteditable-редактора damumed (#editor_N) из-за этого
  // подпись шага получалась вида «Жалобы на головные боли.блаблабла*[align="right"]
  // { text-align: right !important» — в описание уезжала таблица стилей.
  // Для узлов без innerText (тесты, не-HTML) остаётся прежний textContent.
  function describeNode(node) {
    if (!node || node.nodeType !== 1) return '';
    var text = node.innerText != null ? node.innerText : (node.textContent || '');
    var s = node.getAttribute('placeholder') || node.getAttribute('aria-label') ||
            node.getAttribute('title') || text;
    return String(s).replace(/\s+/g, ' ').trim().slice(0, 80);
  }

  function buildClickStep(node, address, cssPath) {
    return {
      selector: cssPath(node), method: 'click', type_write: 'write',
      value: null, address: address || '', description: describeNode(node)
    };
  }

  function buildWriteStep(node, value, address, cssPath) {
    return {
      selector: cssPath(node), method: 'write', type_write: 'write',
      value: value == null ? '' : String(value), address: address || '',
      description: describeNode(node)
    };
  }

  // Иммутабельный дедуп: повторный write в то же поле обновляет последний шаг
  // (иначе каждый keystroke/повторное редактирование плодит шаги).
  function pushStep(steps, step) {
    var out = (steps || []).slice();
    var last = out[out.length - 1];
    if (step.method === 'write' && last && last.method === 'write' && last.selector === step.selector) {
      out[out.length - 1] = step;
      return out;
    }
    out.push(step);
    return out;
  }

  // Полный СТРУКТУРНЫЙ путь до элемента: только тег + позиция (:nth-child),
  // без id/dataset/классов. Динамические id (сессионные, сгенерированные)
  // не попадают в селектор — это безопаснее и точнее для воспроизведения.
  // Пример: "body > div:nth-child(2) > form:nth-child(1) > input:nth-child(3)".
  function structuralSelector(node) {
    if (!node || node.nodeType !== 1) return '';
    var parts = [];
    var el = node;
    while (el && el.nodeType === 1) {
      var tg = el.tagName.toLowerCase();
      if (tg === 'html' || tg === 'body') { parts.unshift(tg); break; }
      var parent = el.parentElement;
      if (!parent) { parts.unshift(tg); break; }
      var kids = parent.children || [];
      var idx = 0;
      for (var i = 0; i < kids.length; i++) { if (kids[i] === el) { idx = i + 1; break; } }
      parts.unshift(idx ? tg + ':nth-child(' + idx + ')' : tg);
      el = parent;
    }
    return parts.join(' > ');
  }

  // Оборачивает записанные шаги в структуру server/templates/20.json.
  // dateStr — передаётся снаружи (в модуле нет доступа ко времени; так тест детерминирован).
  function toTemplateFile(name, id, steps, dateStr) {
    return {
      id: id,
      name: String(name == null ? 'Без имени' : name),
      description: 'Записано в режиме «Обучение» ' + (dateStr || ''),
      example_output: { template: 'recorded', steps: (steps || []).slice() }
    };
  }

  return {
    isTextEntry: isTextEntry,
    isActionableClick: isActionableClick,
    resolveClickTarget: resolveClickTarget,
    describeNode: describeNode,
    buildClickStep: buildClickStep,
    buildWriteStep: buildWriteStep,
    pushStep: pushStep,
    toTemplateFile: toTemplateFile,
    structuralSelector: structuralSelector
  };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = AqRecorder;
