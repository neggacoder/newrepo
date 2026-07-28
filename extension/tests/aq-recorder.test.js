/* Запуск: node --test extension/tests/aq-recorder.test.js */
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  isTextEntry, isActionableClick, resolveClickTarget, describeNode,
  buildClickStep, buildWriteStep, pushStep, toTemplateFile, structuralSelector
} = require('../aq-recorder.js');

// Фейковый DOM-узел: только то, что читают функции модуля.
function fakeNode(spec) {
  spec = spec || {};
  const attrs = spec.attrs || {};
  return {
    nodeType: 1,
    tagName: (spec.tag || 'div').toUpperCase(),
    isContentEditable: !!spec.contentEditable,
    textContent: spec.text || '',
    _sel: spec.sel || '#none',
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k); }
  };
}
const cssPath = (n) => n._sel;

test('isTextEntry: input/textarea/select/contenteditable — да; button — нет', () => {
  assert.strictEqual(isTextEntry(fakeNode({ tag: 'input', attrs: { type: 'text' } })), true);
  assert.strictEqual(isTextEntry(fakeNode({ tag: 'textarea' })), true);
  assert.strictEqual(isTextEntry(fakeNode({ tag: 'select' })), true);
  assert.strictEqual(isTextEntry(fakeNode({ tag: 'div', contentEditable: true })), true);
  assert.strictEqual(isTextEntry(fakeNode({ tag: 'button' })), false);
  assert.strictEqual(isTextEntry(fakeNode({ tag: 'input', attrs: { type: 'checkbox' } })), false);
});

test('isActionableClick: кнопки/ссылки/role=button/onclick — да; текстовое поле — нет', () => {
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'button' })), true);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'a', attrs: { href: '#' } })), true);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'div', attrs: { role: 'button' } })), true);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'span', attrs: { onclick: 'f()' } })), true);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'input', attrs: { type: 'submit' } })), true);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'input', attrs: { type: 'text' } })), false);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'div' })), false);
});

test('isActionableClick: div со скрытым обработчиком опознаётся по cursor:pointer', () => {
  // Damumed: <div> без onclick-атрибута, переход вешает jQuery — единственный
  // внешний признак кликабельности приходит из content.js как hints.pointer.
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'div' }), { pointer: true }), true);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'div' }), { pointer: false }), false);
  // Текстовое поле остаётся вводом, даже если у него курсор-рука.
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'input', attrs: { type: 'text' } }), { pointer: true }), false);
  // <body>/<html> с курсором-рукой кликом не считаем — иначе в запись попадёт
  // любой промах мимо элемента.
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'body' }), { pointer: true }), false);
  assert.strictEqual(isActionableClick(fakeNode({ tag: 'html' }), { pointer: true }), false);
});

/* ─── resolveClickTarget ────────────────────────────────────────────────────
   Дерево линейное: предок → потомок, индекс растёт вглубь. Этого хватает —
   функция ходит только вверх по одной ветке. */
function chain(tags) {
  const nodes = tags.map((t) => ({ nodeType: 1, tagName: t.toUpperCase(), parent: null }));
  for (let i = 1; i < nodes.length; i++) nodes[i].parent = nodes[i - 1];
  return nodes;
}
// pointerFrom — индекс узла, ОБЪЯВИВШЕГО cursor:pointer. У него и у всех
// потомков getComputedStyle вернёт pointer: cursor — наследуемое свойство CSS,
// и именно это ломало прежний подъём «пока у родителя курсор-рука».
function envFor(nodes, opts) {
  const o = opts || {};
  const at = (n) => nodes.indexOf(n);
  const from = o.pointerFrom == null ? -1 : o.pointerFrom;
  const contains = o.containsActionable || [];
  return {
    explicit: o.explicit == null ? null : nodes[o.explicit],
    pointer: (n) => from >= 0 && at(n) >= from,
    parent: (n) => (n ? n.parent : null),
    tag: (n) => n.tagName.toLowerCase(),
    hasActionable: (n) => contains.indexOf(at(n)) >= 0
  };
}

test('resolveClickTarget: клик по <a> внутри карточки с курсором-рукой берёт сам <a>', () => {
  // Регрессия из кабинета врача Damumed: карточка пациента задаёт cursor:pointer,
  // и все её потомки его НАСЛЕДУЮТ. Прежний подъём уезжал на 4 уровня вверх — с
  // <a>Выбрать</a> на пассивный div.panel-heading без обработчика, и шаг кликал
  // в пустоту (шаблон вставал на первом же шаге).
  const n = chain(['td', 'div', 'div', 'div', 'div', 'div', 'a']);
  //                0     1      2*     3      4      5      6   (* объявил pointer)
  const got = resolveClickTarget(n[6], envFor(n, { pointerFrom: 2, explicit: 6 }));
  assert.strictEqual(got, n[6], 'должен остаться <a>');
  assert.notStrictEqual(got, n[2], 'не должен уехать на карточку-обёртку');
});

test('resolveClickTarget: клик по иконке внутри кнопки берёт кнопку', () => {
  const n = chain(['div', 'button', 'span']);
  assert.strictEqual(resolveClickTarget(n[2], envFor(n, { explicit: 1 })), n[1]);
});

test('resolveClickTarget: голый div со скрытым обработчиком — подъём работает', () => {
  // То, ради чего подъём и заводился: явной кнопки нет, клик попал в текстовый
  // потомок кликабельного блока.
  const n = chain(['td', 'div', 'div', 'span']);
  assert.strictEqual(resolveClickTarget(n[3], envFor(n, { pointerFrom: 1 })), n[1]);
});

test('resolveClickTarget: подъём не проглатывает контейнер с настоящими кнопками внутри', () => {
  const n = chain(['td', 'div', 'div', 'span']);
  const got = resolveClickTarget(n[3], envFor(n, { pointerFrom: 1, containsActionable: [1] }));
  assert.strictEqual(got, n[2]);
  assert.notStrictEqual(got, n[1]);
});

test('resolveClickTarget: подъём останавливается на структурных тегах (td/tr/li/form)', () => {
  const n = chain(['ul', 'li', 'div', 'span']);
  assert.strictEqual(resolveClickTarget(n[3], envFor(n, { pointerFrom: 0 })), n[2]);
});

test('resolveClickTarget: без курсора-руки и без явной кнопки узел не меняется', () => {
  const n = chain(['div', 'span']);
  assert.strictEqual(resolveClickTarget(n[1], envFor(n, {})), n[1]);
});

test('buildClickStep: method=click, value=null, address и selector на месте', () => {
  const step = buildClickStep(fakeNode({ tag: 'button', text: 'Сохранить', sel: '#save' }), 'https://x/y', cssPath);
  assert.deepStrictEqual(step, {
    selector: '#save', method: 'click', type_write: 'write',
    value: null, address: 'https://x/y', description: 'Сохранить'
  });
});

test('buildWriteStep: method=write, значение строкой, type_write=write', () => {
  const step = buildWriteStep(fakeNode({ tag: 'input', attrs: { placeholder: 'ИИН' }, sel: '#iin' }), 870312, 'https://x/y', cssPath);
  assert.deepStrictEqual(step, {
    selector: '#iin', method: 'write', type_write: 'write',
    value: '870312', address: 'https://x/y', description: 'ИИН'
  });
});

test('describeNode: приоритет placeholder>aria-label>title>textContent, обрезка', () => {
  assert.strictEqual(describeNode(fakeNode({ tag: 'input', attrs: { placeholder: 'Фамилия' } })), 'Фамилия');
  assert.strictEqual(describeNode(fakeNode({ tag: 'button', text: '  Отправить\n ' })), 'Отправить');
});

test('pushStep: два write по одному selector схлопываются в последний', () => {
  let steps = [];
  steps = pushStep(steps, buildWriteStep(fakeNode({ tag: 'input', sel: '#a' }), '1', 'u', cssPath));
  steps = pushStep(steps, buildWriteStep(fakeNode({ tag: 'input', sel: '#a' }), '12', 'u', cssPath));
  assert.strictEqual(steps.length, 1);
  assert.strictEqual(steps[0].value, '12');
});

test('pushStep: разные selector и click — добавляются', () => {
  let steps = [];
  steps = pushStep(steps, buildWriteStep(fakeNode({ tag: 'input', sel: '#a' }), '1', 'u', cssPath));
  steps = pushStep(steps, buildWriteStep(fakeNode({ tag: 'input', sel: '#b' }), '2', 'u', cssPath));
  steps = pushStep(steps, buildClickStep(fakeNode({ tag: 'button', sel: '#b' }), 'u', cssPath));
  assert.strictEqual(steps.length, 3);
});

test('pushStep иммутабелен: исходный массив не меняется', () => {
  const orig = [];
  const next = pushStep(orig, buildClickStep(fakeNode({ tag: 'button', sel: '#x' }), 'u', cssPath));
  assert.strictEqual(orig.length, 0);
  assert.strictEqual(next.length, 1);
});

test('toTemplateFile: структура точно как 20.json', () => {
  const steps = [{ selector: '#a', method: 'write', type_write: 'write', value: 'X', address: 'u' }];
  const file = toTemplateFile('Мой шаблон', 21, steps, '2026-07-15');
  assert.deepStrictEqual(file, {
    id: 21,
    name: 'Мой шаблон',
    description: 'Записано в режиме «Обучение» 2026-07-15',
    example_output: { template: 'recorded', steps }
  });
});

// --- structuralSelector: тег + позиция, без id/dataset/классов ---

function elem(tag, children) {
  const node = { nodeType: 1, tagName: tag.toUpperCase(), parentElement: null, children: children || [] };
  (children || []).forEach((c) => { c.parentElement = node; });
  return node;
}

test('structuralSelector: полный путь до body с nth-child на каждом уровне', () => {
  const input = elem('input');
  const otherInput1 = elem('input');
  const otherInput2 = elem('input');
  const form = elem('form', [otherInput1, otherInput2, input]); // input — 3-й ребёнок
  const otherDiv = elem('div');
  const div = elem('div', [form]); // form — 1-й ребёнок
  const body = elem('body', [otherDiv, div]); // div — 2-й ребёнок

  assert.strictEqual(
    structuralSelector(input),
    'body > div:nth-child(2) > form:nth-child(1) > input:nth-child(3)'
  );
});

test('structuralSelector: не содержит #, ., [ даже если у узлов есть id/class/dataset', () => {
  const leaf = elem('span');
  leaf.id = 'guide-snippet-question_LandingForGold_EJIHEICDDI-2';
  leaf.className = 'some-class another-class';
  leaf.dataset = { foo: 'bar' };
  const parent = elem('div', [leaf]);
  parent.id = 'parent-id';
  parent.className = 'parent-class';
  const body = elem('body', [parent]);

  const sel = structuralSelector(leaf);
  assert.ok(!sel.includes('#'), 'не должно быть #: ' + sel);
  assert.ok(!sel.includes('.'), 'не должно быть .: ' + sel);
  assert.ok(!sel.includes('['), 'не должно быть [: ' + sel);
});

test('structuralSelector: body → "body"; null → ""; текстовый узел → ""', () => {
  const body = elem('body');
  assert.strictEqual(structuralSelector(body), 'body');
  assert.strictEqual(structuralSelector(null), '');
  assert.strictEqual(structuralSelector({ nodeType: 3, tagName: 'DIV' }), '');
});

test('structuralSelector: nth-child считает позицию среди ВСЕХ соседей-элементов', () => {
  const target = elem('p');
  const sib1 = elem('span');
  const sib2 = elem('span');
  const parent = elem('div', [sib1, sib2, target]); // target — 3-й ребёнок
  const body = elem('body', [parent]);

  assert.strictEqual(structuralSelector(target), 'body > div:nth-child(1) > p:nth-child(3)');
});

test('structuralSelector: цепочка родителей упирается прямо в html (без body)', () => {
  const div = elem('div');
  const html = elem('html', [div]); // div — 1-й ребёнок

  assert.strictEqual(structuralSelector(div), 'html > div:nth-child(1)');
});
