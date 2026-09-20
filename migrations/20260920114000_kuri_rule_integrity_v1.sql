-- Deep backend audit hardening: constrain text-based Kuri rules to
-- the rule vocabulary currently implemented by the draw engine.

begin;

alter table public.kuris
  drop constraint if exists kuris_draw_eligibility_rule_check,
  drop constraint if exists kuris_winner_rule_check;

alter table public.kuris
  add constraint kuris_draw_eligibility_rule_check
    check (draw_eligibility_rule = 'PAID_INSTALLMENT'),
  add constraint kuris_winner_rule_check
    check (winner_rule = 'ALL_PERSON_MEMBERSHIPS');

commit;