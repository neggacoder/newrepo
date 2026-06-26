import mysql.connector as cnr

db_config = {
    "host": "localhost",
    "user": "root",
    "password": "12233445",
    "database": "db"
}

msg = "select * from donaters"

# 1. Открываем соединение
db = cnr.connect(**db_config)

try:
    # 2. Создаем курсор обычным способом (без with)
    cursor = db.cursor()
    try:
        # 3. Выполняем запрос
        cursor.execute(msg)
        print(cursor.fetchall())
    finally:
        # 4. Обязательно закрываем курсор
        cursor.close()
finally:
    # 5. Обязательно закрываем соединение
    db.close()
