-- Step 1: staging table to hold raw JSON
CREATE TABLE IF NOT EXISTS raw_steam_blob (data JSONB);

CREATE TABLE IF NOT EXISTS raw_steam AS
SELECT 
    key AS app_id,
    values AS DATA
FROM raw_steam_blob, jsonb_each(data);
