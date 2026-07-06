-- =============================================================================
-- Migration 0001 (DOWN / ROLLBACK) — engine_dirty_months
-- =============================================================================
-- WARNING: dropping this table permanently discards the pending-rollup queue.
-- If any months are still pending (processed_at IS NULL), run the rollup first,
-- or those months will silently not be recomputed after a future re-create.
--
-- Check before rolling back:
--   SELECT count(*) FROM engine_dirty_months WHERE processed_at IS NULL;
--
-- Touches only the engine-owned table. No review/product tables involved.
-- =============================================================================

BEGIN;

-- (DROP TABLE also removes engine_dirty_months_pending_idx and the PK/constraints.)
DROP TABLE IF EXISTS engine_dirty_months;

COMMIT;
