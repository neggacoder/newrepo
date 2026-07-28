"""
Генератор тест-документа для OCR (шаблон #20 «Первичный приём»).
Создаёт рядом test_20_visit.png — чёткое изображение бланка осмотра,
пригодное для распознавания tesseract (kaz+rus+eng).

Запуск:  python make_test_20_image.py
Файл затем загружается в расширении (OCR) для сквозного теста:
    картинка -> tesseract -> текст -> сервер [OCR] -> шаблон 20 -> steps
"""

import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "test_20_visit.png")
FONT = "C:/Windows/Fonts/arial.ttf"
FONT_BOLD = "C:/Windows/Fonts/arialbd.ttf"

LINES = [
    ("ПЕРВИЧНЫЙ ОСМОТР ПАЦИЕНТА", "h"),
    ("", "n"),
    ("ФИО: Жунусов Марат Бекович", "n"),
    ("ИИН: 870312300247", "n"),
    ("Дата рождения: 12.03.1987", "n"),
    ("Пол: мужской", "n"),
    ("Телефон: +7 (701) 234-56-78", "n"),
    ("Адрес проживания: г. Алматы, ул. Абая, д. 12, кв. 34", "n"),
    ("", "n"),
    ("Витальные показатели:", "b"),
    ("АД: 130/85 мм рт. ст.", "n"),
    ("Пульс: 78 уд/мин", "n"),
    ("Температура: 36.8 C", "n"),
    ("Рост: 176 см    Вес: 82 кг    SpO2: 97 %", "n"),
    ("", "n"),
    ("Жалобы: одышка при физической нагрузке, кашель", "n"),
    ("с мокротой по утрам, свистящее дыхание.", "n"),
    ("Анамнез заболевания: болен около 5 лет, ухудшение", "n"),
    ("в течение недели после переохлаждения, курит 20 лет.", "n"),
    ("", "n"),
    ("Диагноз: J44.1", "b"),
    ("Формулировка диагноза: Хроническая обструктивная", "n"),
    ("болезнь легких, обострение средней степени тяжести.", "n"),
    ("", "n"),
    ("Немедикаментозное лечение: отказ от курения,", "n"),
    ("дыхательная гимнастика, обильное теплое питье.", "n"),
    ("Рекомендации: контроль состояния через 7 дней,", "n"),
    ("при усилении одышки обращение немедленно.", "n"),
]

W, MARGIN, TOP = 960, 60, 50
LH = 46

f_norm = ImageFont.truetype(FONT, 30)
f_bold = ImageFont.truetype(FONT_BOLD, 30)
f_head = ImageFont.truetype(FONT_BOLD, 38)

H = TOP * 2 + LH * len(LINES)
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

y = TOP
for text, kind in LINES:
    if kind == "h":
        d.text((MARGIN, y), text, fill="black", font=f_head)
    elif kind == "b":
        d.text((MARGIN, y), text, fill="black", font=f_bold)
    else:
        d.text((MARGIN, y), text, fill="black", font=f_norm)
    y += LH

# тонкая рамка бланка
d.rectangle([20, 20, W - 20, H - 20], outline=(180, 180, 180), width=2)
img.save(OUT, "PNG")
print("saved:", OUT, img.size)
