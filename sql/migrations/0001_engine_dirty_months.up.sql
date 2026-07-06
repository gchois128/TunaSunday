-- =============================================================================
-- Migration 0001 (UP) — engine_dirty_months
-- =============================================================================
-- Crash-safe marker queue: months whose concept_mentions changed and therefore
-- need a concept_timeseries recompute. This is the durable hand-off between the
-- (Python) tagging step and the (later) rollup step.
--
-- Scope guards:
--   * Engine-owned table only. Does NOT reference or alter any review/product
--     table. Pure additive DDL.
--   * Idempotent (IF NOT EXISTS) so a re-run is harmless.
--   * RLS enabled with NO policies -> unreachable via anon/public API; only the
--     service_role connection (which bypasses RLS) can read/write it.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS engine_dirty_months (
    month        date        NOT NULL,
    marked_at    timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,                       -- NULL => dirty (pending rollup)
    CONSTRAINT engine_dirty_months_pkey PRIMARY KEY (month)
);

COMMENT ON TABLE  engine_dirty_months IS
  'Marker queue of months whose concept_mentions changed and need concept_timeseries recompute. processed_at IS NULL = pending.';
COMMENT ON COLUMN engine_dirty_months.month        IS 'First day (UTC) of the affected month.';
COMMENT ON COLUMN engine_dirty_months.marked_at    IS 'When the month was last (re)marked dirty.';
COMMENT ON COLUMN engine_dirty_months.processed_at IS 'When the rollup for this month last completed; NULL = pending.';

-- Fast lookup of the pending set (the rollup step reads WHERE processed_at IS NULL).
CREATE INDEX IF NOT EXISTS engine_dirty_months_pending_idx
    ON engine_dirty_months (month)
    WHERE processed_at IS NULL;

-- Engine-internal table: lock it down on the API surface.
ALTER TABLE engine_dirty_months ENABLE ROW LEVEL SECURITY;
-- (No policies created on purpose: service_role bypasses RLS; anon/authenticated get nothing.)

COMMIT;
