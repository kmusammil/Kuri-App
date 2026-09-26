-- Fix Expense obligation occurrence-date invariant.
-- Calendar recurring obligations may have no cycle, and one-time obligations
-- may have neither a cycle nor an occurrence date. Only a cycle-scoped
-- obligation must carry an occurrence date; rule-specific identity validation
-- remains enforced by enforce_expense_obligation_identity().

ALTER TABLE public.expense_obligations
  DROP CONSTRAINT IF EXISTS expense_obligations_occurrence_date_check;

ALTER TABLE public.expense_obligations
  ADD CONSTRAINT expense_obligations_occurrence_date_check
  CHECK (
    cycle_id IS NULL
    OR occurrence_date IS NOT NULL
  );
