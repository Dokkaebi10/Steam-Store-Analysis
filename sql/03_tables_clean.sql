-- Null out prices outside the plausible range.
-- pandas coerces unparseable prices to NULL before the DB load, so no NaN float condition is needed here.
BEGIN;
 
UPDATE games
SET price_usd = NULL
WHERE price_usd < 0
   OR price_usd > 999;
 
-- The Python load kept release_date as text to avoid cast errors.
-- The regex filter skips rows that don't match "Mon DD, YYYY"
-- (e.g. "Jul 29, 2016"). Non-matching rows stay NULL.
-- Add extra UPDATE passes below for any other formats spotted
-- in cleanup_audit.sql query 3.
ALTER TABLE games ADD COLUMN IF NOT EXISTS release_date_parsed DATE;
 
UPDATE games
SET release_date_parsed = TO_DATE(release_date, 'Mon DD, YYYY')
WHERE release_date ~ '^\w{3} \d+, \d{4}$';
 
-- Add additional UPDATE passes here for non-standard formats, e.g.:
-- UPDATE games
-- SET release_date_parsed = TO_DATE(release_date, 'YYYY-MM-DD')
-- WHERE release_date ~ '^\d{4}-\d{2}-\d{2}$'
--   AND release_date_parsed IS NULL;
 
 -- Deletes rows with no playtime on either measure AND no reviews
-- on either side. game_tags orphans are cleaned up in Step 5.
DELETE FROM games
WHERE (average_playtime_forever = 0 AND median_playtime_forever = 0)
  AND (positive_reviews         = 0 AND negative_reviews        = 0);
 
COMMIT;

BEGIN;

-- Both tables_audit and tables_clean must be run in the same psql session — temp tables do not persist across sessions.
-- Uncomment when satisfied with the audit output.
-- Re-comment after running to prevent accidental re-execution.
-- Child table must be deleted before parent to respect FK order.
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

-- Safety check: print count so you can abort if it looks wrong
DO $$
DECLARE n INT;
BEGIN
    SELECT COUNT(*) INTO n FROM non_game_appids;
    IF n > 1000 THEN
        RAISE EXCEPTION 'non_game_appids has % rows — expected ≤ 1000. '
                        'Review cleanup_audit.sql output and adjust threshold. '
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