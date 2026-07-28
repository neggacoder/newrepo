/* Suerte / Aqbobek — какой идентификатор пациента лежит в ссылке.
 *
 * «В конце каждой ссылки про человека всегда есть его id» — почти правда, но
 * id РАЗНЫЕ. На medicalHistory ?id= — это medicalHistoryID (2186386), а на
 * editMedicalRecord тот же человек проходит как patientAdmissionRegisterID
 * (3136382), и ?id= там означает id самой мед. записи (0 для новой).
 * Поэтому смотрим на параметр и на путь, а не на «последнее число».
 */
var AqPatientIds = (function () {
  'use strict';

  var NUM = /^\d+$/;

  function extractPatientIds(href) {
    var out = {};
    var url;
    try { url = new URL(String(href)); } catch (_e) { return out; }

    var par = url.searchParams.get('patientAdmissionRegisterID');
    if (par && NUM.test(par)) out.patientAdmissionRegisterID = par;

    // ?id= означает пациента ТОЛЬКО на medicalHistory.
    if (/\/medicalHistory\//i.test(url.pathname)) {
      var mh = url.searchParams.get('id');
      if (mh && NUM.test(mh)) out.medicalHistoryID = mh;
    }
    return out;
  }

  // ФИО пациента на странице medicalHistory лежит только в <title>:
  //   «БЕЛАЛОВА РАЯНА РОМАНОВНА 04.06.2019 - Dmed.Стационар»
  // На editMedicalRecord его нет нигде — ни в модели, ни в API (RegPost.PersonShortName
  // это исполнитель, то есть врач). Не нашли — возвращаем '' и живём без ФИО.
  var TITLE_FIO = /^\s*([А-ЯЁ]{2,}(?:\s+[А-ЯЁ]{2,}){1,2})\s+\d{2}\.\d{2}\.\d{4}/;

  function extractFullNameFromTitle(title) {
    var m = TITLE_FIO.exec(String(title == null ? '' : title));
    if (!m) return '';
    // «БЕЛАЛОВА РАЯНА» -> «Белалова Раяна»
    return m[1].split(/\s+/).map(function (word) {
      return word.charAt(0) + word.slice(1).toLowerCase();
    }).join(' ');
  }

  /* ── Журнал ids.jsonl: разбор кнопок грида medicalHistory ─────────────
   * Dropdown «создать запись» несёт первый аргумент 0, строка грида — id
   * записи в кавычках; второй аргумент в обоих случаях —
   * patientAdmissionRegisterID. Kendo-шаблоны ('#: ID #') отсекаются
   * требованием \d+. */
  var EDIT_DROPDOWN = /onEditButtonClick\(\s*0\s*,\s*'(\d+)'/;
  var EDIT_GRID = /onEditButtonClick\(\s*'(\d+)'\s*,\s*'(\d+)'/;
  var VIEW_TYPE1 = /onViewButtonClick\(\s*'(\d+)'\s*,\s*'1'\s*\)/;

  function editIdFromOnclick(onclick) {
    var s = String(onclick == null ? '' : onclick);
    var m = EDIT_DROPDOWN.exec(s);
    if (m) return { id: m[1], fromDropdown: true };
    m = EDIT_GRID.exec(s);
    if (m) return { id: m[2], fromDropdown: false };
    return null;
  }

  function watchIdFromOnclick(onclick) {
    var m = VIEW_TYPE1.exec(String(onclick == null ? '' : onclick));
    return m ? m[1] : null;
  }

  /* ФИО в div.patient-info: «№981 ФИО 10.12.2017 (8)». Сохранённые страницы
   * иногда портят «№» кодировкой («в„–981»), поэтому имя ищем от первой
   * ЗАГЛАВНОЙ буквы (включая казахские Ә, Ғ, Қ, Ң, Ө, Ұ, Ү, Һ, І) до даты.
   * Регистр не трогаем: в ids.jsonl имя лежит как на странице. */
  var FIO_UPPER = 'А-ЯЁӘҒҚҢӨҰҮҺІA-Z';
  var FIO_BEFORE_DATE = /^\s*(.+?)\s+\d{2}\.\d{2}\.\d{4}/;

  function fioFromText(text) {
    var s = String(text == null ? '' : text).replace(/\s+/g, ' ');
    var m = FIO_BEFORE_DATE.exec(s);
    if (!m) return '';
    return m[1].replace(new RegExp('^[^' + FIO_UPPER + ']+'), '').trim();
  }

  return {
    extractPatientIds: extractPatientIds,
    extractFullNameFromTitle: extractFullNameFromTitle,
    editIdFromOnclick: editIdFromOnclick,
    watchIdFromOnclick: watchIdFromOnclick,
    fioFromText: fioFromText
  };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = AqPatientIds;
