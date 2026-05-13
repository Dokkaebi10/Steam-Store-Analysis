-- transaction 1: clean implausible values and zero-engagement rows from games
BEGIN;

-- prices outside the plausible range become NULL — these are likely data errors, and the Python load already coerces unparseable values to NULL, so no NaN float condition is needed here.
UPDATE games
SET price_usd = NULL
WHERE price_usd < 0
   OR price_usd > 999;

-- adds DATE column and adds raw text column for rows that match data format "Mon DD, YYYY" (e.g. "Jul 29, 2016")
-- non-matching rows stay NULL; add extra UPDATE passes for any other formats spotted in tables_audit.sql que
-- the regex filter skips rows that don't match "Mon DD, YYYY" (e.g. "Jul 29, 2016")
ALTER TABLE games ADD COLUMN IF NOT EXISTS release_date_parsed DATE;
 
UPDATE games
SET release_date_parsed = TO_DATE(release_date, 'Mon DD, YYYY')
WHERE release_date ~ '^\w{3} \d+, \d{4}$';
 
UPDATE games
SET release_date_parsed = TO_DATE(release_date, 'YYYY-MM-DD')
WHERE release_date ~ '^\d{4}-\d{2}-\d{2}$'
    AND release_date_parsed IS NULL;

-- deletes rows with no engagement signals
DELETE FROM games
WHERE (average_playtime_forever = 0 AND median_playtime_forever = 0)
  AND (positive_reviews         = 0 AND negative_reviews        = 0);
 
COMMIT;

-- Post-run row count (outside transaction — reflects committed state).
SELECT COUNT(*) AS clean_rows FROM games;