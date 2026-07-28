/* Suerte / Aqbobek — мост в MAIN-мир страницы Damumed (editMedicalRecord).
 *
 * content.js работает в ИЗОЛИРОВАННОМ мире: он видит DOM, но не видит JS-объекты
 * страницы. Данные мед. записи лежат именно в них:
 *   EditMedicalRecordFieldData.model  — все 16 блоков (file1.html:1364)
 *   MedicalRecordsEditor['md_0']      — редактор и queryItems (file1.html:1886)
 * Поэтому читаем их отсюда, через chrome.scripting.executeScript({world:'MAIN'}).
 *
 * ВАЖНО: каждая функция ниже уходит в executeScript({func}) и сериализуется в
 * исходный текст. У неё НЕ может быть замыканий, импортов и ссылок на соседей —
 * всё внешнее приходит через args, все хелперы объявляются внутри тела.
 */
'use strict';

/* Идентификаторы пациента и записи. patientAdmissionRegisterID есть и в URL,
   и в queryItems (QueryItemType: 1 — пациент, 2 — история болезни). */
export function readPageIds() {
  const out = { patientAdmissionRegisterID: null, medicalHistoryID: null, medicalRecordTypeID: null };

  try {
    const params = new URL(location.href).searchParams;
    out.patientAdmissionRegisterID = params.get('patientAdmissionRegisterID');
    out.medicalRecordTypeID = params.get('medicalRecordTypeID');
  } catch (_e) { /* URL без параметров — добираем из queryItems ниже */ }

  try {
    const editor = window.MedicalRecordsEditor && window.MedicalRecordsEditor['md_0'];
    const qi = editor && typeof editor.queryItems === 'function' ? editor.queryItems() : null;
    const items = (qi && qi.QueryItems) || [];
    items.forEach((it) => {
      if (it.QueryItemType === 1 && !out.patientAdmissionRegisterID) out.patientAdmissionRegisterID = String(it.QueryItemValue);
      if (it.QueryItemType === 2 && !out.medicalHistoryID) out.medicalHistoryID = String(it.QueryItemValue);
    });
  } catch (_e) { /* модели ещё нет — вернём то, что нашли в URL */ }

  return out;
}

/* Все блоки разом из JS-модели. Активный блок ещё не закоммичен в модель
   (это делает saveCurrentField при переключении), поэтому берём его из редактора. */
export function readFieldBlocks() {
  const store = window.EditMedicalRecordFieldData;
  if (!store || !Array.isArray(store.model) || !store.model.length) return null;

  const activeLink = document.querySelector('#divFieldData a.active');
  const activeId = activeLink ? activeLink.getAttribute('data-id') : null;

  let activeHtml = null;
  try {
    const editor = window.MedicalRecordsEditor && window.MedicalRecordsEditor['md_0'];
    if (editor && typeof editor.medicalRecord === 'function') activeHtml = editor.medicalRecord();
  } catch (_e) { /* редактор не готов — возьмём значение из модели */ }

  return store.model.map((m) => {
    const id = String(m.ID);
    const fromModel = (m.MedicalRecord && m.MedicalRecord.Record) || '';
    const isActive = id === activeId;
    return {
      id,
      name: (m.MedicalRecordFieldDataType && m.MedicalRecordFieldDataType.Name) || id,
      html: (isActive && activeHtml != null) ? activeHtml : fromModel,
      active: isActive
    };
  });
}

/* Фоллбэк на случай, если Damumed переименует модель: обходим блоки кликами и
   читаем содержимое редактора после каждого. Медленнее и заметно для врача,
   поэтому используется только когда readFieldBlocks вернул null. */
export async function readBlocksByClicking() {
  const links = Array.prototype.slice.call(document.querySelectorAll('#divFieldData a[data-id]'));
  if (!links.length) return null;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const originallyActive = document.querySelector('#divFieldData a.active');

  const readEditorHtml = () => {
    const frames = document.querySelectorAll('iframe');
    for (const frame of frames) {
      let doc = null;
      try { doc = frame.contentDocument; } catch (_e) { continue; }  // чужой origin
      const body = doc && doc.body;
      if (body && /^editor_\d+$/.test(body.id || '')) return body.innerHTML || '';
    }
    return '';
  };

  const out = [];
  for (const link of links) {
    link.click();
    await sleep(150);   // onFieldDataChange перерисовывает редактор синхронно, запас на всякий случай
    out.push({
      id: link.getAttribute('data-id'),
      name: (link.textContent || '').trim(),
      html: readEditorHtml(),
      active: false
    });
  }

  if (originallyActive) { originallyActive.click(); await sleep(150); }
  return out;
}

/* Предыдущие мед. записи пациента. Kendo объявляет transport как
   type:'POST', dataType:'json' БЕЗ contentType (file2.html:1525-1532) — то есть
   уходит через $.ajax с form-urlencoded телом. Чтобы не повторять сериализацию
   вручную, зовём ту же page-jQuery; fetch — только фоллбэк. */
export function fetchHistory(parId, limit) {
  const url = '/patientMedicalRecord/getMedicalRecords';
  const data = {
    PatientAdmissionRegisterID: String(parId),
    OrderBy: 'TypeThenRegDateDesc',
    Offset: 0,
    Limit: limit
  };

  // Ровно то, что рисует onViewButtonClick в about:blank (file2.html:607).
  const shape = (resp) => ((resp && resp.Data) || []).map((it) => {
    const rec = it.MedicalRecord || {};
    const html = [rec.Record || '', rec.MedicalFinal || ''].filter(Boolean).join('<br>');
    return {
      type: (it.MedicalRecordType && it.MedicalRecordType.Name) || 'Мед. запись',
      date: rec.RegDateTimeStr || '',
      html
    };
  });

  const jq = window.jQuery || window.$;
  if (typeof jq === 'function' && jq.ajax) {
    return new Promise((resolve) => {
      jq.ajax({ url, type: 'POST', dataType: 'json', data })
        .done((resp) => resolve({ ok: true, records: shape(resp) }))
        .fail((xhr) => resolve({
          ok: false,
          status: (xhr && xhr.status) || 0,
          error: (xhr && (xhr.status === 401 || xhr.status === 403))
            ? 'Сессия Damumed истекла — войдите заново'
            : 'Damumed отклонил запрос истории (HTTP ' + ((xhr && xhr.status) || '?') + ')'
        }));
    });
  }

  return fetch(url, {
    method: 'POST',
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: new URLSearchParams(data).toString()
  }).then((res) => {
    if (res.status === 401 || res.status === 403) return { ok: false, status: res.status, error: 'Сессия Damumed истекла — войдите заново' };
    if (!res.ok) return { ok: false, status: res.status, error: 'Damumed отклонил запрос истории (HTTP ' + res.status + ')' };
    const ct = res.headers.get('content-type') || '';
    // Истёкшая сессия часто отдаёт 200 + HTML страницы логина.
    if (ct.indexOf('json') === -1) return { ok: false, status: res.status, error: 'Сессия Damumed истекла — войдите заново' };
    return res.json().then((resp) => ({ ok: true, records: shape(resp) }));
  }).catch((e) => ({ ok: false, error: 'Сеть недоступна: ' + ((e && e.message) || String(e)) }));
}
