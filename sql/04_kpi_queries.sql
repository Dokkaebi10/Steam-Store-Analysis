-- KPI 1 Average playtime by tags
-- Which tags are associated with the longest average playtime?
-- A lot of the games from this table are games with low peak_ccu, reccomendations, and low range of owners. 
-- This is likely because they are niche games that appeal to a smaller audience, but those players tend to play for longer sessions. 
-- For example, "Visual Novel" and "Anime" are popular tags for story-driven games that may not have mass appeal but can be very engaging for fans of the genre. 
-- On the other hand, more mainstream tags like "Action" or "Multiplayer" might have a wider audience but shorter average playtime due to the nature of the gameplay.
SELECT 
    jsonb_object_keys(g.tags)                        AS tag_name,
    COUNT(DISTINCT g.appid)                          AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1) AS avg_playtime_hours,
    ROUND(AVG(g.median_playtime_forever) / 60.0, 1)  AS median_playtime_hours
FROM games g
WHERE g.average_playtime_forever > 0
  AND g.tags IS NOT NULL
GROUP BY tag_name 
HAVING COUNT(DISTINCT g.appid) >= 10
ORDER BY avg_playtime_hours DESC
LIMIT 20;

-- Games by a specific developer
SELECT name, developers
FROM games
WHERE developers ? 'Valve';

-- Count games per developer (unnested)
SELECT 
    jsonb_array_elements_text(developers) AS developer,
    COUNT(*)                              AS game_count
FROM games
GROUP BY developer
ORDER BY game_count DESC;

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