-- =============================================================================
-- Brand Intelligence Search — module queries
-- Bind params:  :brand_id ,  :window_months (default 12)
-- Reads: sm_brand_trend, sm_concept_trend, sm_brand_volume (semantic layer)
--        + v_reviews_unified / concept_mentions for evidence.
-- =============================================================================


-- Q1 ── Brand header KPIs ──────────────────────────────────────────────────────
-- Review volume (TTM + all-time, avg rating) from unified reviews;
-- SoV, sentiment, and rank-in-category from the semantic layer's latest period.
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
vol AS (
    SELECT
        COUNT(*)                                                              AS reviews_all,
        COUNT(*) FILTER (WHERE r.review_date
              >= (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => :window_months)) AS reviews_window,
        AVG(r.rating)                                                         AS avg_rating,
        MAX(r.brand_name)                                                     AS brand_name,
        MAX(r.category_name)                                                  AS category_name
    FROM v_reviews_unified r
    WHERE r.brand_id = :brand_id
),
pos AS (
    SELECT bt.sov, bt.avg_sentiment, bt.sov_rank, bt.brands_in_category
    FROM sm_brand_trend bt, bounds
    WHERE bt.brand_id = :brand_id AND bt.period = bounds.max_p
)
SELECT vol.brand_name, vol.category_name,
       vol.reviews_all, vol.reviews_window, vol.avg_rating,
       pos.sov, pos.avg_sentiment, pos.sov_rank, pos.brands_in_category
FROM vol LEFT JOIN pos ON TRUE;


-- Q2 ── Loved / Hated concepts ─────────────────────────────────────────────────
-- Aggregate this brand's mentions over the window; split by concept kind.
-- 'benefit' concepts ranked by volume = Loved;  'complaint' concepts = Hated.
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
agg AS (
    SELECT
        t.concept_id,
        SUM(t.mentions)                                              AS mentions,
        SUM(t.avg_sentiment * t.mentions) / NULLIF(SUM(t.mentions),0) AS avg_sentiment
    FROM sm_concept_trend t, bounds
    WHERE t.scope_type = 'brand'
      AND t.scope_id   = :brand_id
      AND t.period >= bounds.max_p - MAKE_INTERVAL(months => :window_months)
    GROUP BY t.concept_id
)
SELECT c.concept_kind, c.concept_label, a.mentions, a.avg_sentiment,
       RANK() OVER (PARTITION BY c.concept_kind ORDER BY a.mentions DESC) AS rank_in_kind
FROM agg a
JOIN sm_concept c USING (concept_id)
WHERE c.concept_kind IN ('benefit','complaint')
ORDER BY c.concept_kind, a.mentions DESC;


-- Q3 ── Volume & sentiment trend (chart series) ────────────────────────────────
-- Distinct review volume from unified reviews; concept sentiment from timeseries.
SELECT
    v.period,
    v.reviews,
    v.avg_rating,
    bt.avg_sentiment,
    bt.sov
FROM sm_brand_volume v
LEFT JOIN sm_brand_trend bt
       ON bt.brand_id = v.brand_id AND bt.period = v.period
WHERE v.brand_id = :brand_id
ORDER BY v.period;


-- Q4 ── Competitive fingerprint (over/under-index vs category) ──────────────────
-- For each concept: brand SoM vs category SoM in the latest period.
-- index_ratio > 1  => brand over-indexes on that concept vs its category.
WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
brand_som AS (
    SELECT t.concept_id, t.category_id, t.som
    FROM sm_concept_trend t, bounds
    WHERE t.scope_type='brand' AND t.scope_id=:brand_id AND t.period=bounds.max_p
),
cat_som AS (
    SELECT t.concept_id, t.som AS cat_som
    FROM sm_concept_trend t, bounds
    WHERE t.scope_type='category' AND t.period=bounds.max_p
      AND t.scope_id = (SELECT DISTINCT category_id FROM brand_som)
)
SELECT c.concept_label, c.concept_kind,
       b.som           AS brand_som,
       cs.cat_som,
       b.som / NULLIF(cs.cat_som, 0) AS index_ratio
FROM brand_som b
JOIN cat_som cs USING (concept_id)
JOIN sm_concept c USING (concept_id)
ORDER BY index_ratio DESC NULLS LAST;


-- Q5 ── Verbatim drill-down for one concept ────────────────────────────────────
-- Bind: :brand_id, :concept_id, :limit (default 20)
-- Evidence path the spec calls for: concept_mentions -> v_reviews_unified for text.
SELECT
    r.review_id, r.review_date, r.rating, r.source,
    m.sentiment,
    r.review_text,
    m.snippet
FROM concept_mentions m
JOIN v_reviews_unified r ON r.review_id = m.review_id
WHERE m.concept_id = :concept_id
  AND r.brand_id   = :brand_id
ORDER BY r.review_date DESC
LIMIT :limit;
