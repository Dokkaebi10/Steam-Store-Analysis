import json # parses .json files into Python dicts/lists
import os # reads environment variables from .env
import pandas as pd # for DataFrame manipulation and cleaning
from sqlalchemy import create_engine # for SQL/Python connection and writing to Postgres
from sqlalchemy import Text # for text columns in to_sql dtype mapping
from sqlalchemy.dialects.postgresql import JSONB # for JSONB columns in to_sql dtype mapping
from dotenv import load_dotenv # for loading .env file with DB credentials
 
load_dotenv()
 
# PostgreSQL Database connection
# Reads credentials from .env
engine = create_engine(
    f"postgresql://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}"
    f"@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
)
 
# Load json file
# 'with' is a context manager that ensures the file is properly closed after reading
# 'encoding="utf-8"' ensures we can read any special characters in the JSON
print("Reading JSON file...")
with open("data/games.json", encoding="utf-8") as f:
    raw = json.load(f)
print(f"Loaded {len(raw)} games from JSON")
 
# Flatten into a DataFrame: Converts the nested dictionary into a flat table (a DataFrame)
# raw is {"496350": {...}, "10": {...}}
# orient="index" treats each key as a row index (the appid)
df = pd.DataFrame.from_dict(raw, orient="index")
df.index.name = "appid"
# reset_index moves the appid from the index into a regular column, which we can then clean and cast
df.reset_index(inplace=True)
 
print(f"Columns found: {list(df.columns)}")
 
# Select only the columns we need
# copy() is used to avoid SettingWithCopyWarning when we later modify the DataFrame
df = df[[
    "appid", "name", "release_date",
    "price", "dlc_count", "detailed_description",
    "short_description", "windows", "mac", "linux",
    "metacritic_score", "achievements", "recommendations",
    "developers", "publishers", "categories",
    "positive", "negative", "estimated_owners", "average_playtime_forever",
    "median_playtime_forever", "peak_ccu", "tags"
]].copy()
 
# Clean and cast
# appid: must be a valid integer
# errors="coerce" converts invalid values to NaN, which we can then drop
df["appid"] = pd.to_numeric(df["appid"], errors="coerce")
df.dropna(subset=["appid"], inplace=True)
df["appid"] = df["appid"].astype(int)
 
# price: already in dollars — coerce bad values to null, and filter out negative prices and unrealistically high prices
df["price"] = pd.to_numeric(df["price"], errors="coerce")
df.loc[df["price"] < 0, "price"] = None
df.loc[df["price"] > 999, "price"] = None
 
# integer columns: fill nulls with 0
# Note: some of these may be better as nulls instead of zeros, but we'll keep it simple for now
int_cols = [
    "dlc_count", "metacritic_score",
    "achievements", "recommendations", "positive", "negative",
    "average_playtime_forever", "median_playtime_forever", "peak_ccu"
]
for col in int_cols:
    df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0).astype(int)
 
# booleans
for col in ["windows", "mac", "linux"]:
    df[col] = df[col].astype(bool)
 
# snapshot df before flattening list columns
# df_raw preserves the full tags/developers/publishers lists
# needed for the bridge table explosion below
df_raw = df.copy()
 
# developers/publishers are arrays like ["minori"] — grab first element
df["developer"] = df["developers"].apply(
    lambda x: x[0] if isinstance(x, list) and len(x) > 0 else None
)
df["publisher"] = df["publishers"].apply(
    lambda x: x[0] if isinstance(x, list) and len(x) > 0 else None
)
 
# Combine categories (full list) and tags (dict keys) into one deduplicated list
# Deduplication is case-insensitive; first-seen casing is preserved
def merge_genres_and_tags(row):
    genres = row["categories"] if isinstance(row["categories"], list) else []
    tag_keys = list(row["tags"].keys()) if isinstance(row["tags"], dict) else []
 
    seen = {}
    for item in genres + tag_keys:
        item = item.strip()
        if item and item.lower() not in seen:
            seen[item.lower()] = item  # keep first-seen casing
 
    return list(seen.values())
 
df["genres_and_tags"] = df.apply(merge_genres_and_tags, axis=1)
df.drop(columns=["categories"], inplace=True)
 
# remove junk rows: no name, test apps, zero engagement
df.dropna(subset=["name"], inplace=True)
df = df[~df["name"].str.contains("test|valve test", case=False, na=False)]
df = df[~(
    (df["peak_ccu"] == 0) &
    (df["positive"] == 0) &
    (df["negative"] == 0)
)]
 
print(f"Clean row count: {len(df)}")
 
# rename to final column names
df.rename(columns={
    "price":    "price_usd",
    "positive": "positive_reviews",
    "negative": "negative_reviews",
}, inplace=True)
 
# Ensure tags is always a dict before writing to JSONB
df["tags"] = df["tags"].apply(
    lambda x: x if isinstance(x, dict) else {}
)
 
# ── write games table ─────────────────────────────────────────────
print("Writing games table...")
df.to_sql("games", engine, if_exists="replace", index=False, dtype={
    "tags":            JSONB,
    "developers":      JSONB,
    "publishers":      JSONB,
    "genres_and_tags": JSONB,
})
print(f"  games: {len(df)} rows")
 
# ── build tags dimension + bridge table ───────────────────────────
print("Building tags tables...")
 
rows = []
for _, row in df_raw.iterrows():
    tags = row.get("tags", {})
 
    # Tags are a dict: {"Action": 1500, "Indie": 300, ...}
    if isinstance(tags, dict):
        for tag_name, vote_count in tags.items():
            tag_name = tag_name.strip()
            if tag_name:
                rows.append({
                    "appid": row["appid"],
                    "tag_name": tag_name,
                    "votes": int(vote_count) if vote_count else 0
                })
    # Fallback: sometimes tags may arrive as a pre-parsed string
    elif isinstance(tags, str):
        try:
            parsed = json.loads(tags)
            for tag_name, vote_count in parsed.items():
                rows.append({
                    "appid": row["appid"],
                    "tag_name": tag_name.strip(),
                    "votes": int(vote_count) if vote_count else 0
                })
        except (json.JSONDecodeError, AttributeError):
            pass
 
df_bridge = pd.DataFrame(rows)
 
if df_bridge.empty:
    sample = df_raw["tags"].dropna().head(5).tolist()
    raise ValueError(f"No tags parsed. Sample tags values: {sample}")
 
# unique tag names → tags dimension table
df_tags = pd.DataFrame(
    df_bridge["tag_name"].unique(), columns=["tag_name"]
)
df_tags.index.name = "tag_id"
df_tags.reset_index(inplace=True)
df_tags["tag_id"] = df_tags["tag_id"] + 1
 
df_tags.to_sql("tags", engine, if_exists="replace", index=False)
print(f"  tags: {len(df_tags)} rows")
 
# merge to get tag_id into bridge, keep only valid appids
df_bridge = df_bridge.merge(df_tags, on="tag_name")[["appid", "tag_id", "votes"]]
df_bridge.drop_duplicates(subset=["appid", "tag_id"], inplace=True)
valid = set(df["appid"].tolist())
df_bridge = df_bridge[df_bridge["appid"].isin(valid)]
 
df_bridge.to_sql("game_tags", engine, if_exists="replace", index=False)
print(f"  game_tags: {len(df_bridge)} rows")