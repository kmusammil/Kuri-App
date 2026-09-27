-- SEC-005: bound the combined membership x cycle amplification envelope.
alter table public.system_capacity_limits
  drop constraint if exists system_capacity_membership_cycle_amplification_check;

alter table public.system_capacity_limits
  add constraint system_capacity_membership_cycle_amplification_check
  check (
    max_members_per_kuri::bigint * max_cycles_per_kuri::bigint <= 9000
  );