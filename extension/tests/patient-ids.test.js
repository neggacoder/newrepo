/* Запуск: node --test extension/tests/patient-ids.test.js */
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  extractPatientIds, extractFullNameFromTitle,
  editIdFromOnclick, watchIdFromOnclick, fioFromText
} = require('../patient-ids.js');

const EDIT = 'https://hospital-akt.dmed.kz/patientMedicalRecord/editMedicalRecord?id=0&patientAdmissionRegisterID=3136382&medicalRecordTypeID=6';
const HISTORY = 'https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186386';

test('editMedicalRecord: берём patientAdmissionRegisterID, а не id', () => {
  assert.deepStrictEqual(extractPatientIds(EDIT), { patientAdmissionRegisterID: '3136382' });
});

test('medicalHistory: id — это medicalHistoryID', () => {
  assert.deepStrictEqual(extractPatientIds(HISTORY), { medicalHistoryID: '2186386' });
});

test('medicalHistory с якорем и лишними параметрами', () => {
  assert.deepStrictEqual(
    extractPatientIds('https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186386#tab'),
    { medicalHistoryID: '2186386' });
});

test('оба параметра сразу: patientAdmissionRegisterID главнее', () => {
  const both = 'https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=2186386&patientAdmissionRegisterID=3136382';
  assert.deepStrictEqual(extractPatientIds(both), { patientAdmissionRegisterID: '3136382', medicalHistoryID: '2186386' });
});

test('страница без id — пустой объект', () => {
  assert.deepStrictEqual(extractPatientIds('https://hospital-akt.dmed.kz/myCab'), {});
});

test('id вне medicalHistory не считается идентификатором пациента', () => {
  assert.deepStrictEqual(extractPatientIds('https://hospital-akt.dmed.kz/dictionary/list?id=42'), {});
});

test('нечисловой id игнорируется', () => {
  assert.deepStrictEqual(extractPatientIds('https://hospital-akt.dmed.kz/medicalHistory/medicalHistory?id=abc'), {});
});

test('мусор вместо URL не роняет', () => {
  assert.deepStrictEqual(extractPatientIds('не url'), {});
  assert.deepStrictEqual(extractPatientIds(null), {});
});

test('ФИО из title страницы medicalHistory', () => {
  assert.strictEqual(
    extractFullNameFromTitle('БЕЛАЛОВА РАЯНА РОМАНОВНА 04.06.2019 - Dmed.Стационар'),
    'Белалова Раяна Романовна');
});

test('ФИО без отчества', () => {
  assert.strictEqual(extractFullNameFromTitle('ИВАНОВ ПЁТР 01.02.1990 - Dmed'), 'Иванов Пётр');
});

test('title без ФИО даёт пустую строку', () => {
  assert.strictEqual(extractFullNameFromTitle('Медицинская запись - Dmed.Стационар'), '');
  assert.strictEqual(extractFullNameFromTitle(''), '');
  assert.strictEqual(extractFullNameFromTitle(null), '');
});

test('ФИО без даты рождения не распознаётся (не хотим ложных срабатываний)', () => {
  assert.strictEqual(extractFullNameFromTitle('БЕЛАЛОВА РАЯНА РОМАНОВНА - Dmed'), '');
});

/* ── журнал ids.jsonl: разбор onclick и ФИО из div.patient-info ───────── */

test('editIdFromOnclick: dropdown «создать запись» (первый аргумент 0)', () => {
  assert.deepStrictEqual(
    editIdFromOnclick("PatientMedicalRecordList.onEditButtonClick(0, '3136436', '12')"),
    { id: '3136436', fromDropdown: true });
});

test('editIdFromOnclick: строка грида (первый аргумент — id записи)', () => {
  assert.deepStrictEqual(
    editIdFromOnclick("PatientMedicalRecordList.onEditButtonClick('21641095', '3136436', '12');"),
    { id: '3136436', fromDropdown: false });
});

test('editIdFromOnclick: чужой обработчик и kendo-шаблон — null', () => {
  assert.strictEqual(editIdFromOnclick("PatientMedicalRecordList.onDeleteButtonClick('21641095', '12');"), null);
  assert.strictEqual(editIdFromOnclick("PatientMedicalRecordList.onEditButtonClick('#: ID #', '#: PatientAdmissionRegisterID #', '#: MedicalRecordTypeID #');"), null);
  assert.strictEqual(editIdFromOnclick(''), null);
  assert.strictEqual(editIdFromOnclick(null), null);
});

test('watchIdFromOnclick: берём ТОЛЬКО запись типа 1', () => {
  assert.strictEqual(watchIdFromOnclick("PatientMedicalRecordList.onViewButtonClick('21641017', '1');"), '21641017');
});

test('watchIdFromOnclick: другие типы и шаблоны — null', () => {
  assert.strictEqual(watchIdFromOnclick("PatientMedicalRecordList.onViewButtonClick('21641095', '12');"), null);
  assert.strictEqual(watchIdFromOnclick("PatientMedicalRecordList.onViewButtonClick('#: ID #', '#: MedicalRecordTypeID #');"), null);
  assert.strictEqual(watchIdFromOnclick(null), null);
});

test('fioFromText: «№981 ФИО дата (лет)» из div.patient-info', () => {
  assert.strictEqual(
    fioFromText('№981 АМАНТАЙ ДИДАР ДАРХАНҰЛЫ 10.12.2017 (8) '),
    'АМАНТАЙ ДИДАР ДАРХАНҰЛЫ');
});

test('fioFromText: битая кодировка номера («в„–981») не мешает', () => {
  assert.strictEqual(
    fioFromText('в„–981 АМАНТАЙ ДИДАР ДАРХАНҰЛЫ 10.12.2017 (8)'),
    'АМАНТАЙ ДИДАР ДАРХАНҰЛЫ');
});

test('fioFromText: без даты — пустая строка', () => {
  assert.strictEqual(fioFromText('№981 АМАНТАЙ ДИДАР ДАРХАНҰЛЫ'), '');
  assert.strictEqual(fioFromText(''), '');
  assert.strictEqual(fioFromText(null), '');
});
