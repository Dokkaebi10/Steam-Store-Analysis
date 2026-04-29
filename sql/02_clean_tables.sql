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
WHERE price_usd IS NULL OR price_usd < 0 OR price_usd > 999 OR price_usd != price_usd
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
-- Final row count
SELECT COUNT(*) AS clean_rows FROM games;