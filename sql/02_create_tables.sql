-- sql/01a_staging.sql

-- One row holds the entire JSON file as a single JSONB value.
-- JSONB validates and parses the JSON on insert.
-- IF NOT EXISTS makes this safe to re-run without errors.
CREATE TABLE IF NOT EXISTS raw_steam_blob (data JSONB);
