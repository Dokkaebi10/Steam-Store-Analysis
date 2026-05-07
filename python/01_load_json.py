import json # parses .json files into Python dicts/lists
import os # reads environment variables from .env
import pandas as pd # for DataFrame manipulation and cleaning
from sqlalchemy import create_engine, text # for SQL/Python connection and writing to Postgres
from sqlalchemy.dialects.postgresql import JSONB # for JSONB columns in to_sql dtype mapping
from dotenv import load_dotenv # for loading .env file with DB credentials
 
load_dotenv()

required = ["DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME"]
missing  = [k for k in required if not os.getenv(k)]
if missing:
    raise EnvironmentError(f"Missing required env vars: {missing}")

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
# estimated_owners is a wide range string so we'll drop it for now to keep things simpler, but it could be cleaned and included in the future if desired
# peak_ccu and metacritic_score are too variable and often zero, but we'll keep them for now as they can be useful for filtering out junk apps and analyzing engagement patterns
df = df[[
    "appid", "name", "release_date",
    "price", "dlc_count",
    "windows", "mac", "linux",
    "metacritic_score", "achievements", "recommendations",
    "developers", "publishers", "categories",
    "positive", "negative", "average_playtime_forever",
    "median_playtime_forever", "peak_ccu", "tags"
]].copy()
 
# Clean and cast
# appid: must be a valid integer
# errors="coerce" converts invalid values to NaN, which we can then drop
df["appid"] = pd.to_numeric(df["appid"], errors="coerce")
df.dropna(subset=["appid"], inplace=True)
df["appid"] = df["appid"].astype(int)
 
# price: already in dollars — coerce bad values to NaN
df["price"] = pd.to_numeric(df["price"], errors="coerce")
 
# integer columns: fill nulls with 0
# Note: some of these may be better as nulls (eg. Metacritic score) instead of zeros, but we'll keep it simple for now
# price is not filled with 0 because we want to distinguish between free games (price = 0) and games with missing/invalid price (price = null)
int_cols = [
    "dlc_count", "metacritic_score",
    "achievements", "recommendations", "positive", "negative",
    "average_playtime_forever", "median_playtime_forever", "peak_ccu"
]
for col in int_cols:
    df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0).astype(int)

for col in ["developers", "publishers"]:
    df[col] = df[col].apply(lambda x: x if isinstance(x, list) else [])
 
# booleans
for col in ["windows", "mac", "linux"]:
    df[col] = df[col].astype(bool)
 
# remove junk rows: no names, test apps, zero engagement
# ~ is bitwise NOT operator, used here to negate the condition (keep rows that do NOT match)
# na=False in str.contains ensures that if name is NaN, it won't match the regex and thus won't be dropped by this filter
# this is done in the python script to reduce the amount of junk data we write to Postgres, which can speed up the SQL cleaning steps later and reduce storage of clearly invalid entries
before = len(df)
df.dropna(subset=["name"], inplace=True)
df = df[~df["name"].str.contains("test|valve test", case=False, na=False)]
df = df[~(
    (df["peak_ccu"] == 0) &
    (df["positive"] == 0) &
    (df["negative"] == 0)
)]
 
print(f"Removed {before - len(df)} test/junk rows") # should be significantly less than the original count if junk rows were removed
 
# Combine categories (full list) and tags (dict keys) into one deduplicated list.
# Only strip whitespace — do NOT apply .title() here: it mangles acronyms like
# "RPG" → "Rpg" and "FPS" → "Fps". Steam tag names come from a controlled vocabulary so casing is already consistent.
def merge_genres_and_tags(row):
    genres = row["categories"] if isinstance(row["categories"], list) else [] # categories are already a list of strings
    tag_keys = list(row["tags"].keys()) if isinstance(row["tags"], dict) else [] # tags are a dict of {"tag_name": vote_count}, we want just the tag names
 
    seen = {} # to track seen items in a case-insensitive way, while preserving original casing
    for item in genres + tag_keys: # combine genres and tag names into one list
        item = item.strip() # strip whitespace for better deduplication
        if item and item.lower() not in seen: # check if we've already seen this item (case-insensitive)
            seen[item.lower()] = item  # store title-cased version
 
    return list(seen.values())
 
df["genres_and_tags"] = df.apply(merge_genres_and_tags, axis=1) # create new column by applying the merge function to each row
df.drop(columns=["categories"], inplace=True) # we no longer need the original categories column but keeping the tags column for the votes in the bridge table

# rename to final column names
# inplace=True modifies the DataFrame in place without needing to assign it back to df
df.rename(columns={
    "price":    "price_usd",
    "positive": "positive_reviews",
    "negative": "negative_reviews",
}, inplace=True)
 
# Ensure tags is always a dict before writing to JSONB
df["tags"] = df["tags"].apply(lambda x: x if isinstance(x, dict) else {})
 
# ── Bridge table construction (vectorized, replaces iterrows loop) ───────────
# Explode the tags dict for each game into one row per (appid, tag_name) pair.
# This is significantly faster than iterrows() on large datasets.
print("Building tags tables...")
 
# We first filter to rows where tags is a dict, then we convert the dict to a list of (tag_name, votes) tuples, and finally we explode that list into separate rows. 
# This way we can handle the tags in a vectorized manner without explicit Python loops.
mask = df["tags"].apply(lambda x: isinstance(x, dict))
df_tags_only = df.loc[mask, ["appid", "tags"]].copy()
 
df_tags_only["tags"] = df_tags_only["tags"].apply(lambda d: list(d.items()))
df_bridge = df_tags_only.explode("tags").dropna(subset=["tags"])
df_bridge = df_bridge[df_bridge["tags"].apply(lambda x: isinstance(x, tuple) and len(x) == 2)].copy()
df_bridge[["tag_name", "votes"]] = pd.DataFrame(
    df_bridge["tags"].tolist(), index=df_bridge.index
)
df_bridge = df_bridge[["appid", "tag_name", "votes"]].copy()
df_bridge["tag_name"] = df_bridge["tag_name"].str.strip()
df_bridge = df_bridge[df_bridge["tag_name"] != ""]
df_bridge["votes"] = pd.to_numeric(df_bridge["votes"], errors="coerce").fillna(0).astype(int)
df_bridge.drop_duplicates(subset=["appid", "tag_name"], inplace=True)

if df_bridge.empty:
    sample = df["tags"].dropna().head(5).tolist()
    raise ValueError(f"No tags parsed. Sample tags values: {sample}")
 
# Tags dimension table — sorted so tag_id assignments are stable across runs.
# Non-deterministic ordering (from .unique()) would reassign different IDs to the same tags each time the script runs.
# the index (which starts at 0) is promoted to a real column called tag_id, then + 1 shifts it to start at 1 instead of 0 (optional, but often better for IDs to start at 1) because some SQL tools and ORMs expect that convention
df_dim_tags = pd.DataFrame(
    sorted(df_bridge["tag_name"].unique()), columns=["tag_name"]
)
df_dim_tags.index.name = "tag_id"
df_dim_tags.reset_index(inplace=True)
df_dim_tags["tag_id"] = df_dim_tags["tag_id"] + 1

# Count distinct games per tag from the bridge table (before the merge adds tag_id)
tag_game_counts = df_bridge.groupby("tag_name")["appid"].nunique().rename("game_count")
df_dim_tags = df_dim_tags.merge(tag_game_counts, on="tag_name", how="left")
df_dim_tags["game_count"] = df_dim_tags["game_count"].fillna(0).astype(int)
 
# merge to get tag_id into bridge, keep only valid appids
# We merge the exploded tags DataFrame (df_bridge) with the tags dimension table (df_dim_tags) on the tag_name to get the corresponding tag_id for each tag_name
# drop_duplicates is used to ensure that if a game has the same tag multiple times (which shouldn't happen but we want to be safe), we only keep one row for that game-tag combination in the bridge table
df_bridge = df_bridge.merge(df_dim_tags, on="tag_name")[["appid", "tag_id", "votes"]]
df_bridge.drop_duplicates(subset=["appid", "tag_id"], inplace=True)

# Ensure all appids in the bridge table exist in the main games table to maintain referential integrity. 
# This is a safety check before writing to the database, since the SQL cleanup script will add FK constraints that would reject any invalid appids.
valid_appids = set(df["appid"])
df_bridge = df_bridge[df_bridge["appid"].isin(valid_appids)].copy()

# Write all three tables inside a single transaction
# If any write fails, all are rolled back — no partial state in the database.
# Note: if_exists="replace" drops and recreates each table, which also removes
# any indexes or constraints added in previous runs. Re-apply them via the SQL
# cleanup script after this script completes.
# chunksize=1000 and method="multi" optimize the insert performance by batching rows into multi-row INSERT statements.
# CASCADE drops any dependent views (v_kpi_*) created by views.sql.
# # Re-run views.sql and constraints.sql after any full reload.
try:
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE IF EXISTS game_tags CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS tags CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS games CASCADE"))

        df.to_sql("games", conn, if_exists="replace", index=False, chunksize=1000, method="multi", dtype={
            "tags":            JSONB,
            "developers":      JSONB,
            "publishers":      JSONB,
            "genres_and_tags": JSONB,
        })
        df_dim_tags.to_sql("tags", conn, if_exists="replace", index=False)
        df_bridge.to_sql("game_tags", conn, if_exists="replace", index=False)

    print(f"  games:     {len(df)} rows")
    print(f"  tags:      {len(df_dim_tags)} rows")
    print(f"  game_tags: {len(df_bridge)} rows")
    print("Done.")

except Exception as e:
    print(f"Write failed, transaction rolled back: {e}")
    raise