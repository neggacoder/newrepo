/*
 * Suerte / Aqbobek — браузерный тест шаблона #20 «Первичный приём».
 * ─────────────────────────────────────────────────────────────────────
 * Это МИНИ-исполнитель (как в расширении), чтобы проверить план steps
 * прямо на демо-странице, без сервера и расширения.
 *
 * Как пользоваться:
 *   1. Открыть https://herachxx.github.io/damumed-example/
 *   2. Перейти на вкладку «Новый приём».
 *   3. Открыть DevTools (F12) → Console.
 *   4. Вставить весь этот файл и нажать Enter — форма заполнится по шагам.
 *
 * PLAN получен из decode() декодера 20.py на файле test_20_visit.txt.
 * Финальный шаг (клик «Сохранить и передать в КМИС») по умолчанию ВЫКЛЮЧЕН,
 * чтобы не срабатывал alert. Включить — SUBMIT = true ниже.
 */
(async () => {
  const SUBMIT = false;        // true — выполнять и финальный клик «Сохранить»
  const DELAY_MS = 250;        // пауза между шагами (наглядность)

  const PLAN = [
    { selector: "#patient-lastname",   method: "write", value: "Жунусов" },
    { selector: "#patient-firstname",  method: "write", value: "Марат" },
    { selector: "#patient-middlename", method: "write", value: "Бекович" },
    { selector: "#patient-iin",        method: "write", value: "870312300247" },
    { selector: "#patient-dob",        method: "write", value: "1987-03-12" },
    { selector: "#patient-gender",     method: "write", value: "Мужской" },
    { selector: "#patient-phone",      method: "write", value: "+7 (701) 234-56-78" },
    { selector: "#patient-address",    method: "write", value: "г. Алматы, ул. Абая, д. 12, кв. 34" },
    { selector: "#bp-sys",             method: "write", value: "130" },
    { selector: "#bp-dia",             method: "write", value: "85" },
    { selector: "#pulse",              method: "write", value: "78" },
    { selector: "#temp",               method: "write", value: "36.8" },
    { selector: "#height",             method: "write", value: "176" },
    { selector: "#weight",             method: "write", value: "82" },
    { selector: "#spo2",               method: "write", value: "97" },
    { selector: "#complaints",         method: "write", value: "Одышка при физической нагрузке, кашель с мокротой по утрам, свистящее дыхание." },
    { selector: "#anamnesis",          method: "write", value: "Болен около 5 лет, ухудшение в течение недели после переохлаждения, курит 20 лет." },
    { selector: "#icd-search",         method: "write", value: "J44.1" },
    { selector: "#diag-text",          method: "write", value: "Хроническая обструктивная болезнь лёгких, обострение средней степени тяжести." },
    { selector: "#non-med",            method: "write", value: "Отказ от курения, дыхательная гимнастика, обильное тёплое питьё." },
    { selector: "#recommendations",    method: "write", value: "Контроль состояния через 7 дней, при усилении одышки обращение немедленно." },
    { selector: "#tab-new-visit .form-actions .btn-primary", method: "click", value: null, submit: true },
  ];

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Аналог write из исполнителя расширения: ставит значение + шлёт input/change,
  // чтобы обычный JS/фреймворк на странице увидел изменение.
  function writeValue(el, value) {
    el.focus();
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  let done = 0, skipped = 0;
  for (const step of PLAN) {
    if (step.submit && !SUBMIT) { console.log("· пропуск (SUBMIT=false):", step.selector); skipped++; continue; }
    const el = document.querySelector(step.selector);
    if (!el) { console.warn("✗ не найден селектор:", step.selector); skipped++; continue; }
    el.scrollIntoView({ block: "center", behavior: "smooth" });
    if (step.method === "click") {
      el.click();
    } else {
      writeValue(el, step.value);
    }
    el.style.outline = "2px solid #22c55e";
    setTimeout(() => (el.style.outline = ""), 800);
    console.log("✓", step.selector, "=", step.value ?? "(click)");
    done++;
    await sleep(DELAY_MS);
  }
  console.log(`Готово. Заполнено: ${done}, пропущено: ${skipped}. SUBMIT=${SUBMIT}`);
})();
