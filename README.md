# Steam-Store-Analysis

Analysis of video games listed on the Steam Store using the Kaggle Dataset "Steam Games Dataset" by Martin Bustos. This a self-learning project where Python is used to load the dataset (json), SQL is used to create the tables and handle the data, and Power BI is used for the dashboard. 

This Project is a way for me to strengthen my Python skills and apply my more new skills with SQL and Power BI.
I am mainly learning through Claude and GitHub Copilot.

# KPI
1. Average playtime by tags
- Which tags are associated with the longest average playtime?
- Additionally, compare if highest playtimes also have acheievments
2. Top 10 publishers/developers by total review
- Leaderboard of publishers by ratio of positive and negative reviews
3. Games released per year
- Trend of volume within gaming industry
4. Average playtime by price
- Moneys worth of games
5. Average playtime for Free to Play vs Average playtime for Paid
- Comparison of free to play and paid gaming models
- Further comparison between tags
8. Which tags are associated with the highest review scores?

# KPI Considerations
7. What price range has the most estimated owners on average?


## Getting the data
1. Download from Kaggle: [Steam Games Dataset by Martin Bustos](kaggle link)
2. Place `games.json` in the `data/` folder
3. Run the scripts in numerical order

## Pipeline
Python (ETL) → PostgreSQL (storage) → SQL Views (data prep) → Power BI (visualization)

## Tables Schema
games       game_tags (bridge)    tags
─────       ──────────────────    ────
appid  ──── appid                 tag_id
name        tag_id ───────────── tag_name
...         votes

## Python Script
Raw JSON (one big blob)
        │
        ▼
   [Extract]  Load into DataFrame
        │
        ▼
   [Transform] Clean types, filter junk, flatten lists
        │
        ▼
   [Load] Write 3 tables to PostgreSQL:
        ├── games      (one row per game)
        ├── tags       (one row per unique tag)
        └── game_tags  (bridge: game ↔ tag with vote weight)