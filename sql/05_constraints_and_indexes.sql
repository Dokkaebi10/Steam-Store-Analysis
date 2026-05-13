-- drop and re-create constraints and indexes to clean up after the bulk deletes in tables_clean.sql
-- and to add ON DELETE CASCADE for easier maintenance going forward
ALTER TABLE game_tags DROP CONSTRAINT IF EXISTS fk_game_tags_appid;
ALTER TABLE game_tags DROP CONSTRAINT IF EXISTS fk_game_tags_tag_id;

-- drop PKs after FKs to avoid dependency issues
ALTER TABLE game_tags DROP CONSTRAINT IF EXISTS game_tags_pkey;
ALTER TABLE tags DROP CONSTRAINT IF EXISTS tags_pkey;
ALTER TABLE games DROP CONSTRAINT IF EXISTS games_pkey;

ALTER TABLE games ADD CONSTRAINT games_pkey PRIMARY KEY (appid);
ALTER TABLE tags ADD CONSTRAINT tags_pkey  PRIMARY KEY (tag_id);
-- composite PK: uniquely identifies each game/tag association and prevents duplicates
ALTER TABLE game_tags ADD CONSTRAINT game_tags_pkey PRIMARY KEY (appid, tag_id);

-- ON DELETE CASCADE: deleting a game or tag automatically removes its bridge rows, preventing orphaned records without a manual cleanup step
ALTER TABLE game_tags
    ADD CONSTRAINT fk_game_tags_appid
        FOREIGN KEY (appid) REFERENCES games(appid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_game_tags_tag_id
        FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE CASCADE;

-- create indexes to speed up common query patterns in the KPI scripts
-- tag-based queries
CREATE INDEX IF NOT EXISTS idx_game_tags_tag_id ON game_tags (tag_id);
-- date-range queries
CREATE INDEX IF NOT EXISTS idx_games_release_date ON games (release_date_parsed);
-- price bracket queries
CREATE INDEX IF NOT EXISTS idx_games_price_usd ON games (price_usd);
-- playtime queries
CREATE INDEX IF NOT EXISTS idx_games_avg_playtime_nonzero
    ON games (average_playtime_forever)
    WHERE average_playtime_forever > 0;
-- genre/tag co-occurrence queries
CREATE INDEX IF NOT EXISTS idx_games_genres_and_tags
    ON games USING GIN (genres_and_tags);
-- tag-based queries that filter on specific tags or tag combinations
CREATE INDEX IF NOT EXISTS idx_games_tags
    ON games USING GIN (tags);
-- partial index for "active" games: rows that appear in almost every KPI query
CREATE INDEX IF NOT EXISTS idx_games_active
    ON games (appid)
    WHERE average_playtime_forever > 0
    AND (positive_reviews + negative_reviews) > 0;

-- VACUUM reclaims storage from deleted rows and updates statistics for the query planner
-- ANALYZE updates the query planner's statistics to help it make informed decisions about which indexes to use
VACUUM ANALYZE games;
VACUUM ANALYZE game_tags;
VACUUM ANALYZE tags;