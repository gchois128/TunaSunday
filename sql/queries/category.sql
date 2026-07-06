-- =============================================================================
-- Category Intelligence — module queries
-- Bind params:  :category_id ,  :window_months (default 12)
-- Reads: sm_category_volume, sm_brand_trend, sm_concept_trend (semantic layer)
--        + concept_mentions / v_reviews_unified for evidence.
-- =============================================================================


-- Q1 ── Category overview KPIs ─────────────────────────────────────────────────
-- Distinct review volume + growth + sentiment + brand count.
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_category_volume),
vol AS (
    SELECT
        SUM(reviews)                                                          AS reviews_all,
        SUM(reviews) FILTER (WHERE period
              >= (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => :window_months)) AS reviews_window,
        SUM(reviews) FILTER (WHERE period
              >= (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => 2*:window_months)
              AND period < (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => :window_months)) AS reviews_prior,
        MAX(brands)                                                           AS brands,
        AVG(avg_rating)                                                       AS avg_rating
    FROM sm_category_volume
    WHERE category_id = :category_id
),
sent AS (   -- market net sentiment in latest period
    SELECT SUM(t.avg_sentiment * t.mentions) / NULLIF(SUM(t.mentions),0) AS avg_sentiment
    FROM sm_concept_trend t, bounds
    WHERE t.scope_type='category' AND t.scope_id=:category_id AND t.period=bounds.max_p
)
SELECT vol.reviews_all, vol.reviews_window, vol.brands, vol.avg_rating,
       sent.avg_sentiment,
       (vol.reviews_window::numeric / NULLIF(vol.reviews_prior,0) - 1) AS growth_yoy
FROM vol, sent;


-- Q2 ── Brand leaderboard ──────────────────────────────────────────────────────
-- SoV, sentiment, rank; volume joined from unified reviews (distinct, correct).
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts)
SELECT
    r.brand_name,
    bt.brand_id,
    bt.sov,
    bt.sov_rank,
    bt.avg_sentiment,
    bv.reviews AS reviews_latest_month
FROM sm_brand_trend bt, bounds
JOIN LATERAL (SELECT DISTINCT brand_id, brand_name FROM v_reviews_unified) r
       ON r.brand_id = bt.brand_id
LEFT JOIN sm_brand_volume bv
       ON bv.brand_id = bt.brand_id AND bv.period = bt.period
WHERE bt.category_id = :category_id
  AND bt.period = bounds.max_p
ORDER BY bt.sov DESC;


-- Q3 ── Concept landscape (dominant benefits vs complaints) ────────────────────
-- Aggregate the category's mentions over the window, split by kind.
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
agg AS (
    SELECT t.concept_id,
           SUM(t.mentions)                                              AS mentions,
           SUM(t.avg_sentiment*t.mentions)/NULLIF(SUM(t.mentions),0)    AS avg_sentiment
    FROM sm_concept_trend t, bounds
    WHERE t.scope_type='category' AND t.scope_id=:category_id
      AND t.period >= bounds.max_p - MAKE_INTERVAL(months => :window_months)
    GROUP BY t.concept_id
)
SELECT c.concept_kind, c.concept_label, a.mentions, a.avg_sentiment,
       a.mentions::numeric / SUM(a.mentions) OVER () AS share_of_mention
FROM agg a
JOIN sm_concept c USING (concept_id)
ORDER BY a.mentions DESC;


-- Q4 ── Category trend + top rising concepts ───────────────────────────────────
-- (a) category volume & sentiment series:
SELECT v.period, v.reviews, v.avg_rating,
       t.avg_sentiment
FROM sm_category_volume v
LEFT JOIN (
    SELECT scope_id AS category_id, period,
           SUM(avg_sentiment*mentions)/NULLIF(SUM(mentions),0) AS avg_sentiment
    FROM sm_concept_trend WHERE scope_type='category'
    GROUP BY scope_id, period
) t ON t.category_id = v.category_id AND t.period = v.period
WHERE v.category_id = :category_id
ORDER BY v.period;

-- (b) top rising concepts in-category (latest period, by velocity, volume-floored):
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts)
SELECT c.concept_label, c.concept_kind, t.som, t.velocity, t.acceleration, t.mentions
FROM sm_concept_trend t, bounds
JOIN sm_concept c USING (concept_id)
WHERE t.scope_type='category' AND t.scope_id=:category_id
  AND t.period = bounds.max_p
  AND t.mentions >= 30                    -- volume floor: suppress small-sample noise
ORDER BY t.velocity DESC NULLS LAST
LIMIT 15;


-- Q5 ── Verbatim drill-down for a concept in the category ───────────────────────
-- Bind: :category_id, :concept_id, :limit (default 20)
SELECT r.review_id, r.brand_name, r.review_date, r.rating, r.source,
       m.sentiment, r.review_text, m.snippet
FROM concept_mentions m
JOIN v_reviews_unified r ON r.review_id = m.review_id
WHERE m.concept_id = :concept_id
  AND r.category_id = :category_id
ORDER BY r.review_date DESC
LIMIT :limit;
