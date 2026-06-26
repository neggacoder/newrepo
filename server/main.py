import mysql.connector as cnr
import fastapi
import pydantic
from fastapi.middleware.cors import CORSMiddleware

app = fastapi.FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

db_config = {
    "host": "localhost",
    "user": "root",
    "password": "12233445",
    "database": "db"
}


@app.get("/donaters")
def GetDonaters():
    msg = "SELECT * FROM donaters"
    db = cnr.connect(**db_config)
    try:
        cursor = db.cursor()
        try:
            cursor.execute(msg)
            result = cursor.fetchall()
            return result
        finally:
            cursor.close()
    finally:
        db.close()


class donate(pydantic.BaseModel):
    name: str
    amount: int
    valute: str


@app.post("/donaters/add")
def AddDonaters(payload: donate):
    try:
        msg = "INSERT INTO donaters(name,amount,valute) VALUES (%s,%s,%s)"
        values = (payload.name, payload.amount, payload.valute)
        db = cnr.connect(**db_config)
        try:
            cursor = db.cursor()
            try:
                cursor.execute(msg, values)
                db.commit()
            finally:
                cursor.close()
        finally:
            db.close()
    except Exception as e:
        print(f"ERROR OCCURED: {e}")
        raise fastapi.HTTPException(status_code=500, detail="Database error")
