-- summary of the raw loaded data to review data quality
SELECT
    COUNT(*)                                                AS total_rows,
    COUNT(*) FILTER (WHERE name IS NULL)                    AS null_names,
    COUNT(*) FILTER (WHERE price_usd IS NULL)               AS null_prices,
    COUNT(*) FILTER (WHERE peak_ccu = 0)                    AS zero_peak_ccu,
    COUNT(*) FILTER (WHERE average_playtime_forever = 0)    AS zero_playtime,
    COUNT(*) FILTER (WHERE positive_reviews  = 0
                     AND   negative_reviews  = 0)           AS no_reviews
FROM games;

-- prices outside the valid range ($0–$999)
SELECT
    COUNT(*) FILTER (WHERE price_usd < 0)    AS negative_prices,
    COUNT(*) FILTER (WHERE price_usd > 999)  AS prices_above_999
FROM games;

-- release_date values that fail the "Mon DD, YYYY" format check
SELECT
    release_date,
    COUNT(*) AS occurrences
FROM games
WHERE release_date IS NOT NULL
GROUP BY release_date
ORDER BY occurrences DESC
LIMIT 40;

-- rows with no playtime on either measure AND no reviews on either side
-- these are candidates for deletion, but spot-check a sample before proceeding
SELECT COUNT(*) AS zero_engagement_rows_to_delete
FROM games
WHERE (average_playtime_forever = 0 AND median_playtime_forever = 0)
  AND (positive_reviews         = 0 AND negative_reviews        = 0);

-- spot-check a sample of what will be removed
SELECT appid, name, release_date, price_usd
FROM games
WHERE (average_playtime_forever = 0 AND median_playtime_forever = 0)
  AND (positive_reviews         = 0 AND negative_reviews        = 0)
LIMIT 20;

-- rows that have a non-game tag with >= 5 votes and no game-indicator tags
-- these will be offered for deletion in tables_clean.sql (behind a comment guard)
-- if any legitimate games appear, adjust the tag lists or the votes threshold in here AND tables_clean.sql before uncommenting the DELETE blocks
DROP TABLE IF EXISTS non_game_appids;
CREATE TEMP TABLE non_game_appids AS
SELECT DISTINCT g.appid
FROM games g
JOIN game_tags gt ON g.appid  = gt.appid
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
 
-- row count — confirm this looks reasonable before proceeding
SELECT COUNT(*) AS non_game_rows_to_remove FROM non_game_appids;
 
-- review for any legitimate games before uncommenting the DELETE blocks in tables_clean.sql
SELECT
    g.appid,
    g.name,
    g.genres_and_tags,
    t.tag_name   AS non_game_tag,
    gt.votes     AS non_game_tag_votes
FROM games g
JOIN game_tags gt       ON g.appid   = gt.appid
JOIN tags      t        ON gt.tag_id = t.tag_id
JOIN non_game_appids na ON g.appid   = na.appid
ORDER BY gt.votes DESC, g.name;