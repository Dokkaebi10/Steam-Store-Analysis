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
WHERE price_usd < 0 OR price_usd > 999 OR price_usd = 'NaN'::float;

-- Check how many null prices remain after cleanup
SELECT COUNT(*) FILTER (WHERE price_usd IS NULL) AS null_prices_after_cleanup
FROM games;

-- ADD a proper date column
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
  OR (positive_reviews = 0
  AND negative_reviews = 0);

-- Peak ccu is a snapshot around that time, so it's possible for it to be zero if the game was added but never released or had no players. 
-- However, you may want to investigate these cases further to see if they are valid entries or if they should be removed.

-- For filter/selecting JSONB columns, you can use the following syntax:
-- To check if a key exists in a JSONB column (e.g. developers):
-- SELECT * FROM games WHERE developers ? 'Valve';
-- ? checks if the key exists in the JSONB object. This is useful for filtering games by a specific developer or tag.
-- @> checks if the JSONB object contains a specific key-value pair. This is useful for filtering games that have a specific tag with a certain value (e.g. "Action": true).

-- Final row count
SELECT COUNT(*) AS clean_rows FROM games;

