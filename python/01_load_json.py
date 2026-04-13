import json, psycopg2

conn = psycopg2.connect("dbname=steam_dashboard user=postgres")
cur = conn.cursor()

with open("data/games.json", encoding="utf-8") as f:
    data = json.load(f)

cur.execute("INSERT INTO raw_steam_blob (data) VALUES (%s)", [json.dumps(data)])
conn.commit()