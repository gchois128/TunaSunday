# Beauty Market Intelligence Terminal — Implementation Roadmap

**Reprioritized: Product-First**
_Last updated: 2026-07-06_

---

## 0. Context & the Reprioritization

The earlier audit was a **data-engineering** audit — it correctly identified gaps in
freshness, incremental processing, and operational hardening (`incremental_update.py`,
`engine_dirty_months`, `tagging_state`, scheduling, CI, tests).

Those findings still stand. What changes is **sequencing**, based on two facts:

1. **This is a product project right now, not a data-engineering project.** The value is
   the Beauty Market Intelligence Terminal that decision-makers use — not the pipeline
   that feeds it.
2. **The existing data is sufficient to build and validate v1.** We are not collecting
   new reviews right now, so **freshness is not the immediate priority.** The Concept
   Engine has already tagged the corpus into precomputed tables; that is a stable base to
   build a product on.

Therefore the pipeline hardening moves **after** the product is built and looks
executive-grade. We operationalize a product people already want — not a pipeline for a
product that doesn't exist yet.

### Priority order

| Phase | Goal | Theme |
|-------|------|-------|
| **Phase 1** | Build the complete Product MVP (5 modules) on the existing Concept Engine | Ship the product |
| **Phase 2** | Refine UX and executive presentation quality | Make it credible |
| **Phase 3** | Operationalize the platform (incremental pipeline, scheduling, CI, tests, deploy) | Make it durable |
| **Phase 4** | Build competitive-moat modules | Make it defensible |

---

## 1. Working Assumptions

These are inferred from the current setup (precomputed tables + local dashboard, no
Vercel yet). Correct any that are wrong and the affected sections adjust — nothing below
depends on more than these.

- **A1 — Data access:** The Concept Engine writes **precomputed tables** to a Postgres
  database (Supabase, on a separate account). All Phase 1 modules are **read-only** over
  those tables. No live engine calls, no re-tagging in the request path.
- **A2 — Frontend:** There is an existing **local dashboard** (localhost). Phase 1 extends
  it module by module. Assumed modern web stack (Next.js/React) since Vercel is the
  eventual target; if it is Streamlit/Dash/other, the module *specs* are unchanged, only
  the component mechanics differ.
- **A3 — Grain of the data:** Reviews carry `product → brand → category`, a `date`, a
  `rating`/`sentiment`, and a `source`. The Concept Engine emits **concept mentions** per
  review, where a concept has a `type` (benefit / attribute / ingredient / **complaint** /
  etc.) and sits in a taxonomy.
- **A4 — Time grain:** Monthly rollups are the working resolution for trends. (Weekly if
  volume supports it — decided per category by the volume floor in §6.)
- **A5 — No new collection during Phase 1–2.** A one-time full precompute is acceptable;
  incremental machinery is deliberately deferred to Phase 3.

> **The single most important input I still need:** the actual DDL / column names of the
> precomputed tables. Everything below is written as a **logical data contract** — map it
> to your real table/column names and the queries become concrete.

---

## 2. Architecture for Phase 1 (the foundation everything reuses)

All five modules answer questions over the **same primitives**: brand, product, category,
concept, complaint, time, volume, sentiment. If each module writes its own queries and its
own definition of "trend" or "share of voice," the terminal will contradict itself — the
fastest way to lose an executive's trust.

So the highest-leverage Phase 1 investment is a **shared semantic / metrics layer** sitting
between the precomputed tables and the modules.

```
┌─────────────────────────────────────────────────────────┐
│  Dashboard shell (nav, search, global filters, charts)   │  ← UI
├─────────────────────────────────────────────────────────┤
│  5 module views (Brand / Pulse / Shift / Radar / Category)│  ← per-module
├─────────────────────────────────────────────────────────┤
│  Semantic / Metrics layer  (ONE definition each of:      │  ← shared, the moat
│   share-of-voice, sentiment, velocity, acceleration,      │
│   novelty, saturation, demand, share-of-mention)          │
├─────────────────────────────────────────────────────────┤
│  Data-access layer (read-only queries over precomputed    │  ← shared
│   concept/complaint/rollup tables)                        │
├─────────────────────────────────────────────────────────┤
│  Precomputed Concept Engine tables (Postgres)             │  ← existing
└─────────────────────────────────────────────────────────┘
```

### Logical data contract (map to real tables)

**Base facts**

- `review(review_id, product_id, brand_id, category_id, date, rating, source)`
- `review_concept(review_id, concept_id, sentiment, weight)` — concept mentions per review
- `concept(concept_id, label, type, taxonomy_path)`
- `brand(brand_id, name, category_id)`, `product(...)`, `category(...)`

**Rollups (precompute these once in Phase 1; incrementalize in Phase 3)**

- `concept_month(concept_id, category_id, month, mention_count, review_count, pos_count, neg_count, avg_sentiment)`
- `brand_month(brand_id, category_id, month, review_count, avg_rating, avg_sentiment, mention_count)`
- `category_month(category_id, month, review_count, brand_count, mention_count, avg_sentiment)`

If these rollups don't exist yet, building them is **the first Phase 1 task** — they are
plain aggregations over data that's already tagged, cheap to materialize once.

### Metric definitions (single source of truth)

Defined **once**, in the semantic layer, and reused by every module and the tooltips:

- **Share of Voice (SoV)** = brand mentions ÷ category mentions, in window W.
- **Share of Mention (SoM)** = concept mentions ÷ total mentions in window W. _Always use
  SoM (not raw counts) for trend comparisons_ so overall corpus growth can't masquerade as
  concept growth.
- **Sentiment** = (pos − neg) ÷ total mentions (net sentiment), _or_ avg polarity — pick
  one, document it, use it everywhere.
- **Velocity** = slope / period-over-period % change of a SoM (or volume) series over W.
- **Acceleration** = change in velocity (2nd difference). _The core signal for the Radar._
- **Novelty** = recency of first material appearance + low trailing baseline.
- **Saturation** = # of brands/products materially addressing a concept.
- **Demand proxy** = mention volume (optionally weighted toward positive-intent mentions).

Every number the terminal shows resolves to one of these. Every chart tooltip cites the
definition.

---

## 3. Phase 1 — Product MVP

> **Definition of done for Phase 1:** All five modules are usable end-to-end against the
> real precomputed data on the local dashboard, share one metrics layer, and every headline
> number is reconcilable across modules (a brand's category-scoped stats match the Category
> module's, SoV sums to ~100%, etc.).

### 3.0 Shared foundation (build first)

| Deliverable | Notes |
|---|---|
| Rollup tables (`concept_month`, `brand_month`, `category_month`) | One-time materialization over existing tagged data |
| Data-access layer | Read-only, parameterized queries; no business logic |
| Semantic/metrics layer | Implements §2 definitions once |
| Dashboard shell | Global search, category + time-window filters, nav between modules |
| Shared components | Time-series chart, leaderboard/table, KPI header, **verbatim drill-down** (reused by every module) |
| Metric definitions doc | The tooltip source of truth |

### 3.1 Category Intelligence — _build first_

- **Purpose:** Deep-dive a single category — the competitive & needs landscape.
- **Answers:** Who leads? Which concepts dominate? What's the complaint landscape? Is it
  growing?
- **Data:** `category_month`, `brand_month` (in category), `concept_month` (in category).
- **Views:** category size + growth + sentiment + brand count; brand leaderboard (SoV /
  volume / sentiment); concept landscape (dominant benefits vs complaints); in-category
  trend + top rising concepts.
- **Acceptance:** category totals reconcile; a brand's in-category numbers match what the
  Brand module will show; complaint landscape is drillable to verbatims.
- **Why first:** pure "query + display," exercises the whole foundation, high exec value,
  no derivative math yet.

### 3.2 Brand Intelligence Search

- **Purpose:** Look up any brand → a full competitive-intelligence brief.
- **Answers:** How is brand X perceived? Loved for what, hated for what? Trending vs its
  category? What's its share of voice?
- **Data:** `brand_month`, `review_concept` filtered to brand, `category_month` for
  benchmarking.
- **Views:** brand header (volume + trend, rating/sentiment, SoV rank); **Loved / Hated**
  (top positive concepts, top complaint concepts); volume & sentiment trend; **competitive
  fingerprint** (what this brand over/under-indexes on vs category average); drill to
  representative verbatims per concept.
- **Acceptance:** search resolves any brand quickly; SoV rank consistent with Category
  module; verbatims match the concept clicked.

### 3.3 Market Pulse

- **Purpose:** "What's moving right now" — market-wide, current period.
- **Answers:** Which concepts/categories are rising or falling this period? Volume &
  sentiment shifts.
- **Data:** `concept_month`, `category_month`. _First module to use **velocity**._
- **Views:** top movers (rising benefits, rising complaints, by velocity); category
  momentum (volume & sentiment deltas); overall market sentiment index; now-vs-prior deltas
  with sparklines.
- **Acceptance:** movers list is deterministic and passes a manual spot-check; **volume
  floors** applied so small-sample concepts don't dominate the movers.

### 3.4 Consumer Shift

- **Purpose:** How consumer priorities evolve over **longer horizons** — structural shifts,
  not this-month noise.
- **Answers:** Which concerns are structurally rising/declining over 6–24 months? What's the
  trajectory shape?
- **Data:** long `concept_month` series (SoM-normalized), optionally per category.
- **Views:** concept-trajectory explorer (multi-year normalized lines); rising vs declining
  leaderboards over a chosen horizon (regression/smoothed, **not** single-month deltas);
  shift map (quadrant by level × trend: established / growing / declining / emerging).
- **Acceptance:** trajectories use SoM (normalized for corpus growth); smoothing method
  documented; partial end-months excluded so the last point isn't misleading.

### 3.5 Emerging Complaint Radar — _build last (composes everything)_

- **Purpose:** Early-warning on complaints **accelerating before they're mainstream.** The
  highest-signal, most defensible module.
- **Answers:** Which complaints are accelerating fastest? Which are genuinely new? Which
  brands/categories are driving them?
- **Data:** complaint-type concepts in `concept_month`; reuses velocity from Market Pulse +
  adds acceleration + novelty.
- **Core computation (define precisely):**
  - **Candidate** = complaint concept whose recent-window SoM is **accelerating** (positive
    2nd derivative) **AND** clears a volume floor **AND** is **novel** (low trailing
    baseline / recent first appearance).
  - **Score** = weighted(acceleration, recent absolute volume, novelty, breadth across
    brands).
- **Views:** radar leaderboard (score, velocity, first-seen, affected brands/categories,
  sample verbatims); detail (trajectory with the inflection highlighted, brands/products
  driving it). Alerting hooks left as stubs for Phase 3.
- **Acceptance:** **backtest** — a complaint that later became mainstream should have been
  flagged early from a historical cutoff; false-positive rate controlled by thresholds;
  every flag substantiated by verbatims.
- **Why last:** it composes volume floors + velocity + novelty + scoring and needs a
  backtest harness; building the earlier modules first supplies all its primitives.

### Phase 1 sequencing rationale

```
Foundation → Category → Brand → Market Pulse → Consumer Shift → Emerging Complaint Radar
  (shared)   (query+display, validate base)   (velocity)   (trajectories)   (accel+novelty+score)
```

Each module reuses the primitives the previous one introduced. Radar — the crown jewel —
comes last because it's the composition of everything before it.

---

## 4. Phase 2 — UX & Executive Presentation Quality

The MVP proves the *signal*. Phase 2 makes it *credible to an executive who won't read a
tooltip.*

- **Design system:** consistent typography, color, spacing; a coherent "terminal"
  aesthetic; light/dark.
- **Information hierarchy:** one headline metric + supporting detail per view; progressive
  disclosure (summary → drill → verbatims).
- **Auto-generated takeaways:** each view emits a plain-language one-liner —
  _"Sensitivity complaints in Cleansers accelerated ~3× since March, driven by 4 brands."_
  Generated from the same metrics layer, not hand-written.
- **Comparison & export:** side-by-side brand/category compare; PDF/PNG export that is
  **deck-ready**; shareable snapshot links.
- **Executive home:** a curated "what changed this period" landing view that synthesizes all
  five modules into the 5–7 things worth knowing.
- **Performance & polish:** skeleton loaders, query caching, empty/loading/error states,
  every metric tooltip'd with its definition.
- **Acceptance:** a non-technical exec can navigate unaided and walk away with a defensible
  insight; every chart has a plain-language takeaway; exports drop straight into a deck.

---

## 5. Phase 3 — Operationalize the Platform

Now — and only now — the audit's data-engineering findings get built, against a product
that has already proven its worth. Freshness becomes cheap right when you're ready to
resume collection.

- **`incremental_update.py`** — incremental ingestion + re-tag only changed data.
- **`engine_dirty_months`** — track which month-partitions changed so rollups
  (`concept_month`/`brand_month`/`category_month`) and Radar scores recompute **selectively**
  instead of full reprocessing.
- **`tagging_state`** — persistent, idempotent, resumable record of what's been tagged, and
  under **which taxonomy version** (so a taxonomy change can trigger targeted re-tagging).
- **Precompute/rollup pipeline** — materializes rollups + Radar scores on a schedule,
  incrementally via dirty months.
- **Scheduling** — cron/orchestration (Supabase scheduled functions / GitHub Actions /
  a scheduler) running incremental update → rollups → Radar.
- **CI** — lint, type-check, tests, migration checks gating every PR.
- **Tests** — engine unit tests (tagging correctness), **metric-layer tests** (SoV /
  velocity / SoM definitions), **Radar backtest as a regression test**, data-quality checks
  (row counts, null rates, cross-module reconciliation).
- **Deploy** — promote the local dashboard → Vercel; env/secret management; connect to the
  (separate-account) Supabase; logging + error tracking.
- **Acceptance:** a scheduled run ingests new data, re-tags only deltas, refreshes only
  dirty-month rollups, and redeploys; green CI gates merges; the Radar backtest runs in CI.

> **One guardrail kept in Phase 1 despite deferring tests:** carry a *lightweight*
> correctness net into Phase 1 — cross-module reconciliation asserts + the Radar backtest.
> They're cheap and the modules' credibility depends on the numbers being right. Full
> CI/test infrastructure still lands in Phase 3; this is just the minimum that protects the
> Phase 1 deliverable from silently lying.

---

## 6. Phase 4 — Competitive-Moat Modules

Built on the now-operational platform and a richer taxonomy. Sequenced so each feeds the
next.

1. **Concept Co-occurrence** _(foundation for the rest)_ — co-occurrence matrix of concepts
   within reviews → `concept_pair_month`, rendered as a network/graph. Reveals concept
   **bundles** (e.g., _gentle_ + _fragrance-free_ + _eczema_). Data: self-join on
   `review_concept`.
2. **White Space Finder** — unmet-need detector: concepts / bundles with **high demand or
   complaint signal but low product coverage and low satisfaction.** Crosses demand
   (mentions) × supply (products addressing) × satisfaction (sentiment). Ranks the gaps.
3. **Innovation Opportunity Matrix** — a bubble/2×2 positioning concept bundles as
   opportunities (e.g., x = demand momentum, y = competitive saturation, size = volume,
   color = sentiment gap). Synthesizes White Space + Co-occurrence + Consumer Shift.
4. **Taxonomy expansion** _(engine-side, run in parallel)_ — discover concepts **not yet in
   the taxonomy** (unmatched n-grams / embedding clusters from reviews), human-in-the-loop
   to promote → re-tag (using Phase 3 `tagging_state` versioning) → **lifts every module at
   once.**

- **Acceptance:** each moat module produces a ranked, defensible output an analyst can act
  on, substantiated by verbatims and reconcilable with Phase 1 numbers.
- **The moat:** these four are hard to copy because they depend on the taxonomy, the tagged
  corpus, and the shared metrics layer — not on any single chart.

---

## 7. Cross-Cutting Principles

- **One definition per metric** — enforced by the semantic layer. The classic failure mode
  is two modules with two definitions of "trend"; §2 exists to prevent it.
- **Normalize with Share-of-Mention** for every trend comparison so corpus growth ≠ concept
  growth.
- **Volume floors everywhere** to suppress small-sample noise; surface the threshold in the
  UI so users know what's filtered.
- **Backtest anything predictive** (Radar now; White Space later) before it's shown as
  signal.
- **Verbatims are the trust layer** — every quantitative claim drills to the reviews behind
  it. The reusable verbatim component (§3.0) is load-bearing.

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Modules contradict each other on numbers | Shared semantic/metrics layer built first (§2) |
| Small-sample noise fakes trends / false Radar alerts | Volume floors + smoothing + significance filters |
| Precomputed rollups go stale mid-MVP | Not collecting new data now → one-time full precompute is fine; incrementalize in Phase 3 |
| Moat-module scope creep into Phase 1 | Hard gate: no Phase 4 work before Phase 3 operationalization |
| Deferring tests/CI lets Phase 1 regress silently | Keep lightweight reconciliation asserts + Radar backtest in Phase 1 (§5 guardrail) |
| Corpus growth misread as concept growth | Share-of-Mention normalization mandated in the metrics layer |

---

## 9. Immediate Next Steps

1. **Send the precomputed table DDL / column names** (or `\d+` output for the concept /
   complaint / review tables). This turns the §2 logical data contract into real queries.
2. **Confirm the dashboard stack** (Next.js? Streamlit? other) so module specs get concrete
   component-level detail.
3. **Materialize the rollup tables** (`concept_month`, `brand_month`, `category_month`) if
   they don't already exist — first Phase 1 task, pure aggregation over existing tagged
   data.
4. **Build the Phase 1 foundation** (semantic layer + shell + shared components), then ship
   **Category → Brand** as the first two modules to validate the base.

---

_This roadmap deliberately inverts the earlier data-engineering-first plan into a
product-first plan. The audit's findings are not discarded — they are Phase 3, executed
against a product that has already proven it deserves to be operationalized._
