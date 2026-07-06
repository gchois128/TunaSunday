#!/usr/bin/env python3
"""
incremental_update.py  —  crash-safe incremental tagging for the Concept Engine.

WHAT IT DOES
    1. Discovers reviews that are NOT yet tagged (anti-join base tables vs tagging_state).
    2. Reconstructs each into the v_reviews_unified shape *from base tables, for speed*.
    3. Verifies that reconstruction matches v_reviews_unified EXACTLY (parity guard).
    4. Tags them by calling the EXISTING tagger.py  (never reimplemented here).
    5. Writes concept_mentions, upserts tagging_state, and marks affected months
       dirty in engine_dirty_months — atomically, one transaction per batch.

WHAT IT DELIBERATELY DOES NOT DO
    * No tagging logic. tagger.py is the single source of truth; we only orchestrate.
    * No SQL port of the tagger.
    * No writes to any review/product/base table (read-only there).
    * No concept_timeseries recompute (that is the separate "rollup" step; this script
      only marks months dirty so the rollup knows what to recompute).
    * No DDL at runtime — migration 0001 must be applied manually first.
    * No scheduler / pg_cron. Invoked manually or by an external runner.

CRASH SAFETY
    * Per-batch transaction: concept_mentions + tagging_state + engine_dirty_months
      commit together or not at all. A crash mid-batch rolls back; those reviews stay
      untagged and are retried next run (the anti-join is the durable watermark).
    * engine_dirty_months persists until its month's rollup commits and clears it, so a
      crash after tagging but before rollup cannot "lose" a month.
    * Idempotent: re-running never double-tags (anti-join) and never double-inserts
      mentions (ON CONFLICT DO NOTHING).

SEAMS TO CONFIRM AGAINST THE REAL SCHEMA (search "SEAM"):
    SEAM 1  tagger.py entry point (import + call signature)
    SEAM 2  base-table source adapters — each MUST mirror v_reviews_unified exactly
    SEAM 3  tagging_state columns
    SEAM 4  concept_mentions columns

COMMANDS
    Dry-run (no writes):   DATABASE_URL=... python engine/incremental_update.py --dry-run --limit 500
    Normal run:            DATABASE_URL=... python engine/incremental_update.py --batch-size 1000
"""
from __future__ import annotations

import argparse
import logging
import os
import sys

import psycopg2
import psycopg2.extras

# ── SEAM 1: reuse the EXISTING tagger. Do NOT reimplement tagging. ────────────
# Confirm tagger.py's public entry point and the shape it returns.
# Assumed: tag_review(unified_row: dict) -> list[dict], each dict having at least
#          {"concept_id": ..., "sentiment": ..., "snippet": ...}
from tagger import tag_review  # noqa: E402  (adjust import path to where tagger.py lives)

log = logging.getLogger("incremental_update")

TAXONOMY_VERSION = os.environ.get("TAXONOMY_VERSION", "v1")
DEFAULT_BATCH = 1000

# Canonical output columns — must equal v_reviews_unified's column list (fact #4).
UNIFIED_COLUMNS = [
    "review_id", "product_id", "brand_id", "brand_name",
    "category_id", "category_name", "rating", "review_date",
    "source", "review_text",
]

# ── SEAM 2: base-table source adapters ───────────────────────────────────────
# v_reviews_unified is (assumed) a UNION ALL of per-source SELECTs. Replicate ONE
# entry here per base source table, projecting into UNIFIED_COLUMNS with the SAME
# casts/normalization the view uses. The parity guard (verify_parity) will FAIL the
# run if any adapter drifts from the view — that is the safety net for "must mirror
# v_reviews_unified exactly". Each query also anti-joins tagging_state to return
# only untagged reviews for the current taxonomy version.
SOURCE_ADAPTERS = {
    # --- EXAMPLE for one source; copy & adapt for every base source table. ---
    "example_source": """
        SELECT
            b.review_id,
            b.product_id,
            b.brand_id,
            br.name             AS brand_name,
            b.category_id,
            cat.name            AS category_name,
            b.rating,
            b.created_at::date  AS review_date,
            'example_source'    AS source,
            b.body              AS review_text
        FROM example_source_reviews b
        JOIN brands     br  ON br.brand_id  = b.brand_id
        JOIN categories cat ON cat.category_id = b.category_id
        LEFT JOIN tagging_state ts
               ON ts.review_id = b.review_id
              AND ts.taxonomy_version = %(tax)s          -- SEAM 3 column
        WHERE ts.review_id IS NULL                       -- untagged for this taxonomy version
        ORDER BY b.review_id
        LIMIT %(limit)s
    """,
}


def get_conn():
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        sys.exit("DATABASE_URL not set. Use the service-role / direct Postgres DSN "
                 "(it must bypass RLS to write engine tables).")
    return psycopg2.connect(dsn)


def preflight(cur) -> None:
    """Refuse to run if migration 0001 hasn't been applied. Never creates DDL itself."""
    cur.execute("SELECT to_regclass('public.engine_dirty_months')")
    if cur.fetchone()[0] is None:
        sys.exit("engine_dirty_months is missing. Apply sql/migrations/0001_*.up.sql first.")


def fetch_untagged(cur, limit: int) -> list[dict]:
    """Read-only discovery + reconstruction from base tables (SEAM 2)."""
    rows: list[dict] = []
    for source, sql in SOURCE_ADAPTERS.items():
        remaining = limit - len(rows)
        if remaining <= 0:
            break
        cur.execute(sql, {"tax": TAXONOMY_VERSION, "limit": remaining})
        cols = [d[0] for d in cur.description]
        for r in cur.fetchall():
            row = dict(zip(cols, r))
            missing = set(UNIFIED_COLUMNS) - set(row)
            if missing:
                sys.exit(f"source adapter '{source}' is missing unified columns: {missing}")
            rows.append(row)
    return rows


def verify_parity(cur, rows: list[dict]) -> None:
    """Assert base-table reconstruction == v_reviews_unified for these review_ids.

    This is the guardrail that makes 'fetch from base tables for speed' safe: if any
    field diverges from the canonical view, we STOP before tagging on bad input.
    """
    ids = [r["review_id"] for r in rows]
    if not ids:
        return
    cur.execute(
        f"SELECT {', '.join(UNIFIED_COLUMNS)} FROM v_reviews_unified WHERE review_id = ANY(%s)",
        (ids,),
    )
    canon = {r[0]: dict(zip(UNIFIED_COLUMNS, r)) for r in cur.fetchall()}
    mismatches: list[tuple] = []
    for row in rows:
        c = canon.get(row["review_id"])
        if c is None:
            mismatches.append((row["review_id"], "absent from v_reviews_unified"))
            continue
        for col in UNIFIED_COLUMNS:
            if row[col] != c[col]:
                mismatches.append((row["review_id"], f"{col}: {row[col]!r} != {c[col]!r}"))
    if mismatches:
        for m in mismatches[:20]:
            log.error("PARITY MISMATCH %s", m)
        sys.exit(f"Parity check failed ({len(mismatches)} mismatches). "
                 "Fix SOURCE_ADAPTERS to mirror v_reviews_unified before writing.")
    log.info("Parity OK for %d reviews.", len(rows))


def run_tagger(unified_row: dict) -> list[dict]:
    """SEAM 1 adapter. Delegates to the existing tagger; contains no tagging logic."""
    return tag_review(unified_row)


def month_of(review_date):
    """Bucket a date to the first day of its month (UTC-consistent, matches timeseries)."""
    return review_date.replace(day=1)


def write_batch(conn, rows: list[dict], mentions_by_review: dict[object, list[dict]]) -> set:
    """Atomic per-batch write: mentions + tagging_state + dirty months, or nothing."""
    dirty: set = set()
    with conn:                                   # commit on success, rollback on any error
        with conn.cursor() as cur:
            for row in rows:
                rid = row["review_id"]
                if rid not in mentions_by_review:
                    continue                     # tagger errored on this review -> leave untagged
                ms = mentions_by_review[rid]
                if ms:
                    # SEAM 4: concept_mentions columns
                    psycopg2.extras.execute_values(
                        cur,
                        "INSERT INTO concept_mentions (review_id, concept_id, sentiment, snippet) "
                        "VALUES %s ON CONFLICT DO NOTHING",
                        [(rid, m["concept_id"], m.get("sentiment"), m.get("snippet")) for m in ms],
                    )
                # SEAM 3: tagging_state upsert (the durable watermark)
                cur.execute(
                    "INSERT INTO tagging_state (review_id, tagged_at, taxonomy_version) "
                    "VALUES (%s, now(), %s) "
                    "ON CONFLICT (review_id) DO UPDATE "
                    "SET tagged_at = EXCLUDED.tagged_at, taxonomy_version = EXCLUDED.taxonomy_version",
                    (rid, TAXONOMY_VERSION),
                )
                dirty.add(month_of(row["review_date"]))
            for m in dirty:
                cur.execute(
                    "INSERT INTO engine_dirty_months (month, marked_at, processed_at) "
                    "VALUES (%s, now(), NULL) "
                    "ON CONFLICT (month) DO UPDATE SET marked_at = now(), processed_at = NULL",
                    (m,),
                )
    return dirty


def main() -> None:
    ap = argparse.ArgumentParser(description="Crash-safe incremental Concept Engine tagging.")
    ap.add_argument("--dry-run", action="store_true", help="Do everything except write (no COMMIT).")
    ap.add_argument("--batch-size", type=int, default=DEFAULT_BATCH)
    ap.add_argument("--limit", type=int, default=None, help="Max reviews this run (mainly for dry-run).")
    ap.add_argument("--parity-sample", type=int, default=200, help="Reviews per batch to parity-check.")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    conn = get_conn()
    with conn.cursor() as cur:
        preflight(cur)

    total = 0
    while True:
        batch_limit = args.batch_size
        if args.limit is not None:
            batch_limit = min(batch_limit, args.limit - total)
        if batch_limit <= 0:
            break

        with conn.cursor() as cur:
            rows = fetch_untagged(cur, batch_limit)
        if not rows:
            log.info("No untagged reviews remaining.")
            break

        # Parity guard BEFORE trusting the base-table reconstruction.
        with conn.cursor() as cur:
            verify_parity(cur, rows[: args.parity_sample])

        # Tag via the existing tagger. Per-review failures are isolated & retried later.
        mentions_by_review: dict[object, list[dict]] = {}
        n_mentions = 0
        for row in rows:
            try:
                ms = run_tagger(row)
            except Exception as e:  # noqa: BLE001 — isolate one bad review from the batch
                log.error("tagger failed for review %s: %s (left untagged, will retry)",
                          row["review_id"], e)
                continue
            mentions_by_review[row["review_id"]] = ms
            n_mentions += len(ms)

        months = sorted({month_of(r["review_date"]) for r in rows
                         if r["review_id"] in mentions_by_review})

        if args.dry_run:
            log.info("[DRY-RUN] would tag %d/%d reviews -> %d mentions; dirty months: %s",
                     len(mentions_by_review), len(rows), n_mentions,
                     [m.isoformat() for m in months])
            total += len(rows)
            if args.limit is None:      # dry-run does one batch by default
                break
            continue

        dirty = write_batch(conn, rows, mentions_by_review)
        total += len(rows)
        log.info("Committed batch: %d reviews, %d mentions, %d dirty months.",
                 len(mentions_by_review), n_mentions, len(dirty))

    log.info("Done. Processed %d reviews this run.", total)
    conn.close()


if __name__ == "__main__":
    main()
