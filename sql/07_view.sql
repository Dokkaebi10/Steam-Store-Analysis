-- source for KPI 1 bar/scatter chart
-- no LIMIT — apply in Power BI or the consuming query
-- no ORDER BY — sort in Power BI
CREATE OR REPLACE VIEW v_kpi_playtime_by_tag AS
SELECT
    t.tag_name,
    COUNT(DISTINCT g.appid)                                             AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1)                    AS avg_playtime_hrs,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP
      (ORDER BY g.average_playtime_forever) / 60.0)::NUMERIC, 1)        AS median_playtime_hrs,
    ROUND(AVG(g.achievements), 0)                                       AS avg_achievements,
    ROUND(CORR(g.average_playtime_forever, g.achievements)::NUMERIC, 3) AS playtime_achievements_corr,
    CASE
        WHEN AVG(g.achievements) = 0   THEN 'None'
        WHEN AVG(g.achievements) < 15  THEN 'Low (1–14)'
        WHEN AVG(g.achievements) < 50  THEN 'Mid (15–49)'
        WHEN AVG(g.achievements) < 100 THEN 'High (50–99)'
        ELSE                                'Very High (100+)'
    END                                                                 AS achievement_band
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN tags      t  ON t.tag_id = gt.tag_id
WHERE g.average_playtime_forever > 0
GROUP BY t.tag_name
HAVING COUNT(DISTINCT g.appid) >= 20;
-- Power BI usage: ORDER BY avg_playtime_hrs DESC, LIMIT 30 (or use Top N filter)

-- source for KPI 3 trend line / stacked bar
CREATE OR REPLACE VIEW v_kpi_releases_by_year_tag AS
SELECT
    EXTRACT(YEAR FROM g.release_date_parsed)::INT                   AS release_year,
    t.tag_name,
    t.game_count                                                    AS tag_total_game_count,
    COUNT(DISTINCT g.appid)                                         AS games_released,
    SUM(COUNT(DISTINCT g.appid)) OVER (
        PARTITION BY t.tag_name
        ORDER BY EXTRACT(YEAR FROM g.release_date_parsed)::INT
    )                                                               AS cumulative_games
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN tags      t  ON t.tag_id = gt.tag_id
WHERE g.release_date_parsed IS NOT NULL
  AND g.release_date_parsed >= '2000-01-01'
  AND g.release_date_parsed <  CURRENT_DATE
GROUP BY 1, 2, 3;
-- Power BI usage: filter tag_total_game_count to top 15 (or use a slicer on tag_name)
-- tag_total_game_count is exposed so Power BI can rank/filter tags without a second query

-- source for KPI 4 column chart
CREATE OR REPLACE VIEW v_kpi_playtime_by_price AS
SELECT
    CASE
        WHEN price_usd IS NULL THEN 'Unknown'
        WHEN price_usd =  0    THEN 'Free'
        WHEN price_usd <  5    THEN '$0.01–$4.99'
        WHEN price_usd < 10    THEN '$5–$9.99'
        WHEN price_usd < 20    THEN '$10–$19.99'
        WHEN price_usd < 30    THEN '$20–$29.99'
        WHEN price_usd < 40    THEN '$30–$39.99'
        WHEN price_usd < 60    THEN '$40–$59.99'
        ELSE                        '$60+'
    END                                                             AS price_bracket,
    -- sort_order lets Power BI sort the axis correctly without
    -- relying on alphabetical ordering of the label strings
    CASE
        WHEN price_usd IS NULL THEN 0
        WHEN price_usd =  0    THEN 1
        WHEN price_usd <  5    THEN 2
        WHEN price_usd < 10    THEN 3
        WHEN price_usd < 20    THEN 4
        WHEN price_usd < 30    THEN 5
        WHEN price_usd < 40    THEN 6
        WHEN price_usd < 60    THEN 7
        ELSE                        8
    END                                                             AS sort_order,
    COUNT(*)                                                        AS game_count,
    ROUND(AVG(average_playtime_forever)  / 60.0, 1)                AS avg_playtime_hrs,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP
      (ORDER BY average_playtime_forever) / 60.0)::NUMERIC, 1)           AS median_playtime_hrs,
    ROUND(AVG(positive_reviews + negative_reviews), 0)             AS avg_review_count
FROM games
WHERE average_playtime_forever > 0
GROUP BY 1, 2;
-- Power BI usage: sort axis by sort_order (ascending)


-- source for KPI 5 clustered bar / small multiples
CREATE OR REPLACE VIEW v_kpi_f2p_vs_paid AS
SELECT
    t.tag_name,
    t.game_count                                                    AS tag_total_game_count,
    CASE WHEN g.price_usd = 0 THEN 'Free to Play' ELSE 'Paid' END  AS model,
    COUNT(DISTINCT g.appid)                                         AS game_count,
    ROUND(AVG(g.average_playtime_forever) / 60.0, 1)               AS avg_playtime_hrs,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP
      (ORDER BY g.average_playtime_forever) / 60.0)::NUMERIC, 1)         AS median_playtime_hrs,
    ROUND(AVG(
        g.positive_reviews::NUMERIC /
        NULLIF(g.positive_reviews + g.negative_reviews, 0) * 100
    ), 1)                                                           AS avg_approval_pct
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN tags      t  ON t.tag_id = gt.tag_id
WHERE g.average_playtime_forever > 0
  AND g.price_usd IS NOT NULL
GROUP BY 1, 2, 3
HAVING COUNT(DISTINCT g.appid) >= 10;
-- Power BI usage: filter tag_total_game_count to Top N for readable charts

-- source for KPI 5A horizontal bar
-- Note: this divides the group's average playtime by the group's average price
-- (ratio of averages), not the average of per-game (playtime / price) ratios.
-- Directionally correct for comparison but not a per-game efficiency figure.
-- Free games produce NULL here intentionally — Power BI can label these separately.
CREATE OR REPLACE VIEW v_kpi_f2p_vs_paid_summary AS
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
GROUP BY 1;

-- Source for KPI 8 horizontal bar (sort by wilson_score)
CREATE OR REPLACE VIEW v_kpi_review_scores_by_tag AS
WITH tag_reviews AS (
    SELECT
        t.tag_name,
        COUNT(DISTINCT g.appid)                                         AS game_count,
        SUM(g.positive_reviews)                                         AS total_positive,
        SUM(g.positive_reviews + g.negative_reviews)                    AS total_reviews,
        ROUND(AVG(
            g.positive_reviews::NUMERIC /
            NULLIF(g.positive_reviews + g.negative_reviews, 0) * 100
        ), 1)                                                           AS avg_approval_pct,
        ROUND(
            SUM(g.positive_reviews)::NUMERIC /
            NULLIF(SUM(g.positive_reviews + g.negative_reviews), 0) * 100
        , 1)                                                            AS pooled_approval_pct
    FROM games g
    JOIN game_tags gt ON gt.appid = g.appid
    JOIN tags      t  ON t.tag_id = gt.tag_id
    WHERE (g.positive_reviews + g.negative_reviews) >= 10
    GROUP BY t.tag_name
    HAVING COUNT(DISTINCT g.appid) >= 20
       AND SUM(g.positive_reviews + g.negative_reviews) >= 500
)
SELECT
    tag_name,
    game_count,
    total_reviews,
    avg_approval_pct,
    pooled_approval_pct,
    -- Wilson lower bound (95 % CI, z = 1.645, one-sided).
    -- Conservative, volume-adjusted score: a tag with 1,000
    -- reviews at 90 % approval ranks above one with 10 reviews
    -- at 95 % approval.
    -- GREATEST(..., 0) prevents a runtime error from floating-
    -- point imprecision producing a tiny negative radicand.
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
    ) / (1 + (1.645 * 1.645) / total_reviews) * 100, 2)               AS wilson_score
FROM tag_reviews;
-- Power BI usage: sort by wilson_score DESC, apply Top N filter for chart.

-- Verify all views exist
SELECT viewname
FROM   pg_views
WHERE  schemaname = 'public'
  AND  viewname LIKE 'v_kpi_%'
ORDER  BY viewname;