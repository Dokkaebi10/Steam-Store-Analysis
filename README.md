# Steam Games Analytics Pipeline

A data pipeline that loads a Steam games dataset from JSON into PostgreSQL, cleans and normalises it into three tables, and exposes pre-aggregated views for Power BI dashboards.

> This is personal learning project so there are a lot more comments as a way to learn the what's and why's for each line and block of code.
---

## Table of Contents

- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Run Order](#run-order)
- [Database Schema](#database-schema)
- [KPI Views](#kpi-views)
- [Power BI Connection](#power-bi-connection)
- [Re-running the Pipeline](#re-running-the-pipeline)
- [Troubleshooting](#troubleshooting)

---

## Project Structure

```
.
├── data/
│   └── games.json                      # Raw Steam dataset (not committed)
├── python/
|   └── 01_load_data.py                 # ETL: JSON → PostgreSQL
├── sql/
│   ├── 02_tables_audit.sql             # Pre-cleanup inspection queries (read-only)
│   ├── 03_tables_run.sql               # Destructive cleanup — run after audit
|   ├── 04_remove_non_games.sql         # Remove software that are not games (optional)
│   ├── 05_constraints_and_indexes.sql  # PKs, FKs, and indexes
│   ├── 06_kpi_queries.sql              # Power BI-facing KPI views (optional)
│   └── 07_views.sql                    # Standalone KPI queries (optional)
├── .env                                # DB credentials (not committed)
├── requirements.txt
└── README.md
```

---

## Architecture

```
games.json
    │
    ▼
01_load_data.py          — Parses, flattens, cleans, and writes three tables
    │
    ▼
┌─────────────────────────────────────────┐
│             PostgreSQL                  │
│                                         │
│  games          tags       game_tags    │
│  (fact)      (dimension)   (bridge)     │
└─────────────────────────────────────────┘
    │
    ▼
02_tables_audit.sql                 — Inspect raw data, review what will be removed
    │
    ▼
03_tables_clean.sql                 — Remove junk rows, parse dates, prune non-games
04_remove_non_games (optioanl)
    │
    ▼
05_constraints_and_indexes.sql      — Add PKs, FKs, indexes, VACUUM ANALYZE
    │
    ▼
07_views.sql                        — Create v_kpi_* views for Power BI
    │
    ▼
Power BI Desktop                    — Connect to views, build dashboards
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Python | 3.9+ | |
| PostgreSQL | 13+ | Must be running and accessible |
| Power BI Desktop | 2020+ | Windows only — native PostgreSQL connector included |

Install Python dependencies:

```bash
pip install -r requirements.txt
```

---

## Setup

1. **Clone the repository** .

2. **Download** [Steam Games Dataset](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) and place `games.json` in the `data/` folder

3. **Fill in your database credentials** in `.env`:

   ```env
   DB_USER=your_user
   DB_PASSWORD=your_password
   DB_HOST=localhost
   DB_PORT=5432
   DB_NAME=your_database
   ```

4. **Create the target database** in PostgreSQL if it doesn't exist:

   ```sql
   CREATE DATABASE your_database;
   ```

---

## Run Order

> ⚠️ The scripts have strict dependencies. Running them out of order will cause errors. Follow this sequence exactly.

### Step 1 — Load raw data (01_load_data.py)

Writes three tables to PostgreSQL: `games`, `tags`, `game_tags`. Drops and recreates them on every run.

> **Note:** Re-running this step will drop all dependent views via `CASCADE`. Re-run Steps 4 and 5 afterward to restore them.

---

### Step 2 — Audit the raw data (02_tables_audit.sql)

This is a review-only step. It prints row counts, price anomalies, date format samples, and the list of apps flagged as non-games. **No data is modified.** Review the output before proceeding, particularly:

- The `non_game_rows_to_remove` count — if it looks unexpectedly high, investigate before continuing.
- The `release_date` sample — confirm the `Mon DD, YYYY` format covers most rows.

---

### Step 3 — Run cleanup (03_tables_clean.sql and 04_remove_non_games.sql (optional))

Performs two sequential transactions:

**Transaction 1 — safe cleanup:**
- Nulls out prices outside `$0–$999`
- Adds and populates the `release_date_parsed DATE` column
- Deletes zero-engagement rows (no playtime and no reviews)

**Transaction 2 — guarded non-game deletion:**
- Identifies apps tagged as software/tools with no game-indicator tags
- Aborts automatically if more than 1000 rows are flagged (safety threshold)
- Deletes flagged apps and their bridge rows
- Prunes orphaned tags
- Recalculates `tags.game_count` to reflect post-deletion state

> **Note:** If Transaction 2 aborts due to the safety threshold, only that transaction rolls back. Transaction 1 is already committed and does not need to be re-run.

---

### Step 4 — Apply constraints and indexes (05_constraints_and_indexes.sql)

Adds primary keys, foreign keys with `ON DELETE CASCADE`, and all performance indexes.

> **Note:** The final `VACUUM ANALYZE` statements cannot run inside a transaction block. In psql this is fine. In GUI clients with auto-begin enabled (DBeaver, DataGrip), run those three statements separately in a plain SQL console.

---

### Step 5 — Create KPI views (07_views.sql)

Creates six `v_kpi_*` views that Power BI connects to directly. Verify they were created:

```sql
SELECT viewname FROM pg_views
WHERE schemaname = 'public' AND viewname LIKE 'v_kpi_%'
ORDER BY viewname;
```

---

## Database Schema

### `games` (fact table)

| Column | Type | Description |
|---|---|---|
| `appid` | integer (PK) | Steam application ID |
| `name` | text | Game title |
| `release_date` | text | Raw release date string from Steam |
| `release_date_parsed` | date | Parsed date — added by `cleanup_run.sql` |
| `price_usd` | numeric | Price in USD; NULL if unparseable or out of range |
| `dlc_count` | integer | Number of DLCs |
| `windows / mac / linux` | boolean | Platform availability |
| `metacritic_score` | integer | 0 if not rated |
| `achievements` | integer | Number of achievements |
| `recommendations` | integer | Steam recommendations count |
| `positive_reviews` | integer | Positive review count |
| `negative_reviews` | integer | Negative review count |
| `average_playtime_forever` | integer | Average playtime in **minutes** |
| `median_playtime_forever` | integer | Median playtime in **minutes** |
| `peak_ccu` | integer | Peak concurrent users |
| `developers` | jsonb | List of developer names |
| `publishers` | jsonb | List of publisher names |
| `genres_and_tags` | jsonb | Deduplicated list of Steam categories and tag names |
| `tags` | jsonb | Raw tag dict `{"tag_name": vote_count}` |

### `tags` (dimension table)

| Column | Type | Description |
|---|---|---|
| `tag_id` | integer (PK) | Surrogate key |
| `tag_name` | text | Steam tag name |
| `game_count` | integer | Number of games carrying this tag (recalculated post-cleanup) |

### `game_tags` (bridge table)

| Column | Type | Description |
|---|---|---|
| `appid` | integer (FK → games) | |
| `tag_id` | integer (FK → tags) | |
| `votes` | integer | Steam user votes for this tag on this game |

---

## KPI Views

All playtime values are stored in **minutes** in the base tables. All views convert to **hours**.

| View | Description |
|---|---|
| `v_kpi_playtime_by_tag` | Average and median playtime per tag; includes achievement band |
| `v_kpi_releases_by_year_tag` | Games released per year per tag; includes cumulative total |
| `v_kpi_playtime_by_price` | Playtime and review counts by price bracket; includes `sort_order` |
| `v_kpi_f2p_vs_paid` | Free-to-play vs paid breakdown per tag |
| `v_kpi_f2p_vs_paid_summary` | Top-level free vs paid comparison with `playtime_hrs_per_dollar` |
| `v_kpi_review_scores_by_tag` | Wilson lower-bound approval score per tag |

> `v_kpi_releases_by_year_tag` returns all tags — apply a Top N filter on `tag_total_game_count` in Power BI to keep charts readable (15 is a good default).

> `v_kpi_playtime_by_price` — always sort the axis by `sort_order` (ascending) in Power BI, not alphabetically.

---

## Power BI Connection

1. Open Power BI Desktop — no additional driver needed for versions 2020 and later
2. **Home → Get Data → PostgreSQL**
3. Server: `DB_HOST` (append `:DB_PORT` if not 5432), Database: `DB_NAME`
4. Data Connectivity mode: **Import**
5. In the Navigator, select only the six `v_kpi_*` views → **Load**
6. In **Column Tools**, set `price_bracket` to sort by `sort_order` in `v_kpi_playtime_by_price`

For scheduled refresh, publish to Power BI Service and configure an **On-premises Data Gateway**.

---

## Re-running the Pipeline

When you reload `games.json` with updated data, repeat Steps 1–5 in full:

```bash
python load_data.py        # re-drops and recreates all tables (CASCADE drops views)
psql -f sql/cleanup_audit.sql
psql -f sql/cleanup_run.sql
psql -f sql/constraints.sql
psql -f sql/views.sql      # must be re-run — views were dropped by CASCADE in Step 1
```

Then click **Refresh** in Power BI Desktop.

---

## Troubleshooting

**`column release_date_parsed does not exist`**
`constraints.sql` or `views.sql` was run before `cleanup_run.sql`. Run `cleanup_run.sql` first — it creates this column via `ALTER TABLE`.

**`VACUUM cannot run inside a transaction block`**
Your SQL client has auto-begin enabled. Run the three `VACUUM ANALYZE` statements at the bottom of `constraints.sql` separately in a plain psql session.

**`non_game_appids has N rows — expected ≤ 500`**
The safety threshold in `cleanup_run.sql` fired. Run `cleanup_audit.sql` first, review the full non-game list, and either adjust the tag lists or the votes threshold in both files before re-running.

**`Missing required env vars: [...]`**
Your `.env` file is missing or one of the five required keys is not set. Check that `.env` exists in the project root and contains all of `DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_PORT`, `DB_NAME`.

**Power BI can't find the PostgreSQL connector**
You are likely on a version of Power BI Desktop older than mid-2020. Either update Power BI Desktop (recommended), or install the Npgsql driver from [npgsql.org](https://www.npgsql.org/) as a fallback for legacy versions.

**`v_kpi_*` views missing after re-run**
`load_data.py` drops tables with `CASCADE`, which removes dependent views. Re-run `views.sql` to restore them.