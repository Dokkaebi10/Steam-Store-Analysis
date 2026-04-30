-- KPI 1: Average playtime by tag, with achievements comparison
-- Do high-playtime tags also tend to have more achievements?
-- HAVING COUNT >= 20 filters out niche tags with too few games to be statistically meaningful. Tune this threshold to taste.
-- median_playtime_forever is included alongside average because
--     playtime distributions are heavily right-skewed (a small number
--     of whales with 1000+ hours inflate the mean). The median is more
--     representative of the typical player experience.
-- avg_achievements tells you how many achievements a game in that
--     tag category tends to have — not whether achievements exist.
--     High achievements + high playtime = games designed for completionists.
-- achievement_rate is the share of games in the tag that have ANY
--     achievements at all — a cleaner yes/no than the raw count.

SELECT
    t.tag_name,
    COUNT(DISTINCT g.appid)                                                 AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1)                        AS avg_playtime_hours,
    ROUND(AVG(g.median_playtime_forever)  / 60.0, 1)                        AS median_playtime_hours,
    ROUND(AVG(g.achievements)::numeric, 1)                                  AS avg_achievements,
    ROUND(100.0 * COUNT(*) FILTER (WHERE g.achievements > 0) / COUNT(*), 1) AS pct_games_with_achievements
FROM games g
JOIN game_tags gt ON g.appid = gt.appid
JOIN tags      t  ON gt.tag_id = t.tag_id
WHERE g.average_playtime_forever > 0   -- exclude games with no playtime data
GROUP BY t.tag_name
HAVING COUNT(DISTINCT g.appid) >= 20   -- minimum sample size per tag
ORDER BY avg_playtime_hours DESC
LIMIT 25;

-- REFERENCE — JSONB query patterns
-- Check if a key EXISTS in a JSONB column (most common for tags):
--   SELECT * FROM games WHERE tags ? 'Action';
--   The ? operator returns true if the key is present, regardless of its value.
--   Use this when you want "games that have the Action tag".
--
-- Check if a JSONB column CONTAINS a sub-object (exact value match):
--   SELECT * FROM games WHERE tags @> '{"Action": 1500}'::jsonb;
--   This only matches rows where Action has exactly the value 1500.
--   Rarely useful for tags — prefer ? for key existence,
--   or JOIN game_tags WHERE votes > N for threshold filtering.
--
-- Filter genres_and_tags array for a specific genre:
--   SELECT * FROM games WHERE genres_and_tags @> '["RPG"]'::jsonb;