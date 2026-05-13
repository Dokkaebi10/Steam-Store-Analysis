-- transaction 2: delete non-games based on tag patterns identified in tables_audit.sql
BEGIN;

-- removes rows from games and game_tags, but leaves any referenced tags in place 
-- orphan cleanup at the end of this transaction removes any game_tags rows that reference deleted games, and then any tags that are no longer referenced by any game_tags
-- gt.votes must match with tables_audit.sql to ensure the same rows are targeted for deletion in both places
DROP TABLE IF EXISTS non_game_appids;
CREATE TEMP TABLE non_game_appids AS
SELECT DISTINCT g.appid
FROM games g
JOIN game_tags gt ON g.appid   = gt.appid
JOIN tags      t  ON gt.tag_id = t.tag_id
WHERE
    t.tag_name IN (
        'Video Production', 'Audio Production', 'Photo Editing',
        'Animation & Modeling', 'Game Development', 'Web Publishing',
        'Accounting', 'Utilities', 'Software', 'Software Training', 'Tutorial'
    )
    AND gt.votes >= 5
    AND NOT EXISTS (
        SELECT 1
        FROM game_tags gt2
        JOIN tags t2 ON gt2.tag_id = t2.tag_id
        WHERE gt2.appid = g.appid
          AND t2.tag_name IN (
              'Singleplayer', 'Multiplayer', 'Co-op', 'PvP', 'PvE',
              'Action', 'RPG', 'Adventure', 'Strategy', 'Puzzle',
              'Shooter', 'Platformer', 'Horror', 'Survival', 'Roguelike',
              'Roguelite', 'Indie', 'Casual', 'Sports', 'Racing',
              'Fighting', 'Simulation', 'Open World', 'Sandbox',
              'Story Rich', 'Atmospheric', 'First-Person', 'Third-Person',
              'Top-Down', 'Side Scroller', '2D', '3D'
          )
    );

-- safety check: if this looks unreasonably high
-- review the output of the previous SELECT in tables_audit.sql and adjust the tag lists or votes threshold in both places
DO $$
DECLARE n INT;
BEGIN
    SELECT COUNT(*) INTO n FROM non_game_appids;
    IF n > 1000 THEN
        RAISE EXCEPTION 'non_game_appids has % rows — expected ≤ 1000. '
                        'Review tables_audit.sql output and adjust threshold. '
                        'Transaction will roll back.', n;
    END IF;
    RAISE NOTICE 'non_game_appids: % rows — proceeding with delete', n;
END $$;

DELETE FROM game_tags WHERE appid IN (SELECT appid FROM non_game_appids);
DELETE FROM games     WHERE appid IN (SELECT appid FROM non_game_appids);
 
-- Orphan cleanup
-- Once constraints.sql adds ON DELETE CASCADE, future deletes
-- from games will auto-cascade to game_tags — but that script
-- runs after this one, so the manual cleanup is still needed here.
DELETE FROM game_tags gt
WHERE NOT EXISTS (
    SELECT 1 FROM games g WHERE g.appid = gt.appid
);
 
-- Prune tags dimension table of any now-unreferenced tags.
DELETE FROM tags t
WHERE NOT EXISTS (
    SELECT 1 FROM game_tags gt WHERE gt.tag_id = t.tag_id
);

-- Recalculate game_count now that zero-engagement and non-game rows
-- have been removed. The Python load computed this pre-deletion, so
-- the values are stale. This affects top-tag rankings in KPI 3 and
-- v_kpi_releases_by_year_tag.
UPDATE tags t
SET game_count = (
    SELECT COUNT(DISTINCT gt.appid)
    FROM game_tags gt
    WHERE gt.tag_id = t.tag_id
);
 
COMMIT;

-- ── Post-run row count ───────────────────────────────────────
-- Outside the transaction intentionally — reflects committed state.
SELECT COUNT(*) AS clean_rows FROM games;