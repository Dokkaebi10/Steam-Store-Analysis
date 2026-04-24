-- run this first and review before changing anything
SELECT
  COUNT(*)                                           AS total_rows,
  COUNT(*) FILTER (WHERE name IS NULL)               AS null_names,
  COUNT(*) FILTER (WHERE price_usd IS NULL)          AS null_prices,
  COUNT(*) FILTER (WHERE peak_ccu = 0)               AS zero_peak_ccu,
  COUNT(*) FILTER (WHERE average_playtime_forever=0) AS zero_playtime,
  COUNT(*) FILTER (WHERE positive_reviews = 0
                   AND   negative_reviews = 0)       AS no_reviews
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

-- Fix bad prices
UPDATE games SET price_usd = NULL
WHERE price_usd < 0 OR price_usd > 999;

-- Remove games with no average playtime and no reviews (combined positive and negative)
-- These are likely to be games that were added to the database but never released, or had no players and no reviews. They skew the data and don't provide useful insights.
DELETE FROM games
WHERE (average_playtime_forever = 0
  AND median_playtime_forever  = 0)
  OR (positive_reviews = 0
  AND negative_reviews = 0);

-- Final row count
SELECT COUNT(*) AS clean_rows FROM games;