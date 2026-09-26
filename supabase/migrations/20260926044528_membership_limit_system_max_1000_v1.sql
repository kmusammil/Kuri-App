begin;

alter table public.kuris
  add constraint kuris_membership_limit_max_1000
  check (membership_limit >= 1 and membership_limit <= 1000);

commit;