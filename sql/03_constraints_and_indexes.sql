-- Add primary keys, foreign keys, and indexes
-- to_sql() creates bare tables with no constraints. Add them here
-- so referential integrity is enforced and common query patterns are fast.
-- Run AFTER all deletes/updates so constraint validation is clean.
ALTER TABLE games      ADD PRIMARY KEY (appid);
ALTER TABLE tags       ADD PRIMARY KEY (tag_id);
ALTER TABLE game_tags  ADD PRIMARY KEY (appid, tag_id);

-- Foreign keys with ON DELETE CASCADE ensure that if a game or tag is deleted, related rows in the bridge table are automatically removed, preventing orphaned records. 
ALTER TABLE game_tags
  ADD CONSTRAINT fk_game_tags_appid  FOREIGN KEY (appid)   REFERENCES games(appid),
  ADD CONSTRAINT fk_game_tags_tag_id FOREIGN KEY (tag_id)  REFERENCES tags(tag_id);
 
-- Index for joining/filtering bridge by tag
CREATE INDEX IF NOT EXISTS idx_game_tags_tag_id         ON game_tags (tag_id);
 
-- Index for date-range queries
CREATE INDEX IF NOT EXISTS idx_games_release_date       ON games (release_date_parsed);
 
-- GIN index for JSONB containment queries on genres_and_tags
-- e.g. WHERE genres_and_tags @> '["Action"]'
CREATE INDEX IF NOT EXISTS idx_games_genres_and_tags    ON games USING GIN (genres_and_tags);
 
-- GIN index for tag key-existence queries
-- e.g. WHERE tags ? 'Action'
CREATE INDEX IF NOT EXISTS idx_games_tags               ON games USING GIN (tags);
 
-- Refresh planner statistics
-- After bulk writes, deletes, and index creation the query planner's
-- statistics are stale. VACUUM reclaims dead rows; ANALYZE updates stats.
VACUUM ANALYZE games;
VACUUM ANALYZE game_tags;
VACUUM ANALYZE tags; 

-- Consider Partial index for active/reviewed games