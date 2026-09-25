begin;

alter table public.memberships add column if not exists current_holder_person_id uuid;
alter table public.membership_exits
  add column if not exists requested_at timestamptz default now(),
  add column if not exists settled_to_nominee_id uuid,
  add column if not exists settlement_notes text,
  add column if not exists death_date date,
  add column if not exists death_date_verified_at timestamptz,
  add column if not exists death_date_verified_by uuid;
alter table public.nominees add column if not exists successor_person_id uuid;

create table if not exists public.membership_successions (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null,
  membership_exit_id uuid not null,
  original_person_id uuid not null,
  successor_person_id uuid not null,
  nominee_id uuid not null,
  succeeded_at timestamptz not null default now(),
  recorded_by uuid,
  notes text,
  created_at timestamptz not null default now()
);

create unique index if not exists membership_successions_one_per_membership
  on public.membership_successions(membership_id);
create unique index if not exists membership_successions_one_per_exit
  on public.membership_successions(membership_exit_id);
create index if not exists membership_successions_successor_idx
  on public.membership_successions(successor_person_id);
create index if not exists memberships_current_holder_person_id_idx
  on public.memberships(current_holder_person_id);

alter table public.membership_successions enable row level security;
revoke all on table public.membership_successions from anon,authenticated;

commit;