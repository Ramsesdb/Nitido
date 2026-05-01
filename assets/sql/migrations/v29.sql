-- v29: defense-in-depth against the auto-import dedupe race.
--
-- In production we observed a single BDV bank notification producing TWO
-- pending_imports rows with the same bankRef and accountId, inserted within
-- the same millisecond. Root cause: the orchestrator dispatched the event
-- to its pipeline twice (multiple listeners on the merged stream) and the
-- DedupeChecker.check() / insertPendingImport sequence is NOT atomic, so
-- both racing invocations passed the duplicate check before either insert
-- materialized.
--
-- This migration adds a partial UNIQUE index over (bankRef, accountId)
-- restricted to rows where bankRef IS NOT NULL. Effects:
--   - Future racing inserts hit a UNIQUE-violation that the service layer
--     catches and treats as a no-op.
--   - NULL bankRef rows (SMS without a reference, manual additions) are
--     excluded by the WHERE clause and never collide.
--
-- BEFORE creating the index we collapse any pre-existing duplicate rows so
-- the CREATE doesn't fail on legacy data. We keep the OLDEST pending row
-- per (bankRef, accountId) and DELETE the rest. Confirmed/rejected rows
-- are NOT touched — they reflect user decisions and must survive.
--
-- Idempotent: re-running this migration is a no-op once the index exists.

-- (1) Collapse legacy duplicates among status='pending' rows. Keep the row
--     with the smallest rowid (oldest) per (bankRef, accountId) and delete
--     the others. This is conservative — we never touch confirmed or
--     rejected rows.
DELETE FROM pendingImports
 WHERE status = 'pending'
   AND bankRef IS NOT NULL
   AND accountId IS NOT NULL
   AND rowid NOT IN (
     SELECT MIN(rowid)
       FROM pendingImports
      WHERE status = 'pending'
        AND bankRef IS NOT NULL
        AND accountId IS NOT NULL
      GROUP BY bankRef, accountId
   );

-- (2) Create the partial UNIQUE index. SQLite supports partial indexes
--     since 3.8.0; Drift's bundled SQLite is well above that on every
--     supported platform.
CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_imports_bankref_account_unique
  ON pendingImports(bankRef, accountId)
  WHERE bankRef IS NOT NULL;
