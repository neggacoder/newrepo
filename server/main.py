import mysql.connector as cnr
import fastapi
import pydantic
app = fastapi.FastAPI()
from fastapi.middleware.cors import CORSMiddleware
app.add_middleware(
    CORSMiddleware,
    allow_origins = ['*'],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

db_config = {
    "host": "localhost",
    "user": "root",
    "password": "",
    "database": "db"
}

@app.get("/donaters")
def GetDonaters():
    msg = "SELECT * FROM donaters"
    with cnr.connect(**db_config) as db:
        with db.cursor() as cursor:
            cursor.execute(msg)
            list= cursor.fetchall()
            return list


class donate(pydantic.BaseModel):
    name   : str
    amount : int
    valute : str
@app.post("/donaters/add")
def AddDonaters(payload : donate)
    try:
        msg = "INSERT INTO donaters(name,amount,valute) VALUES (%s,%s,%s)"
        values = (payload.name,payload.amount,payload.valute)
        cursor.execute(msg,values)
    except:
        print("ERROR OCCURED")

