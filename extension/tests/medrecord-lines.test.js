/* Запуск: node --test extension/tests/ */
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { htmlBlockToText, isBlockEmpty } = require('../medrecord-lines.js');

test('первая строка идёт голым текстом, следующие — в <div>', () => {
  assert.strictEqual(htmlBlockToText('Привет<div>Как дела</div>'), 'Привет\nКак дела');
});

test('<div><br></div> даёт пустую строку между абзацами', () => {
  assert.strictEqual(htmlBlockToText('А<div><br></div><div>Б</div>'), 'А\n\nБ');
});

test('одиночный <div><br></div> разворачивается в пустую строку', () => {
  assert.strictEqual(htmlBlockToText('<div><br></div>'), '');
});

test('служебный <style id="omgcss"> вырезается вместе с содержимым', () => {
  assert.strictEqual(htmlBlockToText('<style id="omgcss">table td{border:1px}</style>Текст'), 'Текст');
});

test('HTML-сущности декодируются', () => {
  assert.strictEqual(htmlBlockToText('&lt;b&gt;&nbsp;A &amp; B'), '<b> A & B');
});

test('таблица разворачивается построчно', () => {
  assert.strictEqual(htmlBlockToText('<table><tr><td>А</td></tr><tr><td>Б</td></tr></table>'), 'А\nБ');
});

test('null и undefined безопасны', () => {
  assert.strictEqual(htmlBlockToText(null), '');
  assert.strictEqual(htmlBlockToText(undefined), '');
});

test('isBlockEmpty: пустой редактор', () => {
  assert.strictEqual(isBlockEmpty('<div><br></div>'), true);
  assert.strictEqual(isBlockEmpty(''), true);
  assert.strictEqual(isBlockEmpty(null), true);
});

test('isBlockEmpty: блок с одним лишь omgcss считается пустым', () => {
  assert.strictEqual(isBlockEmpty('<style id="omgcss">table td{border:1px}</style>'), true);
});

test('isBlockEmpty: блок с текстом не пуст', () => {
  assert.strictEqual(isBlockEmpty('<div>Жалоб нет</div>'), false);
  assert.strictEqual(isBlockEmpty('<div>36.6</div>'), false);
});

test('isBlockEmpty: одна пунктуация — это пусто', () => {
  assert.strictEqual(isBlockEmpty('<div>—</div>'), true);
});
