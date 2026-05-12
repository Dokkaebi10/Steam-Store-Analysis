import json                                         # parses .json files into Python dicts/lists
import os                                           # reads environment variables from .env
import pandas as pd                                 # for DataFrame manipulation and cleaning
from sqlalchemy import create_engine, text          # for SQL/Python connection and writing to Postgres
from sqlalchemy.dialects.postgresql import JSONB    # for JSONB columns in to_sql dtype mapping
from dotenv import load_dotenv                      # for loading .env file with DB credentials
 
# load DB credentials from .env and validate 
load_dotenv()
required = ["DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME"]
missing  = [k for k in required if not os.getenv(k)]
if missing:
    raise EnvironmentError(f"Missing required env vars: {missing}")

# reads credentials from .env and creates PostgreSQL database connection
engine = create_engine(
    f"postgresql://{os.getenv('DB_USER')}:{os.getenv('DB_PASSWORD')}"
    f"@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
)

# load json file
# 'with' ensures the file is properly closed after reading
# 'encoding="utf-8"' ensures we can read any special characters in the JSON
print("Reading JSON file...")
with open("data/games.json", encoding="utf-8") as f:
    raw = json.load(f)
print(f"Loaded {len(raw)} games from JSON")
 
# converts the nested dictionary {"496350": {...}, "10": {...}} into a flat table
# orient="index" treats each key (appid) as column names and game data as values
# reset_index moves the appid from the index into a regular column, which we can then clean and cast
df = pd.DataFrame.from_dict(raw, orient="index")
df.index.name = "appid"
df.reset_index(inplace=True)
print(f"Columns found: {list(df.columns)}")
 
# select only the columns we need
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

# to_numeric with errors="coerce" converts invalid values to NaN
# dropna removes rows where appid couldn't be parsed, then cast to int
df["appid"] = pd.to_numeric(df["appid"], errors="coerce")
df.dropna(subset=["appid"], inplace=True)
df["appid"] = df["appid"].astype(int)
 
# price: already in dollars — coerce bad values to NaN
# kept as float (not cast to int) to distinguish free (0.0) from missing (NaN)
df["price"] = pd.to_numeric(df["price"], errors="coerce")
 
# coerce selected columns to int and fill nulls with 0
# note: some of these may be better as nulls (eg. Metacritic score) instead of zeros, but we'll keep it simple for now
int_cols = [
    "dlc_count", "metacritic_score",
    "achievements", "recommendations", "positive", "negative",
    "average_playtime_forever", "median_playtime_forever", "peak_ccu"
]
for col in int_cols:
    df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0).astype(int)

# coerce non-list values to empty lists so these columns are always list-typed
for col in ["developers", "publishers"]:
    df[col] = df[col].apply(lambda x: x if isinstance(x, list) else [])
for col in ["windows", "mac", "linux"]:
    df[col] = df[col].astype(bool)

# normalize tags to dict early so all downstream tag logic can assume dict type
df["tags"] = df["tags"].apply(lambda x: x if isinstance(x, dict) else {})
 
# remove junk rows: no names, test apps, zero engagement
# ~ is bitwise NOT operator, used here to negate the condition (keep rows that do NOT match)
# na=False in str.contains ensures that if name is NaN, it won't match the regex and thus won't be dropped by this filter
# filtering here avoids writing junk to Postgres and speeds up later SQL cleanup
before = len(df)
df.dropna(subset=["name"], inplace=True)
df = df[~df["name"].str.contains("test|valve test", case=False, na=False)]
df = df[~(
    (df["peak_ccu"] == 0) &
    (df["positive"] == 0) &
    (df["negative"] == 0)
)]
print(f"Removed {before - len(df)} test/junk rows") # should be significantly less than the original count if junk rows were removed
 
# combine categories (list of strings) and tag names (keys of the tags dict) into one
# deduplicated list, preserving original casing while deduplicating case-insensitively
def merge_genres_and_tags(row):
    genres = row["categories"] if isinstance(row["categories"], list) else []
    tag_keys = list(row["tags"].keys())         # tags is guaranteed a dict at this point
    seen = {}                                   # to track seen items in a case-insensitive way, while preserving original casing
    for item in genres + tag_keys:
        item = item.strip()                     # strip whitespace for better deduplication
        if item and item.lower() not in seen:  
            seen[item.lower()] = item           # key is lowercase for dedup; value preserves original casing
    return list(seen.values())

# categories is now merged into genres_and_tags; tags kept for bridge table votes
df["genres_and_tags"] = df.apply(merge_genres_and_tags, axis=1)
df.drop(columns=["categories"], inplace=True)

# rename to final column names
df.rename(columns={
    "price":    "price_usd",
    "positive": "positive_reviews",
    "negative": "negative_reviews",
}, inplace=True)
 
# build the bridge table: one row per (appid, tag_name) pair, vectorized via explode
# convert each tags dict to a list of (tag_name, votes) tuples, then explode into rows
print("Building tags tables...")
df_bridge = (df[["appid", "tags"]].copy().assign(tags=lambda d: d["tags"].apply(lambda x: list(x.items()))).explode("tags"))
df_bridge[["tag_name", "votes"]] = pd.DataFrame(df_bridge["tags"].tolist(), index=df_bridge.index)
df_bridge = df_bridge[["appid", "tag_name", "votes"]].copy()
df_bridge["tag_name"] = df_bridge["tag_name"].str.strip()
df_bridge = df_bridge[df_bridge["tag_name"] != ""]
df_bridge["votes"] = pd.to_numeric(df_bridge["votes"], errors="coerce").fillna(0).astype(int)
df_bridge.drop_duplicates(subset=["appid", "tag_name"], inplace=True)

# sanity check: if the bridge table is empty, it means we failed to parse any tags, which likely indicates a problem with the JSON structure or our parsing logic. We raise an error with a sample of the original tags values to help diagnose the issue.
if df_bridge.empty:
    sample = df["tags"].dropna().head(5).tolist()
    raise ValueError(f"No tags parsed. Sample tags values: {sample}")

# dimension table: one row per unique tag with a stable numeric tag_id
# sorted() ensures consistent tag_id assignment across runs
df_dim_tags = pd.DataFrame(sorted(df_bridge["tag_name"].unique()), columns=["tag_name"])
df_dim_tags.index.name = "tag_id"
df_dim_tags.reset_index(inplace=True)
df_dim_tags["tag_id"] = df_dim_tags["tag_id"] + 1 # start tag_id from 1 instead of 0 for better readability and to reserve 0 for "unknown" if needed in the future

# we group by tag_name and count the number of unique appids associated with each tag, which gives us the game_count for each tag
# we then merge this count into the df_dim_tags DataFrame so that each tag has its corresponding game_count
# we use a left merge to keep all tags in the dimension table, and fill any missing game_count values with 0
tag_game_counts = df_bridge.groupby("tag_name")["appid"].nunique().rename("game_count")
df_dim_tags = df_dim_tags.merge(tag_game_counts, on="tag_name", how="left")
df_dim_tags["game_count"] = df_dim_tags["game_count"].fillna(0).astype(int)
 
# merge the bridge table with the dimension table to replace tag_name with tag_id, which is more efficient for storage and querying in the database
df_bridge = df_bridge.merge(df_dim_tags[["tag_name", "tag_id"]], on="tag_name")[["appid", "tag_id", "votes"]]

# drop old and write all new three tables inside a single transaction
# if any write fails, all are rolled back — no partial state in the database.
# if_exists="replace" drops and recreates each table, which also removes any indexes or constraints added in previous runs
# CASCADE drops any dependent views (v_kpi_*) created by views.sql.
# Re-run views.sql and constraints.sql after any full reload.
try:
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE IF EXISTS game_tags CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS tags CASCADE"))
        conn.execute(text("DROP TABLE IF EXISTS games CASCADE"))
        # chunksize=1000 and method="multi" batches into multi-row inserts; 1000 rows ber batch
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