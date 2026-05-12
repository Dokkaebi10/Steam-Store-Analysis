-- ── Prerequisites ────────────────────────────────────────────────────────────
-- Run after constraints.sql. All views depend on release_date_parsed, which
-- is created by cleanup_run.sql, and on games/game_tags/tags, which are
-- dropped and recreated by load_data.py. Re-run this file after any full
-- reload via load_data.py (the DROP TABLE CASCADE will have removed these views).

-- All playtime values are stored in minutes; converted to hours where noted. Review score = positive / (positive + negative).
-- KPI 1A: Average playtime by tag (top 30 by avg playtime)
SELECT
    t.tag_name,
    COUNT(DISTINCT g.appid)                                                                                 AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1)                                                        AS avg_playtime_hrs,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY g.average_playtime_forever) / 60.0)::NUMERIC, 1)     AS median_playtime_hrs
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN tags      t  ON t.tag_id = gt.tag_id
WHERE g.average_playtime_forever > 0
GROUP BY t.tag_name
HAVING COUNT(DISTINCT g.appid) >= 20
ORDER BY avg_playtime_hrs DESC
LIMIT 30;


-- ────────────────────────────────────────────────────────────
-- KPI 1B: Top tags by playtime — do high-playtime tags also
--         tend to have achievements? (correlation view)
-- ────────────────────────────────────────────────────────────
SELECT
    t.tag_name,
    COUNT(DISTINCT g.appid)                                          AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1)                AS avg_playtime_hrs,
    ROUND(AVG(g.achievements), 0)                                   AS avg_achievements,
    -- bucket achievements into bands so Power BI can colour-code easily
    CASE
        WHEN AVG(g.achievements) = 0        THEN 'None'
        WHEN AVG(g.achievements) < 15       THEN 'Low  (1–14)'
        WHEN AVG(g.achievements) < 50       THEN 'Mid  (15–49)'
        WHEN AVG(g.achievements) < 100      THEN 'High (50–99)'
        ELSE                                     'Very High (100+)'
    END                                                              AS achievement_band,
    ROUND(CORR(
        g.average_playtime_forever,
        g.achievements
    )::NUMERIC, 3)                                                   AS playtime_achievement_corr
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN tags      t  ON t.tag_id = gt.tag_id
WHERE g.average_playtime_forever > 0
GROUP BY t.tag_name
HAVING COUNT(DISTINCT g.appid) >= 20
ORDER BY avg_playtime_hrs DESC
LIMIT 30;


-- ────────────────────────────────────────────────────────────
-- KPI 3: Games released per year, per tag (trend volume)
-- Use the top 15 tags by total game count to keep the chart
-- readable; adjust the inner CTE to change which tags appear.
-- ────────────────────────────────────────────────────────────
WITH top_tags AS (
    -- Identify the 15 most common tags overall
    SELECT t.tag_id, t.tag_name
    FROM tags t
    ORDER BY t.game_count DESC
    LIMIT 15
),
yearly AS (
    SELECT
        EXTRACT(YEAR FROM g.release_date_parsed)::INT   AS release_year,
        tt.tag_name,
        COUNT(DISTINCT g.appid)                         AS games_released
    FROM games g
    JOIN game_tags gt ON gt.appid = g.appid
    JOIN top_tags  tt ON tt.tag_id = gt.tag_id
    WHERE g.release_date_parsed IS NOT NULL
      AND g.release_date_parsed >= '2000-01-01'   -- pre-2000 data is sparse/unreliable
      AND g.release_date_parsed <  CURRENT_DATE
    GROUP BY 1, 2
)
SELECT
    release_year,
    tag_name,
    games_released,
    -- running total per tag so Power BI can draw a cumulative line
    SUM(games_released) OVER (
        PARTITION BY tag_name
        ORDER BY release_year
    )                                                   AS cumulative_games
FROM yearly
ORDER BY tag_name, release_year;


-- ────────────────────────────────────────────────────────────
-- KPI 4: Average playtime by price bracket
-- ────────────────────────────────────────────────────────────
SELECT
    CASE
        WHEN price_usd IS NULL      THEN 'Unknown'
        WHEN price_usd =  0         THEN 'Free'
        WHEN price_usd <  5         THEN '$0.01 – $4.99'
        WHEN price_usd < 10         THEN '$5 – $9.99'
        WHEN price_usd < 20         THEN '$10 – $19.99'
        WHEN price_usd < 30         THEN '$20 – $29.99'
        WHEN price_usd < 40         THEN '$30 – $39.99'
        WHEN price_usd < 60         THEN '$40 – $59.99'
        ELSE                             '$60+'
    END                                                             AS price_bracket,
    -- bracket sort key so Power BI orders the axis correctly
    CASE
        WHEN price_usd IS NULL      THEN 0
        WHEN price_usd =  0         THEN 1
        WHEN price_usd <  5         THEN 2
        WHEN price_usd < 10         THEN 3
        WHEN price_usd < 20         THEN 4
        WHEN price_usd < 30         THEN 5
        WHEN price_usd < 40         THEN 6
        WHEN price_usd < 60         THEN 7
        ELSE                             8
    END                                                             AS sort_order,
    COUNT(*)                                                        AS game_count,
    ROUND(AVG(average_playtime_forever)  / 60.0, 1)                 AS avg_playtime_hrs,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP
      (ORDER BY average_playtime_forever) / 60.0)::NUMERIC, 1)      AS median_playtime_hrs,
    ROUND(AVG(positive_reviews + negative_reviews), 0)              AS avg_review_count
FROM games
WHERE average_playtime_forever > 0
GROUP BY 1, 2
ORDER BY sort_order;


-- ────────────────────────────────────────────────────────────
-- KPI 5A: Free-to-Play vs Paid — top-level comparison
--
-- Note: this divides the group's average playtime by the group's average price
-- (ratio of averages), not the average of per-game (playtime / price) ratios.
-- Directionally correct for comparison but not a per-game efficiency figure.
-- Free games produce NULL here intentionally — Power BI can label these separately.
-- ────────────────────────────────────────────────────────────
SELECT
    CASE WHEN price_usd = 0 THEN 'Free to Play' ELSE 'Paid' END     AS model,
    COUNT(*)                                                          AS game_count,
    ROUND(AVG(price_usd)::NUMERIC, 2)                               AS avg_price_usd,
ROUND(AVG(average_playtime_forever)::NUMERIC / 60.0, 1)         AS avg_playtime_hrs,
ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP
      (ORDER BY average_playtime_forever))::NUMERIC / 60.0, 1)  AS median_playtime_hrs,
ROUND((AVG(average_playtime_forever) /
      NULLIF(LEAST(AVG(price_usd), 999), 0) / 60.0)::NUMERIC, 1) AS playtime_hrs_per_dollar,
ROUND(AVG(achievements)::NUMERIC, 1)                             AS avg_achievements,
    ROUND(AVG(
        positive_reviews::NUMERIC /
        NULLIF(positive_reviews + negative_reviews, 0) * 100
    ), 1)                                                            AS avg_approval_pct
FROM games
WHERE average_playtime_forever > 0
  AND price_usd IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- ────────────────────────────────────────────────────────────
-- KPI 5B: Free-to-Play vs Paid broken down by tag
-- Useful for Power BI clustered bar / small multiples
-- ────────────────────────────────────────────────────────────
WITH top_tags AS (
    SELECT t.tag_id, t.tag_name
    FROM tags t
    ORDER BY t.game_count DESC
    LIMIT 20
)
SELECT
    tt.tag_name,
    CASE WHEN g.price_usd = 0 THEN 'Free to Play' ELSE 'Paid' END   AS model,
    COUNT(DISTINCT g.appid)                                           AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1)                AS avg_playtime_hrs,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP
      (ORDER BY g.average_playtime_forever) / 60.0)::NUMERIC, 1)          AS median_playtime_hrs
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN top_tags  tt ON tt.tag_id = gt.tag_id
WHERE g.average_playtime_forever > 0
  AND g.price_usd IS NOT NULL
GROUP BY 1, 2
HAVING COUNT(DISTINCT g.appid) >= 10
ORDER BY tag_name, model;


-- ────────────────────────────────────────────────────────────
-- KPI 8: Tags associated with the highest review scores
-- Weighted score blends approval % with review volume so that
-- a tag with 1 five-star review doesn't rank above one with
-- 50,000 positive reviews and 95 % approval.
-- Wilson lower-bound approximation is used as the weighted sort.
-- ────────────────────────────────────────────────────────────
WITH tag_reviews AS (
    SELECT
        t.tag_name,
        COUNT(DISTINCT g.appid)                                          AS game_count,
        SUM(g.positive_reviews)                                          AS total_positive,
        SUM(g.negative_reviews)                                          AS total_negative,
        SUM(g.positive_reviews + g.negative_reviews)                     AS total_reviews,
        -- simple average approval across games in this tag
        ROUND(AVG(
            g.positive_reviews::NUMERIC /
            NULLIF(g.positive_reviews + g.negative_reviews, 0) * 100
        ), 1)                                                            AS avg_approval_pct,
        -- aggregate approval across all reviews pooled for the tag
        ROUND(
            SUM(g.positive_reviews)::NUMERIC /
            NULLIF(SUM(g.positive_reviews + g.negative_reviews), 0) * 100
        , 1)                                                             AS pooled_approval_pct
    FROM games g
    JOIN game_tags gt ON gt.appid = g.appid
    JOIN tags      t  ON t.tag_id = gt.tag_id
    WHERE (g.positive_reviews + g.negative_reviews) >= 10  -- ignore games with almost no reviews
    GROUP BY t.tag_name
    HAVING COUNT(DISTINCT g.appid) >= 20
       AND SUM(g.positive_reviews + g.negative_reviews) >= 500
),
scored AS (
    SELECT
        *,
        -- Wilson lower bound (z=1.645 → 95 % confidence, one-sided)
        -- Penalises tags whose approval % comes from few reviews.
        ROUND((
            (total_positive::NUMERIC / NULLIF(total_reviews, 0))
            + (1.645 * 1.645) / (2.0 * total_reviews)
            - 1.645 * SQRT(
    GREATEST(
        (total_positive::NUMERIC / NULLIF(total_reviews, 0))
        * (1 - total_positive::NUMERIC / NULLIF(total_reviews, 0))
        / total_reviews
        + (1.645 * 1.645) / (4.0 * total_reviews * total_reviews),
        0
    )
)
        ) / (1 + (1.645 * 1.645) / total_reviews) * 100, 2)           AS wilson_score
    FROM tag_reviews
)
SELECT
    tag_name,
    game_count,
    total_reviews,
    avg_approval_pct,
    pooled_approval_pct,
    wilson_score
FROM scored
ORDER BY wilson_score DESC
LIMIT 30;

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