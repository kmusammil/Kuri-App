-- Add the canonical recurring Expense frequency value.
ALTER TYPE public.expense_frequency
  ADD VALUE IF NOT EXISTS 'RECURRING';
