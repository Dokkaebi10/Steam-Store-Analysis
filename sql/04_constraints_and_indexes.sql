-- ── Prerequisites ────────────────────────────────────────────────────────────
-- cleanup_run.sql MUST be run before this script.
-- idx_games_release_date and several views depend on the release_date_parsed
-- column, which cleanup_run.sql creates via ALTER TABLE. Running this script
-- first will error with "column release_date_parsed does not exist".
--
-- Required run order:
--   1. load_data.py
--   2. cleanup_audit.sql  (review only)
--   3. cleanup_run.sql
--   4. constraints.sql    ← this file
--   5. views.sql

-- ── 1. Drop existing FKs before touching the PKs they reference ──────────────
ALTER TABLE game_tags DROP CONSTRAINT IF EXISTS fk_game_tags_appid;
ALTER TABLE game_tags DROP CONSTRAINT IF EXISTS fk_game_tags_tag_id;

-- ── 2. Drop existing PKs ─────────────────────────────────────────────────────
-- PostgreSQL auto-names PKs as <table>_pkey.
ALTER TABLE game_tags DROP CONSTRAINT IF EXISTS game_tags_pkey;
ALTER TABLE tags      DROP CONSTRAINT IF EXISTS tags_pkey;
ALTER TABLE games     DROP CONSTRAINT IF EXISTS games_pkey;

-- ── 3. Re-add PKs ────────────────────────────────────────────────────────────
-- Must come before the FK additions that reference these columns.
ALTER TABLE games
    ADD CONSTRAINT games_pkey PRIMARY KEY (appid);

ALTER TABLE tags
    ADD CONSTRAINT tags_pkey  PRIMARY KEY (tag_id);

-- Composite PK enforces uniqueness at the DB level and doubles as the
-- leading index for appid lookups on the bridge table (no separate index needed).
ALTER TABLE game_tags
    ADD CONSTRAINT game_tags_pkey PRIMARY KEY (appid, tag_id);

-- ── 4. Add FKs ───────────────────────────────────────────────────────────────
-- ON DELETE CASCADE: deleting a game or tag automatically removes its bridge
-- rows, preventing orphaned records without a manual cleanup step.
ALTER TABLE game_tags
    ADD CONSTRAINT fk_game_tags_appid
        FOREIGN KEY (appid)  REFERENCES games(appid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_game_tags_tag_id
        FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE CASCADE;

-- ── 5. Indexes ───────────────────────────────────────────────────────────────
-- Bridge table: tag_id lookups (appid is already covered by the composite PK).
CREATE INDEX IF NOT EXISTS idx_game_tags_tag_id
    ON game_tags (tag_id);

-- Date-range queries (KPI 3 trend line).
CREATE INDEX IF NOT EXISTS idx_games_release_date
    ON games (release_date_parsed);

-- Price bracket queries (KPI 4, KPI 5).
-- NULL-safe: NULLs are stored and the index is still used for IS NULL / IS NOT NULL filters.
CREATE INDEX IF NOT EXISTS idx_games_price_usd
    ON games (price_usd);

-- Playtime filter (WHERE average_playtime_forever > 0 appears in every KPI query).
-- Partial index covers only the rows that actually reach the WHERE clause,
-- keeping it small and the planner selective.
CREATE INDEX IF NOT EXISTS idx_games_avg_playtime_nonzero
    ON games (average_playtime_forever)
    WHERE average_playtime_forever > 0;

-- GIN index for JSONB containment queries on genres_and_tags.
-- e.g. WHERE genres_and_tags @> '["Action"]'
CREATE INDEX IF NOT EXISTS idx_games_genres_and_tags
    ON games USING GIN (genres_and_tags);

-- GIN index for tag key-existence queries on the raw tags JSONB.
-- e.g. WHERE tags ? 'Action'
CREATE INDEX IF NOT EXISTS idx_games_tags
    ON games USING GIN (tags);

-- Partial index for "active" games: rows that appear in almost every KPI query
-- (non-zero playtime + at least one review). Keeps the planner selective for
-- the most common filter combination without touching low-engagement rows.
CREATE INDEX IF NOT EXISTS idx_games_active
    ON games (appid)
    WHERE average_playtime_forever > 0
      AND (positive_reviews + negative_reviews) > 0;

-- ── 6. Refresh planner statistics ────────────────────────────────────────────
-- After bulk writes, deletes, and index creation the query planner's statistics
-- are stale. VACUUM reclaims dead rows from the deletes in cleanup_run.sql;
-- ANALYZE updates column statistics so the planner makes good choices.
--
-- These run OUTSIDE any transaction block — VACUUM cannot be executed inside
-- one and will error with "VACUUM cannot run inside a transaction block".
-- In psql (\i constraints.sql) this is safe because each statement
-- auto-commits. In DBeaver, DataGrip, or any client with auto-begin enabled,
-- copy and run these three lines alone in a separate plain SQL console window.
VACUUM ANALYZE games;
VACUUM ANALYZE game_tags;
VACUUM ANALYZE tags;