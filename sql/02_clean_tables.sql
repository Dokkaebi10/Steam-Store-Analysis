-- run this first and review before changing anything
SELECT
  COUNT(*)                                              AS total_rows,
  COUNT(*) FILTER (WHERE name IS NULL)                  AS null_names,
  COUNT(*) FILTER (WHERE price_usd IS NULL)             AS null_prices,
  COUNT(*) FILTER (WHERE peak_ccu = 0)                  AS zero_peak_ccu,
  COUNT(*) FILTER (WHERE average_playtime_forever=0)    AS zero_playtime,
  COUNT(*) FILTER (WHERE positive_reviews = 0
                   AND   negative_reviews = 0)          AS no_reviews
FROM games;

-- Fix bad prices
-- Remove negative prices and unrealistically high prices (e.g. $999) that are likely data errors.
UPDATE games SET price_usd = NULL
WHERE price_usd < 0
   OR price_usd > 999
   OR price_usd != price_usd; -- also catches NaN since NaN != NaN is true
-- Check how many null prices remain after cleanup
SELECT COUNT(*) FILTER (WHERE price_usd IS NULL) AS null_prices_after_cleanup
FROM games;

-- Parse release_date into a proper DATE column
-- The Python load kept release_date as text to avoid cast errors
ALTER TABLE games ADD COLUMN IF NOT EXISTS release_date_parsed DATE;
-- "Jul 29, 2016" → 2016-07-29
-- The regex filter skips rows that don't match this pattern
UPDATE games
SET release_date_parsed = TO_DATE(release_date, 'Mon DD, YYYY')
WHERE release_date ~ '^\w{3} \d+, \d{4}$';
-- Check how many dates parsed successfully vs failed
SELECT
  COUNT(*) FILTER (WHERE release_date_parsed IS NOT NULL) AS parsed,
  COUNT(*) FILTER (WHERE release_date_parsed IS NULL)     AS failed
FROM games;
-- See what date formats failed so you can add more UPDATE passes
SELECT DISTINCT release_date
FROM games
WHERE release_date_parsed IS NULL
  AND release_date IS NOT NULL
LIMIT 20;

-- Remove games with no average playtime and no reviews (combined positive and negative)
-- These are likely to be games that were added to the database but never released, or had no players and no reviews. They skew the data and don't provide useful insights.
DELETE FROM games
WHERE (average_playtime_forever = 0
  AND median_playtime_forever  = 0)
  AND (positive_reviews = 0
  AND negative_reviews = 0);
-- Clean up orphaned game_tags rows for any appids removed above.
-- Without this, the bridge table holds rows referencing games that no longer exist, which will cause FK constraint violations in the next step.
-- NOT EXISTS over NOT IN for better performance and correct handling of NULLs.
DELETE FROM game_tags gt
WHERE NOT EXISTS (SELECT 1 FROM games g WHERE g.appid = gt.appid);

-- Run the audit SELECTs first and review the output.
-- When satisfied, uncomment the two DELETE blocks to execute.
-- The orphan cleanup at the bottom of this script covers both this removal and the earlier ones — nothing extra needed.
SET votes_threshold = 5; -- tune this threshold based on the output of the SELECTs below

-- Removal requires ALL THREE conditions to be true:
--   1. Has at least one non-game tag
--   2. That non-game tag has votes above the threshold
--   3. Has none of the common game-indicator tags
SELECT
    g.appid,
    g.name,
    g.genres_and_tags,
    t.tag_name                          AS non_game_tag,
    gt.votes                            AS non_game_tag_votes
FROM games g
JOIN game_tags gt ON g.appid = gt.appid
JOIN tags      t  ON gt.tag_id = t.tag_id
WHERE
    -- Condition 1 + 2: has a non-game tag with meaningful votes
    t.tag_name IN (
        'Video Production', 'Audio Production', 'Photo Editing',
        'Animation & Modeling', 'Game Development', 'Web Publishing',
        'Accounting', 'Utilities', 'Software', 'Software Training', 'Tutorial'
    )
    AND gt.votes >= $votes_threshold
    -- Condition 3: has none of the common game-indicator tags
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
              'Fighting', 'Simulation',  -- keep Simulation here:
                                         -- real software rarely gets
                                         -- tagged Simulation by users
              'Open World', 'Sandbox', 'Story Rich', 'Atmospheric',
              'First-Person', 'Third-Person', 'Top-Down', 'Side Scroller',
              '2D', '3D'
          )
    )
ORDER BY gt.votes DESC, g.name;

SELECT COUNT(DISTINCT g.appid) AS non_game_rows_to_remove
FROM games g
JOIN game_tags gt ON g.appid = gt.appid
JOIN tags      t  ON gt.tag_id = t.tag_id
WHERE
    t.tag_name IN (
        'Video Production', 'Audio Production', 'Photo Editing',
        'Animation & Modeling', 'Game Development', 'Web Publishing',
        'Accounting', 'Utilities', 'Software', 'Software Training', 'Tutorial'
    )
    AND gt.votes >= $votes_threshold
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

-- Clean up orphaned game_tags (covers all deletes above)
DELETE FROM game_tags
WHERE appid NOT IN (SELECT appid FROM games);

-- Prune tags dimension table of any now-unreferenced tags
-- This covers the optional non-game software delete.
-- Even though that block correctly deletes game_tags first,
-- some tags may now have zero games referencing them in game_tags.
-- Those tag rows in the dimension table are harmless but dead weight.
DELETE FROM tags t
WHERE NOT EXISTS (
    SELECT 1 FROM game_tags gt WHERE gt.tag_id = t.tag_id
);

-- Final row count
SELECT COUNT(*) AS clean_rows FROM games;