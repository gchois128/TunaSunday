# Product MVP — Implementation Plan

**Scope:** Dashboards over the **frozen** Concept Engine data. No ingestion, no
re-tagging, no automation. Read-only.

**Frozen snapshot**

| Table | Rows | Role |
|---|---|---|
| `v_reviews_unified` / base reviews | 509,506 | review text (drill-down) |
| `concept_mentions` | 655,166 | evidence / per-review concept links |
| `concept_timeseries` | 56,965 | **all metrics** |
| `concepts` + `concept_dimensions` | 53 | concept metadata / kind |
| `concept_terms` | 211 | lexicon (surfacing "why tagged") |

**Explicitly out of scope now:** `incremental_update.py`, `engine_dirty_months`,
pg_cron, automation, White Space Finder, Innovation Matrix. (Deferred, not deleted.)

---

## Build order

```
0. Shared foundation  →  1. Brand Intelligence Search  →  2. Market Pulse
   →  3. Consumer Shift  →  4. Emerging Complaint Radar  →  5. Category Intelligence
```

Brand first because it's the highest-value "look something up and get an answer"
surface and it exercises every primitive the later modules reuse.

---

## 0. Shared foundation (build once, all modules consume)

- **Semantic layer** — the SQL views in `sql/semantic_layer.sql` (SoM, SoV, velocity,
  acceleration, sentiment) + the TS wrapper in `web/lib/`. One definition per metric.
- **Data-access** — a single Postgres client (`web/lib/db.ts`), env-gated, read-only.
- **Terminal shell** — top bar with module tabs, global brand/category search, time-window
  filter, light/dark. (Prototyped in `prototype/brand-intelligence-search.html`.)
- **Reused components** — KPI tile, time-series chart, ranked-bar list, diverging bar,
  **verbatim drawer** (concept → representative reviews; used by all five modules).
- **Fixture layer** — every module ships fixtures shaped identically to its live query
  output, so the UI renders before the DB is connected and flips over by swapping one flag.

---

## 1. Brand Intelligence Search  ← START HERE

**Job:** type a brand → an instant competitive brief.

| View | Source | Query |
|---|---|---|
| Header KPIs (reviews TTM + Δ, avg rating, net sentiment, SoV + rank) | `v_reviews_unified` (volume/rating), `sm_brand_trend` (SoV/sentiment) | `sql/queries/brand.sql` Q1 |
| Loved / Hated concepts | `sm_concept_trend` (brand scope) + `sm_concept.kind` | Q2 |
| Volume & sentiment trend | `sm_brand_volume` + `sm_brand_trend` | Q3 |
| Competitive fingerprint (over/under-index vs category) | `sm_concept_trend` brand vs category SoM | Q4 |
| Verbatim drill-down | `concept_mentions` → `v_reviews_unified` | Q5 |

**Acceptance:** any brand resolves fast; SoV rank matches the Category module; every concept
row drills to real verbatims; header numbers reconcile with the category view.

## 2. Market Pulse

**Job:** "what's moving now." Top movers by **velocity** across concepts + category momentum.
Source: `sm_concept_trend` (global/category scope). First use of velocity; apply volume floors.

## 3. Consumer Shift

**Job:** structural multi-quarter shifts. Concept trajectories (SoM-normalized, smoothed),
rising/declining leaderboards over a chosen horizon, level×trend quadrant map.
Source: long `concept_timeseries` series.

## 4. Emerging Complaint Radar

**Job:** complaints accelerating before they're mainstream. Score = f(acceleration, recent
volume, novelty, breadth), complaint-kind concepts only. `acceleration` already exists in the
semantic layer. Validate with a historical backtest.

## 5. Category Intelligence

**Job:** category landscape — size/growth/sentiment, brand leaderboard, concept landscape,
rising concepts. Source: `sm_category_volume`, `sm_brand_trend`, `sm_concept_trend`.
Queries drafted in `sql/queries/category.sql`.

---

## Definition of done (Phase 1)

All five modules usable end-to-end on frozen data, sharing one metrics layer, every headline
number reconcilable across modules, every concept drillable to verbatims.

## Two schema facts that flip fixtures → live

1. `concept_timeseries` real grain + column names (assumed concept × brand × month).
2. `v_reviews_unified` column list + the `concepts→concept_dimensions` kind values.

Confirm these (or paste `\d+` / the `CREATE VIEW`) and `web/lib/` swaps from fixtures to live
with no UI change. Full detail in `sql/SCHEMA_ASSUMPTIONS.md`.
