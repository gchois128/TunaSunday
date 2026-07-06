/**
 * Brand Intelligence Search — production data layer.
 *
 * Drop this into the existing Next.js app. It returns exactly the shape the Brand
 * dashboard renders. Set USE_FIXTURES=1 (or leave DATABASE_URL unset) to render from
 * web/fixtures/brand.json; set DATABASE_URL to hit the real Concept Engine views.
 *
 * Reads ONLY: sm_* semantic-layer views (sql/semantic_layer.sql), v_reviews_unified,
 * concept_mentions. No writes. Mirrors sql/queries/brand.sql.
 */
import { Pool } from "pg";
import fixtures from "../fixtures/brand.json";

const USE_FIXTURES = process.env.USE_FIXTURES === "1" || !process.env.DATABASE_URL;
const pool = USE_FIXTURES ? null : new Pool({ connectionString: process.env.DATABASE_URL });

export type ConceptKind = "benefit" | "complaint" | "attribute" | "ingredient";

export interface BrandHeader {
  brandId: string;
  brandName: string;
  categoryId: string;
  categoryName: string;
  reviewsAll: number;
  reviewsWindow: number;
  reviewsWindowPrior: number; // for the Δ%
  avgRating: number;
  netSentiment: number; // [-1, 1]
  sov: number; // [0, 1]
  sovRank: number;
  brandsInCategory: number;
}
export interface ConceptStat {
  conceptId: string;
  label: string;
  kind: ConceptKind;
  mentions: number;
  share: number; // share of this brand's mentions
  sentiment: number;
}
export interface TrendPoint {
  period: string; // ISO month
  reviews: number;
  avgRating: number | null;
  netSentiment: number | null;
  sov: number | null;
}
export interface FingerprintRow {
  conceptId: string;
  label: string;
  kind: ConceptKind;
  brandSom: number;
  catSom: number;
  indexRatio: number; // brandSom / catSom  ( >1 = over-indexes )
}
export interface Verbatim {
  reviewId: string;
  reviewDate: string;
  rating: number | null;
  source: string;
  sentiment: number | null;
  text: string;
  snippet: string | null;
}
export interface BrandBrief {
  header: BrandHeader;
  loved: ConceptStat[];
  hated: ConceptStat[];
  trend: TrendPoint[];
  fingerprint: FingerprintRow[];
}

/** Full brief for one brand. */
export async function getBrandBrief(brandId: string, windowMonths = 12): Promise<BrandBrief> {
  if (USE_FIXTURES) return fixtures as unknown as BrandBrief;

  const [header, concepts, trend, fingerprint] = await Promise.all([
    q1Header(brandId, windowMonths),
    q2LovedHated(brandId, windowMonths),
    q3Trend(brandId),
    q4Fingerprint(brandId),
  ]);
  return {
    header,
    loved: concepts.filter((c) => c.kind === "benefit").sort((a, b) => b.mentions - a.mentions),
    hated: concepts.filter((c) => c.kind === "complaint").sort((a, b) => b.mentions - a.mentions),
    trend,
    fingerprint: fingerprint.sort((a, b) => b.indexRatio - a.indexRatio),
  };
}

/** Verbatims behind one concept for one brand (drill-down). */
export async function getBrandConceptVerbatims(
  brandId: string,
  conceptId: string,
  limit = 20,
): Promise<Verbatim[]> {
  if (USE_FIXTURES) {
    const all = (fixtures as any).verbatims?.[conceptId] ?? [];
    return all.slice(0, limit);
  }
  const { rows } = await pool!.query(
    `SELECT r.review_id       AS "reviewId",
            r.review_date::text AS "reviewDate",
            r.rating, r.source, m.sentiment,
            r.review_text     AS text, m.snippet
       FROM concept_mentions m
       JOIN v_reviews_unified r ON r.review_id = m.review_id
      WHERE m.concept_id = $1 AND r.brand_id = $2
      ORDER BY r.review_date DESC
      LIMIT $3`,
    [conceptId, brandId, limit],
  );
  return rows as Verbatim[];
}

// ── query implementations (mirror sql/queries/brand.sql) ─────────────────────
async function q1Header(brandId: string, windowMonths: number): Promise<BrandHeader> {
  const { rows } = await pool!.query(
    `WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
     vol AS (
       SELECT MAX(brand_name) AS brand_name, MAX(category_name) AS category_name,
              MAX(category_id) AS category_id,
              COUNT(*) AS reviews_all,
              COUNT(*) FILTER (WHERE review_date >= (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => $2)) AS reviews_window,
              COUNT(*) FILTER (WHERE review_date >= (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => 2*$2)
                                 AND review_date <  (SELECT max_p FROM bounds) - MAKE_INTERVAL(months => $2)) AS reviews_prior,
              AVG(rating) AS avg_rating
         FROM v_reviews_unified WHERE brand_id = $1
     ),
     pos AS (
       SELECT bt.sov, bt.avg_sentiment, bt.sov_rank, bt.brands_in_category
         FROM sm_brand_trend bt, bounds
        WHERE bt.brand_id = $1 AND bt.period = bounds.max_p
     )
     SELECT $1 AS "brandId", vol.brand_name AS "brandName", vol.category_id AS "categoryId",
            vol.category_name AS "categoryName", vol.reviews_all AS "reviewsAll",
            vol.reviews_window AS "reviewsWindow", vol.reviews_prior AS "reviewsWindowPrior",
            vol.avg_rating AS "avgRating", pos.avg_sentiment AS "netSentiment",
            pos.sov, pos.sov_rank AS "sovRank", pos.brands_in_category AS "brandsInCategory"
       FROM vol LEFT JOIN pos ON TRUE`,
    [brandId, windowMonths],
  );
  return rows[0] as BrandHeader;
}

async function q2LovedHated(brandId: string, windowMonths: number): Promise<ConceptStat[]> {
  const { rows } = await pool!.query(
    `WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
     agg AS (
       SELECT t.concept_id,
              SUM(t.mentions) AS mentions,
              SUM(t.avg_sentiment*t.mentions)/NULLIF(SUM(t.mentions),0) AS sentiment
         FROM sm_concept_trend t, bounds
        WHERE t.scope_type='brand' AND t.scope_id=$1
          AND t.period >= bounds.max_p - MAKE_INTERVAL(months => $2)
        GROUP BY t.concept_id
     )
     SELECT a.concept_id AS "conceptId", c.concept_label AS label, c.concept_kind AS kind,
            a.mentions, a.sentiment,
            a.mentions::float / SUM(a.mentions) OVER () AS share
       FROM agg a JOIN sm_concept c USING (concept_id)`,
    [brandId, windowMonths],
  );
  return rows as ConceptStat[];
}

async function q3Trend(brandId: string): Promise<TrendPoint[]> {
  const { rows } = await pool!.query(
    `SELECT v.period::text AS period, v.reviews, v.avg_rating AS "avgRating",
            bt.avg_sentiment AS "netSentiment", bt.sov
       FROM sm_brand_volume v
       LEFT JOIN sm_brand_trend bt ON bt.brand_id=v.brand_id AND bt.period=v.period
      WHERE v.brand_id = $1
      ORDER BY v.period`,
    [brandId],
  );
  return rows as TrendPoint[];
}

async function q4Fingerprint(brandId: string): Promise<FingerprintRow[]> {
  const { rows } = await pool!.query(
    `WITH bounds AS (SELECT MAX(period) AS max_p FROM sm_scope_ts),
     brand_som AS (
       SELECT t.concept_id, t.category_id, t.som FROM sm_concept_trend t, bounds
        WHERE t.scope_type='brand' AND t.scope_id=$1 AND t.period=bounds.max_p
     ),
     cat_som AS (
       SELECT t.concept_id, t.som AS cat_som FROM sm_concept_trend t, bounds
        WHERE t.scope_type='category' AND t.period=bounds.max_p
          AND t.scope_id=(SELECT DISTINCT category_id FROM brand_som)
     )
     SELECT b.concept_id AS "conceptId", c.concept_label AS label, c.concept_kind AS kind,
            b.som AS "brandSom", cs.cat_som AS "catSom",
            b.som/NULLIF(cs.cat_som,0) AS "indexRatio"
       FROM brand_som b JOIN cat_som cs USING (concept_id) JOIN sm_concept c USING (concept_id)`,
    [brandId],
  );
  return rows as FingerprintRow[];
}
