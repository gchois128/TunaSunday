-- =============================================================================
-- Beauty Market Intelligence Terminal — Semantic / Metrics Layer
-- =============================================================================
-- ONE definition each of the core metrics, built on the real Concept Engine
-- tables. Every module reads these views; no module re-derives a metric.
--
--   Primary metrics source : concept_timeseries   (56,965 rows)
--   Evidence / drill-down  : concept_mentions      (655,166 rows) + v_reviews_unified
--   Dictionaries           : concepts (53) -> concept_dimensions ; concept_terms (211)
--
-- Column names are assumptions isolated to sm_scope_ts (see SCHEMA_ASSUMPTIONS.md).
-- Fix a wrong name there ONCE and everything below still works.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A0. ADAPTER — the ONLY place raw column names appear.
--     Normalizes concept_timeseries into a long, scope-tagged shape:
--       scope_type ∈ ('brand','category','global'),  scope_id = brand/category id (NULL global)
--     Category & global scopes are aggregated from the finest grain so this works
--     whether or not the timeseries stores pre-rolled category/global rows.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sm_scope_ts AS
-- brand scope: straight from the finest grain
SELECT
    'brand'::text        AS scope_type,
    ts.brand_id          AS scope_id,
    ts.category_id       AS category_id,
    ts.concept_id        AS concept_id,
    ts.period            AS period,
    ts.mention_count     AS mentions,
    ts.review_count      AS reviews,      -- per-concept; do NOT sum across concepts for volume
    ts.avg_sentiment     AS avg_sentiment
FROM concept_timeseries ts
WHERE ts.brand_id IS NOT NULL

UNION ALL
-- category scope: aggregate brands within a category (volume-weighted sentiment)
SELECT
    'category', ts.category_id, ts.category_id, ts.concept_id, ts.period,
    SUM(ts.mention_count),
    SUM(ts.review_count),
    SUM(ts.avg_sentiment * ts.mention_count) / NULLIF(SUM(ts.mention_count), 0)
FROM concept_timeseries ts
WHERE ts.category_id IS NOT NULL
GROUP BY ts.category_id, ts.concept_id, ts.period

UNION ALL
-- global scope: whole market
SELECT
    'global', NULL, NULL, ts.concept_id, ts.period,
    SUM(ts.mention_count),
    SUM(ts.review_count),
    SUM(ts.avg_sentiment * ts.mention_count) / NULLIF(SUM(ts.mention_count), 0)
FROM concept_timeseries ts
GROUP BY ts.concept_id, ts.period;

-- ── VARIANT (fact #1) ────────────────────────────────────────────────────────
-- If concept_timeseries has NO brand grain, derive the brand branch from mentions:
--   SELECT 'brand', r.brand_id, r.category_id, m.concept_id, date_trunc('month', r.review_date)::date,
--          count(*), count(DISTINCT m.review_id), avg(m.sentiment)
--   FROM concept_mentions m JOIN v_reviews_unified r USING (review_id)
--   GROUP BY 1,2,3,4,5
-- ─────────────────────────────────────────────────────────────────────────────


-- -----------------------------------------------------------------------------
-- A1. concepts + their dimension/kind, resolved once.
--     kind drives the Loved (benefit) vs Hated (complaint) split everywhere.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sm_concept AS
SELECT
    c.concept_id,
    c.label                                   AS concept_label,
    d.dimension_id,
    d.name                                    AS dimension_name,
    d.kind                                    AS concept_kind          -- benefit | complaint | attribute | ...
FROM concepts c
LEFT JOIN concept_dimensions d ON d.dimension_id = c.dimension_id;


-- -----------------------------------------------------------------------------
-- A2. CONCEPT TREND — Share-of-Mention, Velocity, Acceleration, per scope.
--     SoM         = concept mentions / all mentions in the same scope+period
--                   (normalized so corpus growth is NOT read as concept growth)
--     Velocity    = ΔSoM vs previous period
--     Acceleration= ΔVelocity  (= SoM_t − 2·SoM_{t-1} + SoM_{t-2})   ← Radar's core signal
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sm_concept_trend AS
WITH base AS (
    SELECT
        s.scope_type, s.scope_id, s.category_id, s.concept_id, s.period,
        s.mentions, s.reviews, s.avg_sentiment,
        s.mentions::numeric
            / NULLIF(SUM(s.mentions) OVER (PARTITION BY s.scope_type, s.scope_id, s.period), 0)
            AS som
    FROM sm_scope_ts s
)
SELECT
    b.*,
    b.som - LAG(b.som)      OVER w                                     AS velocity,
    b.som - 2 * LAG(b.som)  OVER w + LAG(b.som, 2) OVER w              AS acceleration
FROM base b
WINDOW w AS (PARTITION BY b.scope_type, b.scope_id, b.concept_id ORDER BY b.period);


-- -----------------------------------------------------------------------------
-- A3. BRAND TREND — brand mention volume, sentiment, and Share-of-Voice.
--     SoV = brand mentions / category mentions in the same period.
--     (Review VOLUME is NOT taken here — see volume note; use v_reviews_unified.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sm_brand_trend AS
WITH brand_tot AS (
    SELECT
        scope_id AS brand_id, category_id, period,
        SUM(mentions)                                              AS mentions,
        SUM(avg_sentiment * mentions) / NULLIF(SUM(mentions), 0)   AS avg_sentiment
    FROM sm_scope_ts
    WHERE scope_type = 'brand'
    GROUP BY scope_id, category_id, period
)
SELECT
    bt.*,
    bt.mentions::numeric
        / NULLIF(SUM(bt.mentions) OVER (PARTITION BY bt.category_id, bt.period), 0)
        AS sov,
    RANK() OVER (PARTITION BY bt.category_id, bt.period ORDER BY bt.mentions DESC) AS sov_rank,
    COUNT(*) OVER (PARTITION BY bt.category_id, bt.period)                         AS brands_in_category
FROM brand_tot bt;


-- -----------------------------------------------------------------------------
-- A4. CATEGORY TOTALS — distinct review volume comes from unified reviews
--     (the ONE correct source for volume; timeseries review_count double-counts).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW sm_category_volume AS
SELECT
    r.category_id,
    date_trunc('month', r.review_date)::date AS period,
    COUNT(*)                                  AS reviews,
    COUNT(DISTINCT r.brand_id)                AS brands,
    AVG(r.rating)                             AS avg_rating
FROM v_reviews_unified r
GROUP BY r.category_id, date_trunc('month', r.review_date)::date;

CREATE OR REPLACE VIEW sm_brand_volume AS
SELECT
    r.brand_id, r.category_id,
    date_trunc('month', r.review_date)::date AS period,
    COUNT(*)                                  AS reviews,
    AVG(r.rating)                             AS avg_rating
FROM v_reviews_unified r
GROUP BY r.brand_id, r.category_id, date_trunc('month', r.review_date)::date;

-- =============================================================================
-- METRIC GLOSSARY (single source of truth — also the UI tooltip text)
--   Share of Mention (SoM) : concept's share of all mentions in a scope+period
--   Share of Voice   (SoV) : brand's share of all mentions in its category+period
--   Velocity               : period-over-period change in SoM
--   Acceleration           : change in velocity  (Emerging Complaint Radar signal)
--   Net sentiment          : avg_sentiment in [-1,1], volume-weighted on aggregation
--   Review volume          : COUNT of review_id in v_reviews_unified (NEVER summed
--                            timeseries.review_count — that double-counts)
-- =============================================================================
