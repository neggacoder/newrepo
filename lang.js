/* ============================================================
   LANG.JS — мультиязычность (KK / RU / EN)
   Язык сохраняется в localStorage под ключом 'jas_lang'
   ============================================================ */

const TRANSLATIONS = {

  /* ─── ОБЩИЕ / NAV ─────────────────────────────────────── */
  nav_support:    { kk: 'Қолдау', ru: 'Поддержать', en: 'Donate' },
  nav_specialists:{ kk: 'Мамандар', ru: 'Специалисты', en: 'Specialists' },
  nav_about:      { kk: 'Біз туралы', ru: 'О нас', en: 'About us' },
  nav_faq:        { kk: 'Жиі сұрақтар', ru: 'Частые вопросы', en: 'FAQ' },
  nav_employees:  { kk: 'Қызметкерлерге', ru: 'Для сотрудников', en: 'For staff' },

  /* ─── INDEX ───────────────────────────────────────────── */
  hero_lead: {
    kk: 'Аутизм спектрі бұзылыстары мен басқа ментальды ерекшеліктері бар балалар мен жасөспірімдерді, сондай-ақ олардың отбасыларын қолдауға арналған қоғамдық қор.',
    ru: 'Общественный фонд, созданный для поддержки детей и подростков с расстройствами аутистического спектра и другими ментальными нарушениями, а также их семей.',
    en: 'A public foundation supporting children and teenagers with autism spectrum disorders and other developmental differences, as well as their families.'
  },
  hero_sub: {
    kk: 'Біз біріктіреміз: заманауи терапия әдістері, мамандарды оқыту, ата-аналарды қолдау, дербестікті дамыту және әлеуметтік бейімделу жобалары.',
    ru: 'Мы объединяем: современные методы терапии, обучение специалистов, поддержку родителей, проекты по развитию самостоятельности и социальной адаптации.',
    en: 'We bring together: modern therapy methods, specialist training, parent support, and projects for developing independence and social integration.'
  },
  mission_eyebrow: { kk: 'Қордың миссиясы', ru: 'Миссия фонда', en: 'Our mission' },
  mission_text: {
    kk: 'Әрбір баланың құқығы бар деп сенеміз: дамуға, білімге, сыйластыққа, дербестікке және лайықты болашаққа. Біздің мақсатымыз — даму ерекшеліктері бар балалардың өз әлеуетін ашуына және отбасыларының кәсіби қолдау алуына мүмкіндік беретін орта жасау.',
    ru: 'Мы верим, что каждый ребёнок имеет право: на развитие, образование, уважение, самостоятельность, и достойное будущее. Наша задача — создавать среду, где дети с особенностями развития могут раскрывать свой потенциал, а семьи получать профессиональную поддержку.',
    en: 'We believe every child has the right to: development, education, respect, independence, and a dignified future. Our goal is to create an environment where children with developmental differences can reach their potential and families can receive professional support.'
  },
  news_eyebrow:   { kk: 'Жаңалықтар', ru: 'Обновления', en: 'Updates' },
  news_title:     { kk: 'Соңғы жаңалықтар', ru: 'Последние новости', en: 'Latest news' },
  news_sub: {
    kk: 'Біздің орталықтардан қысқа хабарламалар — бағдарламалар, жетістіктер және артындағы адамдар туралы.',
    ru: 'Короткие заметки из наших центров — о программах, открытиях и людях, которые за этим стоят.',
    en: 'Short notes from our centres — about programmes, discoveries, and the people behind them.'
  },
  news1_date:  { kk: '2 маусым', ru: '2 июня', en: 'June 2' },
  news1_title: { kk: '№3 орталықта жаңа сенсорлық бөлме ашылды', ru: 'В центре №3 открылась новая сенсорная комната', en: 'New sensory room opens at centre #3' },
  news1_text:  { kk: 'Эрготерапевттерімізбен бірге тыныш ортаны қажет ететін балаларға арналған тынық кеңістік.', ru: 'Тихое пространство с минимумом раздражителей, разработанное вместе с нашими эрготерапевтами для детей, которым нужна спокойная среда.', en: 'A low-stimulus space designed with our occupational therapists for children who need a calm environment.' },
  news1_link:  { kk: 'Толығырақ →', ru: 'Подробнее →', en: 'Read more →' },
  news2_date:  { kk: '24 мамыр', ru: '24 мая', en: 'May 24' },
  news2_title: { kk: 'Жазғы интенсивті бағдарлама: жазылу ашық', ru: 'Летняя интенсивная программа: открыта запись', en: 'Summer intensive programme: enrolment open' },
  news2_text:  { kk: '4–10 жас аралығындағы балаларға арналған логопедия, қозғалыс және топтық ойындарды біріктіретін екі апталық таңертеңгі сабақтар.', ru: 'Двухнедельные утренние занятия, объединяющие логопедию, движение и групповые игры для детей 4–10 лет.', en: 'Two-week morning sessions combining speech therapy, movement and group play for children aged 4–10.' },
  news2_link:  { kk: 'Толығырақ →', ru: 'Подробнее →', en: 'Read more →' },
  news3_date:  { kk: '11 мамыр', ru: '11 мая', en: 'May 11' },
  news3_title: { kk: 'Волонтерлерге арналған тренинг: 18 жаңа көмекші', ru: 'Тренинг для волонтёров: 18 новых помощников', en: 'Volunteer training: 18 new helpers' },
  news3_text:  { kk: 'Отбасылармен бірінші байланыс, шекаралар және қолдаудың күнделікті ережелері туралы екі күндік курс.', ru: 'Двухдневный курс о первом контакте с семьями, границах и повседневных правилах поддержки.', en: 'A two-day course on first contact with families, boundaries and everyday support practices.' },
  news3_link:  { kk: 'Толығырақ →', ru: 'Подробнее →', en: 'Read more →' },
  news4_date:  { kk: '29 сәуір', ru: '29 апреля', en: 'April 29' },
  news4_title: { kk: 'Қалалық балалар ауруханасымен серіктестік', ru: 'Партнёрство с городской детской больницей', en: 'Partnership with city children\'s hospital' },
  news4_text:  { kk: 'Отбасылар медициналық және дамытушы көмек арасында кешіктірусіз өте алуы үшін ортақ жолдама жолы.', ru: 'Общая линия направлений, чтобы семьи могли переходить между медицинской и развивающей помощью без задержек.', en: 'A shared referral pathway so families can move between medical and developmental support without delays.' },
  news4_link:  { kk: 'Толығырақ →', ru: 'Подробнее →', en: 'Read more →' },

  /* ─── КАРТА / MAP ─────────────────────────────────────── */
  map_eyebrow:  { kk: 'Біз қайда орналасқанбыз', ru: 'Где мы находимся', en: 'Where we are' },
  map_title:    { kk: 'Картадағы біздің филиалдар', ru: 'Наши филиалы на карте', en: 'Our branches on the map' },

  /* ─── FAB / СВЯЗЬ ─────────────────────────────────────── */
  fab_call:     { kk: 'Қоңырау шалу', ru: 'Позвонить', en: 'Call us' },
  fab_whatsapp: { kk: 'WhatsApp', ru: 'WhatsApp', en: 'WhatsApp' },

  centres_eyebrow: { kk: 'Біздің орталықтар', ru: 'Наши центры', en: 'Our centres' },
  centres_title: { kk: 'Бүгін қор құрылымында 4 орталық жұмыс істейді', ru: 'Сегодня в структуре фонда работают 4 центра', en: 'Today the foundation runs 4 centres' },
  centres_sub: { kk: '200-ден астам бала тұрақты терапиялық және коррекциялық көмек алады.', ru: 'Более 200 детей получают регулярную терапевтическую и коррекционную помощь.', en: 'More than 200 children receive regular therapeutic and correctional support.' },

  c1_name: { kk: 'Jas Urpaq Kids', ru: 'Jas Urpaq Kids', en: 'Jas Urpaq Kids' },
  c1_desc: { kk: 'Ерте қолдау және даму орталығы', ru: 'Центр ранней поддержки и развития', en: 'Early support and development centre' },
  c2_name: { kk: 'Eventum Junior', ru: 'Eventum Junior', en: 'Eventum Junior' },
  c2_desc: { kk: 'Академиялық дағдылар және еңбек терапиясы', ru: 'Академические навыки и трудотерапия', en: 'Academic skills and occupational therapy' },
  c3_name: { kk: 'Group', ru: 'Group', en: 'Group' },
  c3_desc: { kk: 'Өзіндік өмір дағдыларын қалыптастыру', ru: 'Формирование навыков самостоятельной жизни', en: 'Building independent living skills' },
  c4_name: { kk: 'EVENTUM', ru: 'EVENTUM', en: 'EVENTUM' },
  c4_desc: { kk: 'Жеке сабақтар: АВА, Логопед, Сенсорлық интеграция, Нейропсихолог', ru: 'Индивидуальные занятия: АВА, Логопед, Сенсорная интеграция, Нейропсихолог', en: 'Individual sessions: ABA, Speech Therapy, Sensory Integration, Neuropsychology' },

  staff_text: {
    kk: 'Орталықтарда жұмыс істейді: ABA-мамандары, нейропсихологтар, логопедтер, сенсорлық интеграция мамандары, мінез-құлық терапевттері, дербестік дағдыларын дамыту мамандары.',
    ru: 'В центрах работают: ABA-специалисты, нейропсихологи, логопеды, специалисты сенсорной интеграции, поведенческие терапевты, специалисты по развитию навыков самостоятельности.',
    en: 'Our centres employ: ABA specialists, neuropsychologists, speech therapists, sensory integration specialists, behavioural therapists, and independent living skills specialists.'
  },

  prog_eyebrow: { kk: 'Жұмыс бағыттары', ru: 'Направления работы', en: 'Areas of work' },
  prog_title:   { kk: 'Біздің бағдарламалар', ru: 'Наши программы', en: 'Our programmes' },

  p1_name: { kk: 'ABA-терапия', ru: 'ABA-терапия', en: 'ABA therapy' },
  p1_desc: { kk: 'Қолданбалы мінез-құлық талдауы негізінде коммуникацияны, мінез-құлық дағдыларын және әлеуметтік бейімделуді дамыту.', ru: 'Развитие коммуникации, навыков поведения и социальной адаптации на основе прикладного анализа поведения.', en: 'Developing communication, behavioural skills and social adaptation through applied behaviour analysis.' },
  p2_name: { kk: 'Сенсорлық интеграция', ru: 'Сенсорная интеграция', en: 'Sensory integration' },
  p2_desc: { kk: 'Балаларға сенсорлық тітіркендіргіштерді өңдеуге және қабылдауды реттеуді жақсартуға көмек.', ru: 'Помощь детям в обработке сенсорных стимулов и улучшении регуляции восприятия.', en: 'Helping children process sensory stimuli and improve perceptual regulation.' },
  p3_name: { kk: 'Логопедия және коммуникация', ru: 'Логопедия и коммуникация', en: 'Speech therapy & communication' },
  p3_desc: { kk: 'Сөйлеуді, балама коммуникация әдістерін және тілдік дағдыларды дамыту.', ru: 'Развитие речи, альтернативных методов коммуникации и языковых навыков.', en: 'Developing speech, alternative communication methods and language skills.' },
  p4_name: { kk: 'Өзіндік өмірге дайындау', ru: 'Подготовка к самостоятельной жизни', en: 'Independent living preparation' },
  p4_desc: { kk: 'Тұрмыстық дағдыларды, өзіне-өзі қызмет етуді және қоғамда өмір сүру дағдыларын қалыптастыру.', ru: 'Формирование бытовых навыков, самообслуживания и навыков для жизни в обществе.', en: 'Building household skills, self-care and skills for life in the community.' },
  p5_name: { kk: 'Отбасымен жұмыс', ru: 'Работа с семьёй', en: 'Family work' },
  p5_desc: { kk: 'Біртұтас дамытушы орта жасау үшін ата-аналарға кеңес беру, қолдау және оқыту.', ru: 'Консультации, поддержка и обучение родителей для создания единой развивающей среды.', en: 'Consultations, support and training for parents to build a unified developmental environment.' },

  intern_eyebrow: { kk: 'Халықаралық тағылымдамалар мен оқыту', ru: 'Международные стажировки и обучение', en: 'International placements & training' },
  intern_text: {
    kk: 'Орталықтарымыздың базасында өтеді: практикалық тағылымдамалар, оқу бағдарламалары, супервизиялар, мамандарға арналған халықаралық тренингтер. Біз тек теорияны ғана емес, орталықтың нақты ортасында балалармен практикалық жұмысты үйретеміз.',
    ru: 'На базе наших центров проходят: практические стажировки, обучающие программы, супервизии, международные тренинги для специалистов. Мы обучаем не только теории, но и практической работе с детьми в реальной среде центра.',
    en: 'Our centres host: practical internships, training programmes, supervisions, and international workshops for specialists. We teach not only theory but practical work with children in a real centre environment.'
  },
  intern_who_label: { kk: 'Бағдарламалар сәйкес:', ru: 'Программы подойдут:', en: 'Programmes suit:' },
  intern_who_list: {
    kk: 'жас мамандарға, педагогтарға, психологтарға, ABA-терапистеріне, студенттерге, халықаралық волонтерлерге.',
    ru: 'начинающим специалистам, педагогам, психологам, ABA-терапистам, студентам, международным волонтёрам.',
    en: 'early-career specialists, educators, psychologists, ABA therapists, students, and international volunteers.'
  },

  insta_open: { kk: 'Instagram-да ашу →', ru: 'Открыть в Instagram →', en: 'Open in Instagram →' },
  insta_post:  { kk: 'Жазба', ru: 'Пост', en: 'Post' },
  donors_label: { kk: 'Демеушілер', ru: 'Донаторы', en: 'Donors' },

  faq_eyebrow: { kk: 'Жиі қойылатын сұрақтар', ru: 'Частые вопросы', en: 'Frequently asked questions' },
  faq_title:   { kk: 'Сұрақтар мен жауаптар', ru: 'Вопросы и ответы', en: 'Questions & answers' },

  faq1_q: { kk: 'Баланы қалай жазуға болады?', ru: 'Как записать ребёнка?', en: 'How do I enrol my child?' },
  faq1_a: { kk: '4 орталықтың кез-келгеніне қоңырау шалыңыз немесе қысқа кіріспе кездесуге келіңіз. Маман балаңыз туралы сізбен сөйлесіп, бірінші бағдарламаны ұсынады — ол үшін диагноз немесе дәрігер жолдамасы қажет емес.', ru: 'Позвоните или приходите в любой из 4 центров на короткую вводную встречу. Специалист поговорит с вами о ребёнке и предложит первую программу — диагноз или направление врача для этого не требуются.', en: 'Call or visit any of our 4 centres for a short introductory meeting. A specialist will talk with you about your child and suggest a first programme — no diagnosis or doctor\'s referral needed.' },
  faq2_q: { kk: 'Шектеулі бюджеті бар отбасыларға қолдау бар ма?', ru: 'Есть ли поддержка для семей с ограниченным бюджетом?', en: 'Is support available for families with a limited budget?' },
  faq2_a: { kk: 'Иә. Әрбір қайырмалдықтың бір бөлігі мұқтаж отбасылар үшін сабақтарды толық немесе ішінара жабатын стипендиялар қорына бағытталады. Шарттарды орталық координаторынан анықтаңыз.', ru: 'Да. Часть каждого пожертвования направляется в фонд стипендий, который полностью или частично покрывает занятия для нуждающихся семей. Уточните условия у координатора центра.', en: 'Yes. A portion of every donation goes to a scholarship fund that fully or partially covers sessions for families in need. Ask a centre coordinator for details.' },
  faq3_q: { kk: 'Қандай жас топтарымен жұмыс істейсіздер?', ru: 'С какими возрастными группами вы работаете?', en: 'What age groups do you work with?' },
  faq3_a: { kk: 'Біздің бағдарламалар төрт топқа бөлінген — Kids, Junior, Jas Urpaq Group және Eventum — ерте балалықтан жасөспірімдік жасқа дейін, барлық жас үшін сыртқы іс-шараларға қоса. Толығырақ — «Біз туралы» бетінде.', ru: 'Наши программы разделены на четыре группы — Kids, Junior, Jas Urpaq Group и Eventum — от раннего детства до подросткового возраста, плюс выездные мероприятия для всех возрастов. Подробнее — на странице «О нас».', en: 'Our programmes are divided into four groups — Kids, Junior, Jas Urpaq Group and Eventum — from early childhood to adolescence, plus off-site events for all ages. More details on the About us page.' },
  faq4_q: { kk: 'Волонтер немесе маман болу үшін не істеу керек?', ru: 'Как стать волонтёром или специалистом?', en: 'How do I become a volunteer or specialist?' },
  faq4_a: { kk: 'Біз тұрақты түрде волонтерлерді тартамыз және жыл бойы лицензиясы бар мамандарды іздейміз. Кез-келген орталыққа хабарласыңыз, ал қазіргі қызметкерлер «Қызметкерлерге» бетіне кіре алады.', ru: 'Мы регулярно набираем волонтёров и круглый год ищем лицензированных специалистов. Обратитесь в любой центр, а действующие сотрудники могут войти на странице «Для сотрудников».', en: 'We regularly recruit volunteers and look for licensed specialists year-round. Contact any centre; current staff can log in on the For staff page.' },

  footer_help:      { kk: 'Көмек алу', ru: 'Получить помощь', en: 'Get help' },
  footer_training:  { kk: 'Оқуға өту', ru: 'Пройти обучение', en: 'Take training' },
  footer_donate:    { kk: 'Қорды қолдау', ru: 'Поддержать фонд', en: 'Support the fund' },
  footer_volunteer: { kk: 'Волонтер болу', ru: 'Стать волонтёром', en: 'Become a volunteer' },
  footer_contact:   { kk: 'Байланысу', ru: 'Связаться с нами', en: 'Contact us' },

  /* modals */
  modal_donate_title: { kk: '«Jas Urpaq» орталығын қолдау', ru: 'Поддержать центр «Jas Urpaq»', en: 'Support Jas Urpaq centre' },
  modal_donate_sub:   { kk: 'Қайырмалдығыңыз не үшін жұмсалатынын таңдап, төменде карта деректерін енгізіңіз.', ru: 'Выберите, на что пойдёт ваше пожертвование, и укажите данные карты ниже.', en: 'Choose where your donation goes and enter your card details below.' },
  modal_donate_want:  { kk: 'Мен қолдағым келеді', ru: 'Я хочу поддержать', en: 'I want to support' },
  donate_r_general:   { kk: 'Жалпы қор', ru: 'Общий фонд', en: 'General fund' },
  donate_r_sensory:   { kk: 'Сенсорлық бөлме жабдықтары', ru: 'Оборудование сенсорной комнаты', en: 'Sensory room equipment' },
  donate_r_scholar:   { kk: 'Мұқтаж отбасыларға стипендия', ru: 'Стипендия для нуждающихся семей', en: 'Scholarship for families in need' },
  donate_r_training:  { kk: 'Мамандарды оқыту бағдарламасы', ru: 'Программа обучения специалистов', en: 'Specialist training programme' },
  modal_pay_label:    { kk: 'Төлем деректері', ru: 'Данные платежа', en: 'Payment details' },
  card_number_lbl:    { kk: 'Карта нөмірі', ru: 'Номер карты', en: 'Card number' },
  card_expiry_lbl:    { kk: 'Жарамдылық мерзімі (АА/ЖЖ)', ru: 'Срок действия (MM/YY)', en: 'Expiry date (MM/YY)' },
  card_cvv_lbl:       { kk: 'CVV', ru: 'CVV', en: 'CVV' },
  card_name_lbl:      { kk: 'Карта иесінің аты', ru: 'Имя держателя карты', en: 'Cardholder name' },
  card_name_ph:       { kk: 'Картада жазылғандай', ru: 'Как указано на карте', en: 'As shown on card' },
  donate_btn:         { kk: 'Қайырмалдықты растау', ru: 'Подтвердить пожертвование', en: 'Confirm donation' },
  modal_fineprint:    { kk: 'Бұл демо-форма — нақты төлем жасалмайды.', ru: 'Это демо-форма — реальный платёж не выполняется.', en: 'This is a demo form — no real payment is processed.' },
  donate_alert:       { kk: 'Рахмет — сіздің қайырмалдығыңыз тіркелді. (Бұл демо-форма, нақты есептен шығару жасалмады.)', ru: 'Спасибо — ваше пожертвование зафиксировано. (Это демо-форма, реальное списание не производилось.)', en: 'Thank you — your donation has been recorded. (This is a demo form; no real charge was made.)' },

  modal_help_title:  { kk: 'Көмек алу', ru: 'Получить помощь', en: 'Get help' },
  modal_help_sub:    { kk: 'Байланысыңызды қалдырыңыз — жақын арада хабарласамыз.', ru: 'Оставьте контакты — мы свяжемся с вами в ближайшее время.', en: 'Leave your contact — we will get in touch soon.' },
  field_name_lbl:    { kk: 'Аты', ru: 'Имя', en: 'Name' },
  field_name_ph:     { kk: 'Атыңыз', ru: 'Ваше имя', en: 'Your name' },
  field_phone_lbl:   { kk: 'Телефон', ru: 'Телефон', en: 'Phone' },
  field_phone_ph:    { kk: '+7 (___) ___-__-__', ru: '+7 (___) ___-__-__', en: '+7 (___) ___-__-__' },
  send_btn:          { kk: 'Өтінімді жіберу', ru: 'Отправить заявку', en: 'Submit request' },
  sent_alert:        { kk: 'Өтінім жіберілді! Біз сізбен хабарласамыз.', ru: 'Заявка отправлена! Мы свяжемся с вами.', en: 'Request sent! We will be in touch.' },

  modal_train_title:  { kk: 'Оқуға өту', ru: 'Пройти обучение', en: 'Take training' },
  modal_train_sub:    { kk: 'Форманы толтырыңыз — сәйкес бағдарламаны таңдаймыз.', ru: 'Заполните форму — мы подберём подходящую программу.', en: 'Fill in the form — we will find the right programme for you.' },
  field_email_lbl:    { kk: 'Email', ru: 'Email', en: 'Email' },
  field_email_ph:     { kk: 'example@mail.com', ru: 'example@mail.com', en: 'example@mail.com' },
  field_spec_lbl:     { kk: 'Мамандану', ru: 'Специализация', en: 'Specialisation' },
  field_spec_ph:      { kk: 'Педагог, психолог, ABA-терапист…', ru: 'Педагог, психолог, ABA-терапист…', en: 'Educator, psychologist, ABA therapist…' },
  train_btn:          { kk: 'Өтінімді жіберу', ru: 'Отправить заявку', en: 'Submit request' },
  train_alert:        { kk: 'Оқуға өтінім жіберілді!', ru: 'Заявка на обучение отправлена!', en: 'Training request submitted!' },

  volunteer_alert: { kk: 'Волонтерлік бөлімі — жуырда!', ru: 'Раздел волонтёрства — скоро!', en: 'Volunteering section — coming soon!' },
  contact_alert:   { kk: 'Бізбен байланысыңыз: info@urpaq.kz', ru: 'Свяжитесь с нами: info@urpaq.kz', en: 'Contact us: info@urpaq.kz' },

  /* ─── SPECIALISTS ─────────────────────────────────────── */
  spec_eyebrow: { kk: 'Біздің команда', ru: 'Наша команда', en: 'Our team' },
  spec_h1: { kk: 'Әрбір сабақты өткізетін мамандар.', ru: 'Специалисты, которые проводят каждое занятие.', en: 'The specialists who lead every session.' },
  spec_sub: { kk: 'Психологтар, терапевттер мен педагогтар біздің 4 орталықта жұмыс істейді — әрқайсысы баланың дамуының өз бөлігіне жауапты.', ru: 'Психологи, терапевты и педагоги, работающие в наших 4 центрах — каждый отвечает за свою часть развития ребёнка.', en: 'Psychologists, therapists and educators working across our 4 centres — each responsible for their part of a child\'s development.' },
  spec_show_all: { kk: 'Барлығын көрсету', ru: 'Показать всех', en: 'Show all' },

  s1_role: { kk: 'Қор негізін қалаушы', ru: 'Основатель фонда', en: 'Founder of the foundation' },
  s1_name: { kk: 'Ким Татьяна Львовна', ru: 'Ким Татьяна Львовна', en: 'Tatyana Kim' },
  s1_bio:  { kk: 'Urpaq Inclusive қоры мен Jas Urpaq және Eventum орталықтары желісінің негізін қалаушы. Даму ерекшеліктері бар балалар мен жасөспірімдерге, сондай-ақ отбасыларға жәрдем жүйесін құруға және инклюзивті қоғамды дамытуға бағытталған жобалардың жетекшісі.', ru: 'Основатель фонда Urpaq Inclusive и сети центров Jas Urpaq и Eventum. Руководитель проектов, направленных на создание системы помощи детям и подросткам с особенностями развития, поддержку семей и развитие инклюзивного общества.', en: 'Founder of Urpaq Inclusive foundation and the Jas Urpaq and Eventum centre network. Leads projects aimed at building support systems for children and teenagers with developmental differences, supporting families and advancing inclusive society.' },

  s2_role: { kk: 'Атқарушы директор', ru: 'Исполнительный директор', en: 'Executive Director' },
  s2_name: { kk: 'Кужахметова Нурлыгуль Еркиновна', ru: 'Кужахметова Нурлыгуль Еркиновна', en: 'Nurlygul Kuzhakhmetova' },
  s2_bio:  { kk: 'Jas Urpaq және Eventum орталықтары желісінің атқарушы директоры. Орталықтардың қызметін басқарады, маман командаларының жұмысын үйлестіреді, бағдарламаларды дамытады және балалар мен отбасыларға көрсетілетін көмек сапасын бақылайды.', ru: 'Исполнительный директор сети центров Jas Urpaq и Eventum. Руководит деятельностью центров, координирует работу команд специалистов, развитие программ и качество оказываемой помощи детям и семьям.', en: 'Executive Director of the Jas Urpaq and Eventum centre network. Oversees centre operations, coordinates specialist teams, programme development and the quality of support provided to children and families.' },

  s3_role: { kk: 'Даму жобаларының жетекшісі', ru: 'Руководитель проектов развития', en: 'Development Projects Manager' },
  s3_name: { kk: 'Жулкаева Асем Ерболовна', ru: 'Жулкаева Асем Ерболовна', en: 'Asem Zhulkayeva' },
  s3_bio:  { kk: 'Jas Urpaq және Eventum орталықтары желісінің даму жобаларының жетекшісі. Жаңа жұмыс бағыттарын енгізуге, білім беру және әлеуметтік бағдарламаларды дамытуға, сондай-ақ перспективалық жобаларды іске асыруға жауапты.', ru: 'Руководитель проектов развития сети центров Jas Urpaq и Eventum. Отвечает за внедрение новых направлений работы, развитие образовательных и социальных программ, а также реализацию перспективных проектов.', en: 'Development Projects Manager for the Jas Urpaq and Eventum network. Responsible for introducing new areas of work, developing educational and social programmes, and implementing strategic projects.' },

  s4_role: { kk: 'Ерте даму маманы', ru: 'Специалист по раннему развитию', en: 'Early Development Specialist' },
  s4_name: { kk: 'Хегай Алия Маликовна', ru: 'Хегай Алия Маликовна', en: 'Aliya Khegai' },
  s4_bio:  { kk: 'Даму ерекшеліктері бар балалардың ерте дамуы маманы. KIDS орталығын басқарады және баланың коррекциялық көмекке бейімделуінің алғашқы кезеңдерінде отбасыларға жол береді.', ru: 'Специалист по раннему развитию детей с особенностями развития. Руководит центром KIDS и сопровождает семьи на ранних этапах коррекционной помощи и адаптации ребёнка.', en: 'Specialist in early development of children with developmental differences. Leads the KIDS centre and supports families in the early stages of correctional help and child adaptation.' },

  s5_role: { kk: 'Сенсорлық интеграция кураторы', ru: 'Куратор сенсорной интеграции', en: 'Sensory Integration Curator' },
  s5_name: { kk: 'Шайхин Глеб Ермекович', ru: 'Шайхин Глеб Ермекович', en: 'Gleb Shaikhin' },
  s5_bio:  { kk: 'Сенсорлық интеграция бағытының кураторы. Даму ерекшеліктері бар балалардың сенсорлық реттелуін, моторлық дағдыларын және бейімделуін дамыту маманы.', ru: 'Куратор направления сенсорной интеграции. Специалист по развитию сенсорной регуляции, моторных навыков и адаптации детей с особенностями развития.', en: 'Curator of sensory integration. Specialist in developing sensory regulation, motor skills and adaptation in children with developmental differences.' },

  s6_role: { kk: 'Нейропсихолог', ru: 'Нейропсихолог', en: 'Neuropsychologist' },
  s6_name: { kk: 'Ким Натали Вячеславовна', ru: 'Ким Натали Вячеславовна', en: 'Natali Kim' },
  s6_bio:  { kk: 'Нейропсихолог. Танымдық функциялардың, зейіннің, жадтың, эмоционалдық реттелудің дамуы және даму ерекшеліктері бар балаларды сүйемелдеу маманы.', ru: 'Нейропсихолог. Специалист по развитию когнитивных функций, внимания, памяти, эмоциональной регуляции и сопровождению детей с особенностями развития.', en: 'Neuropsychologist. Specialist in developing cognitive functions, attention, memory, emotional regulation and supporting children with developmental differences.' },

  s7_role: { kk: 'Мінез-құлық терапиясы кураторы', ru: 'Куратор поведенческой терапии', en: 'Behavioural Therapy Curator' },
  s7_name: { kk: 'Бурушева Акмарал Талгатовна', ru: 'Бурушева Акмарал Талгатовна', en: 'Akmaral Burusheva' },
  s7_bio:  { kk: 'Junior орталығының мінез-құлық терапиясы кураторы. Даму ерекшеліктері бар балалар мен жасөспірімдердің дербестік дағдыларын және әлеуметтік бейімделуін дамыту маманы.', ru: 'Куратор поведенческой терапии центра Junior. Специалист по развитию навыков самостоятельности, социальной адаптации и сопровождению детей и подростков с особенностями развития.', en: 'Curator of behavioural therapy at Junior centre. Specialist in developing independence skills, social adaptation and supporting children and teenagers with developmental differences.' },

  s8_role: { kk: 'Логопедиялық бағдарламалар кураторы', ru: 'Куратор логопедических программ', en: 'Speech Therapy Programmes Curator' },
  s8_name: { kk: 'Аветикова Алена Ильинична', ru: 'Аветикова Алена Ильинична', en: 'Alena Avetikova' },
  s8_bio:  { kk: 'Логопедиялық бағдарламалар кураторы. Сөйлеу мен коммуникацияны дамыту және сөйлеу-коммуникативтік қиыншылықтары бар балаларды сүйемелдеу маманы.', ru: 'Куратор логопедических программ. Специалист по развитию речи, коммуникации и сопровождению детей с речевыми и коммуникативными трудностями.', en: 'Curator of speech therapy programmes. Specialist in developing speech, communication and supporting children with speech and communication difficulties.' },

  s9_role: { kk: 'Жеке сабақтар кураторы', ru: 'Куратор индивидуальных занятий', en: 'Individual Sessions Curator' },
  s9_name: { kk: 'Адамович Анастасия Анатольевна', ru: 'Адамович Анастасия Анатольевна', en: 'Anastasiya Adamovich' },
  s9_bio:  { kk: 'Eventum орталығының жеке сабақтар кураторы. Қолданбалы мінез-құлық талдауы және аса маңызды өмірлік дағдыларды дамытудың жетекші маманы.', ru: 'Куратор индивидуальных занятий центра Eventum. Ведущий специалист по прикладному анализу поведения и развитию жизненно важных навыков.', en: 'Curator of individual sessions at Eventum centre. Lead specialist in applied behaviour analysis and developing vital life skills.' },

  s10_role: { kk: 'АДК және сенсорлық интеграция кураторы', ru: 'Куратор АФК и сенсорной интеграции', en: 'Adaptive PE & Sensory Integration Curator' },
  s10_name: { kk: 'Ломако Марина Вячеславовна', ru: 'Ломако Марина Вячеславовна', en: 'Marina Lomako' },
  s10_bio:  { kk: 'Jas Urpaq және Eventum орталықтарының бейімделген дене тәрбиесі (БДТ) бағытының кураторы. Сенсорлық интеграция маманы.', ru: 'Куратор направления адаптивной физической культуры (АФК) центров Jas Urpaq и Eventum. Специалист по сенсорной интеграции.', en: 'Curator of adaptive physical education at Jas Urpaq and Eventum centres. Sensory integration specialist.' },

  spec_footer_copy: { kk: '© 2026 «Jas Urpaq» орталығы. Барлық құқықтар қорғалған.', ru: '© 2026 Центр «Jas Urpaq». Все права защищены.', en: '© 2026 Jas Urpaq Centre. All rights reserved.' },
  spec_footer_sub:  { kk: '4 орталық · коммерциялық емес ұйым', ru: '4 центра · некоммерческая организация', en: '4 centres · non-profit organisation' },

  /* ─── ABOUT US ─────────────────────────────────────────── */
  about_eyebrow: { kk: 'Біз туралы', ru: 'О нас', en: 'About us' },
  about_h1: { kk: 'Балалар мен отбасылармен жұмыстың он жеті жылы.', ru: 'Семнадцать лет работы с детьми и семьями.', en: 'Seventeen years working with children and families.' },
  about_sub: {
    kk: '«Jas Urpaq» орталығы — аймақтағы балалар дамуымен айналысатын ең көне ұйымдардың бірі. Біз 4 орталықта жұмыс жасаймыз, олардың әрқайсысында терапия, оқыту және отбасылық қолдау бір шаңырақ астында біріктірілген; ауруханалар, мектептер мен жергілікті билік органдары бізді жолдама беруге болатын сенімді серіктес ретінде таниды.',
    ru: 'Центр «Jas Urpaq» — одна из самых давних организаций в регионе, занимающихся развитием детей. Мы работаем в 4 центрах, в каждом из которых терапия, обучение и поддержка семьи объединены под одной крышей, и нам доверяют больницы, школы и местные органы власти как надёжному партнёру по направлению пациентов.',
    en: 'Jas Urpaq Centre is one of the longest-established child development organisations in the region. We operate 4 centres, each combining therapy, education and family support under one roof, and are trusted by hospitals, schools and local authorities as a reliable referral partner.'
  },

  stat1_num:   { kk: '17', ru: '17', en: '17' },
  stat1_label: { kk: 'Жыл жұмыс', ru: 'Лет работы', en: 'Years active' },
  stat2_num:   { kk: '4', ru: '4', en: '4' },
  stat2_label: { kk: 'Аймақтағы орталық', ru: 'Центра в регионе', en: 'Centres in the region' },
  stat3_num:   { kk: '40+', ru: '40+', en: '40+' },
  stat3_label: { kk: 'Штаттағы маман', ru: 'Специалистов в штате', en: 'Specialists on staff' },
  stat4_num:   { kk: '2 300+', ru: '2 300+', en: '2,300+' },
  stat4_label: { kk: 'Бала қолдау алды', ru: 'Детей получили поддержку', en: 'Children supported' },

  groups_eyebrow: { kk: 'Жасқа қарай бағдарламалар', ru: 'Программы по возрасту', en: 'Programmes by age' },
  groups_title:   { kk: 'Төрт топ, бір тәсіл', ru: 'Четыре группы, один подход', en: 'Four groups, one approach' },
  groups_sub: {
    kk: 'Әрбір бала өзінің жасы мен қажеттіліктеріне сәйкес топқа түседі және өскен сайын топтар арасында ауыса алады.',
    ru: 'Каждый ребёнок попадает в группу, подходящую его возрасту и потребностям, и может переходить между группами по мере роста.',
    en: 'Every child is placed in a group suited to their age and needs, and can move between groups as they grow.'
  },

  g1_age:  { kk: 'Жас 3–6', ru: 'Возраст 3–6', en: 'Ages 3–6' },
  g1_name: { kk: 'Jas Urpaq Kids', ru: 'Jas Urpaq Kids', en: 'Jas Urpaq Kids' },
  g1_desc: { kk: 'Сенсорлық ойын, сөйлеу негіздері және алғашқы қарым-қатынас дағдылары арқылы ерте даму — ата-анамен бірге шағын топтарда.', ru: 'Раннее развитие через сенсорную игру, основы речи и первые навыки общения — в небольших группах, рядом с родителем.', en: 'Early development through sensory play, speech foundations and first communication skills — in small groups, alongside a parent.' },

  g2_age:  { kk: 'Жас 7–10', ru: 'Возраст 7–10', en: 'Ages 7–10' },
  g2_name: { kk: 'Eventum Junior', ru: 'Eventum Junior', en: 'Eventum Junior' },
  g2_desc: { kk: 'Мектепке дайындық, құрылымдалған топтық терапия және бастауыш мектептің алғашқы жылдарының жүктемесін ескере отырып, құрдастарымен бағытталған ойын.', ru: 'Подготовка к школе, структурированная групповая терапия и направляемая игра со сверстниками — с учётом нагрузки первых школьных лет.', en: 'School preparation, structured group therapy and guided peer play — accounting for the demands of the first school years.' },

  g3_age:  { kk: 'Жас 11–14', ru: 'Возраст 11–14', en: 'Ages 11–14' },
  g3_name: { kk: 'Jas Urpaq Group', ru: 'Jas Urpaq Group', en: 'Jas Urpaq Group' },
  g3_desc: { kk: 'Оқу тәлімгерлігі, кеңес беру және ерте жасөспірімдік кезеңнің қысымы мен өзгерістері кезеңінде мінез-құлықты қолдау.', ru: 'Учебное наставничество, консультирование и поддержка поведения в период давления и перемен раннего подросткового возраста.', en: 'Academic mentoring, counselling and behavioural support during the pressures and changes of early adolescence.' },

  g4_age:  { kk: 'Кез келген жас', ru: 'Любой возраст', en: 'Any age' },
  g4_name: { kk: 'Eventum', ru: 'Eventum', en: 'Eventum' },
  g4_desc: { kk: 'Іс-шараларға негізделген форматымыз: маусымдық сапарлар, шеберхана-сабақтар және барлық топтарды кестеден тыс біріктіретін отбасылық күндер.', ru: 'Наш формат на основе мероприятий: сезонные выезды, мастер-классы и семейные дни, объединяющие все группы вне обычного расписания.', en: 'Our events-based format: seasonal trips, workshops and family days that bring all groups together outside the usual schedule.' },

  about_footer_copy: { kk: '© 2026 «Jas Urpaq» орталығы. Барлық құқықтар қорғалған.', ru: '© 2026 Центр «Jas Urpaq». Все права защищены.', en: '© 2026 Jas Urpaq Centre. All rights reserved.' },
  about_footer_sub:  { kk: '4 орталық · коммерциялық емес ұйым', ru: '4 центра · некоммерческая организация', en: '4 centres · non-profit organisation' }
};

/* ── утилита: получить текст ── */
function t(key) {
  var lang = getLang();
  var entry = TRANSLATIONS[key];
  if (!entry) return key;
  return entry[lang] || entry['ru'] || key;
}

/* ── читать / писать язык ── */
function getLang() {
  return localStorage.getItem('jas_lang') || 'ru';
}

function setLang(lang) {
  localStorage.setItem('jas_lang', lang);
  applyLang();
}

/* ── применить переводы по data-i18n ── */
function applyLang() {
  var lang = getLang();
  /* переключить активную кнопку */
  document.querySelectorAll('.lang-btn').forEach(function(btn) {
    btn.classList.toggle('active', btn.dataset.lang === lang);
  });
  /* обновить все элементы с data-i18n */
  document.querySelectorAll('[data-i18n]').forEach(function(el) {
    var key = el.dataset.i18n;
    var text = t(key);
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      el.placeholder = text;
    } else {
      el.textContent = text;
    }
  });
  /* атрибуты aria-label и placeholder через data-i18n-label */
  document.querySelectorAll('[data-i18n-ph]').forEach(function(el) {
    el.placeholder = t(el.dataset.i18nPh);
  });
  /* lang на html */
  document.documentElement.lang = lang;
}

/* ── рендер свитчера ── */
function renderLangSwitch() {
  var container = document.querySelector('.lang-switch');
  if (!container) return;
  var lang = getLang();
  [['kk','ҚАЗ'],['ru','РУС'],['en','ENG']].forEach(function(pair) {
    var btn = document.createElement('button');
    btn.className = 'lang-btn' + (pair[0] === lang ? ' active' : '');
    btn.dataset.lang = pair[0];
    btn.textContent = pair[1];
    btn.addEventListener('click', function() { setLang(pair[0]); });
    container.appendChild(btn);
  });
}

/* ── подсветка активного пункта навигации ── */
function markActiveNavLink() {
  var current = window.location.pathname.split('/').pop() || 'index.html';
  document.querySelectorAll('.header nav a, .nav-mobile a').forEach(function(link) {
    var href = link.getAttribute('href');
    if (!href) return;
    var linkFile = href.split('#')[0].split('/').pop();
    if (!linkFile || linkFile === 'enter.html') return;
    if (linkFile === current) {
      link.classList.add('nav-active');
    }
  });
}

/* ── счётчик-анимация для цифр статистики ── */
function formatStatNumber(value, lang) {
  var sep = (lang === 'en') ? ',' : ' ';
  return value.toString().replace(/\B(?=(\d{3})+(?!\d))/g, sep);
}

function animateStatNumber(el, target, suffix) {
  var duration = 1400;
  var start = null;

  function step(timestamp) {
    if (start === null) start = timestamp;
    var progress = Math.min((timestamp - start) / duration, 1);
    var eased = 1 - Math.pow(1 - progress, 3);
    var current = Math.round(eased * target);
    el.textContent = formatStatNumber(current, getLang()) + suffix;
    if (progress < 1) {
      requestAnimationFrame(step);
    } else {
      el.textContent = formatStatNumber(target, getLang()) + suffix;
    }
  }

  requestAnimationFrame(step);
}

function initStatCounters() {
  var nums = document.querySelectorAll('.about-stat .num');
  if (!nums.length) return;

  nums.forEach(function(el) {
    var raw = el.textContent.trim();
    var digits = raw.replace(/[^\d]/g, '');
    if (!digits) return;
    var target = parseInt(digits, 10);
    var suffix = raw.replace(/^[\d\s,]+/, '');
    el.dataset.statTarget = target;
    el.dataset.statSuffix = suffix;
  });

  if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    return;
  }

  var animated = new WeakSet();
  var observer = new IntersectionObserver(function(entries) {
    entries.forEach(function(entry) {
      if (entry.isIntersecting && !animated.has(entry.target)) {
        animated.add(entry.target);
        var target = parseInt(entry.target.dataset.statTarget, 10);
        var suffix = entry.target.dataset.statSuffix || '';
        animateStatNumber(entry.target, target, suffix);
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.3 });

  nums.forEach(function(el) {
    if (el.dataset.statTarget) observer.observe(el);
  });
}

/* ── анимация появления карточек при скролле ── */
function initScrollReveal() {
  var selectors = '.news-card, .group-card, .specialist-card, .about-stat';
  var items = document.querySelectorAll(selectors);
  if (!items.length) return;

  if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    items.forEach(function(el) { el.classList.add('is-visible'); });
    return;
  }

  items.forEach(function(el) { el.classList.add('reveal'); });

  var observer = new IntersectionObserver(function(entries) {
    entries.forEach(function(entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });

  items.forEach(function(el) { observer.observe(el); });
}

/* ── переход + плавный скролл к секции (например, FAQ) ──
   Сначала переходим на нужную страницу (если мы не на ней),
   и только после загрузки делаем smooth scroll к блоку —
   вместо мгновенного браузерного прыжка по якорю. */
function smoothScrollTo(id) {
  var target = document.getElementById(id);
  if (!target) return;
  target.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function initSmoothSectionLinks() {
  var current = window.location.pathname.split('/').pop() || 'index.html';

  document.querySelectorAll('[data-scroll-target]').forEach(function(link) {
    link.addEventListener('click', function(e) {
      var id = link.dataset.scrollTarget;
      var hrefFile = (link.getAttribute('href') || '').split('#')[0].split('/').pop() || 'index.html';

      if (hrefFile === current) {
        e.preventDefault();
        smoothScrollTo(id);
      } else {
        e.preventDefault();
        try { sessionStorage.setItem('jas_scroll_target', id); } catch (err) {}
        window.location.href = hrefFile;
      }
    });
  });

  /* если пришли с другой страницы с сохранённой целью — доскроллить после загрузки */
  var pendingId = null;
  try { pendingId = sessionStorage.getItem('jas_scroll_target'); } catch (err) {}
  if (pendingId) {
    try { sessionStorage.removeItem('jas_scroll_target'); } catch (err) {}
    window.requestAnimationFrame(function() {
      setTimeout(function() { smoothScrollTo(pendingId); }, 50);
    });
  }
}

/* ── инициализация ── */
document.addEventListener('DOMContentLoaded', function() {
  renderLangSwitch();
  applyLang();
  markActiveNavLink();
  initStatCounters();
  initScrollReveal();
  initSmoothSectionLinks();
});
