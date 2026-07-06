# Schema assumptions — CONFIRM THESE 6 FACTS

These SQL files are written against your **real** Concept Engine tables
(`concept_timeseries`, `concept_mentions`, `concepts`, `concept_dimensions`,
`concept_terms`, `v_reviews_unified`). I could not read the live DB or the local
repo from this container, so the **column names** below are inferred. All of them are
isolated inside one adapter view (`sm_scope_ts` in `semantic_layer.sql`) — if a name is
wrong, you fix it in exactly one place and every downstream query still works.

Reply with the real names (or paste `\d+ <table>` for these six tables) and I'll finalize.

| # | Fact to confirm | Assumed | Used by |
|---|---|---|---|
| 1 | **`concept_timeseries` grain + columns** — the big one | `(concept_id, brand_id, category_id, period DATE, mention_count, review_count, avg_sentiment)`, one row per concept × brand × month; `brand_id`/`category_id` present on each row | Every metric |
| 2 | **Concept → dimension link & dimension kind** | `concepts.dimension_id → concept_dimensions.dimension_id`; `concept_dimensions.kind ∈ {benefit, complaint, attribute, ingredient}` | Loved/Hated split, concept landscape |
| 3 | **Sentiment representation** | numeric net sentiment in `[-1, 1]` on `concept_timeseries.avg_sentiment` and `concept_mentions.sentiment` | Sentiment metrics |
| 4 | **`v_reviews_unified` columns** | `(review_id, product_id, brand_id, brand_name, category_id, category_name, rating, review_date, source, review_text)` | Volume, ratings, verbatims |
| 5 | **Does `concept_mentions` denormalize `brand_id`/`category_id`/`review_date`?** | No — assumed it carries only `(mention_id, review_id, concept_id, sentiment, snippet)` and we join to `v_reviews_unified` on `review_id` | Drill-down/evidence |
| 6 | **Primary-key naming** | `concepts.concept_id`, `concept_dimensions.dimension_id` (not `id`) | Joins |

### Grain note (fact #1, the one that matters most)

If `concept_timeseries` is **not** concept × brand × month, adjust only the `sm_scope_ts`
view:
- **concept × category × month** (no brand rows) → drop the `brand` UNION branch; brand-scope
  metrics then come from aggregating `concept_mentions` instead (a variant is noted in
  `semantic_layer.sql`).
- **concept × month only (global)** → keep only the `global` branch; brand/category scope come
  from `concept_mentions` joined to `v_reviews_unified`.
- **`entity_type` / `entity_id` shape** → map `entity_type='brand'|'category'` into the
  `scope_type`/`scope_id` columns in `sm_scope_ts`.

### Volume correctness note

`concept_timeseries.review_count` is **per concept** — a review mentioning 3 concepts is
counted in 3 rows. So **summing `review_count` across concepts double-counts reviews.** True
distinct review volume for a brand/category comes from `v_reviews_unified` (count of
`review_id`). The queries use timeseries for *mention share / SoV / sentiment* and
`v_reviews_unified` for *review volume* — deliberately, not interchangeably.
