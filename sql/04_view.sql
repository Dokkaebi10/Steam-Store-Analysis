CREATE OR REPLACE VIEW v_top10_games AS
SELECT
  appid, name, peak_ccu,
  price_usd, estimated_owners,
  ROUND(positive_reviews::NUMERIC /
    NULLIF(positive_reviews + negative_reviews, 0) * 100, 1
  ) AS approval_pct
FROM games
ORDER BY peak_ccu DESC
LIMIT 10;

CREATE OR REPLACE VIEW v_monthly_trend AS
SELECT
  DATE_TRUNC('month', release_date_parsed) AS month,
  COUNT(*)                                  AS games_released,
  SUM(peak_ccu)                             AS total_peak_players,
  ROUND(AVG(price_usd)::NUMERIC, 2)         AS avg_price
FROM games
WHERE release_date_parsed IS NOT NULL
GROUP BY 1
ORDER BY 1;

CREATE OR REPLACE VIEW v_revenue_by_tag AS
SELECT
  t.tag_name,
  COUNT(DISTINCT g.appid)              AS game_count,
  ROUND(AVG(g.price_usd)::NUMERIC, 2) AS avg_price,
  SUM(g.price_usd * g.peak_ccu)       AS est_revenue,
  SUM(gt.votes)                        AS total_votes
FROM games g
JOIN game_tags gt ON gt.appid = g.appid
JOIN tags t       ON t.tag_id = gt.tag_id
WHERE g.price_usd IS NOT NULL
GROUP BY t.tag_name
ORDER BY est_revenue DESC NULLS LAST;

CREATE OR REPLACE VIEW v_playtime AS
SELECT
  name,
  ROUND(average_playtime_forever / 60.0, 1) AS avg_hrs,
  ROUND(median_playtime_forever  / 60.0, 1) AS median_hrs,
  peak_ccu, price_usd
FROM games
WHERE average_playtime_forever > 0
ORDER BY average_playtime_forever DESC
LIMIT 20;

-- Verify all views exist
\dv