-- Kuri-App foundation schema
-- PostgreSQL / Supabase

create extension if not exists pgcrypto;

create type public.user_role as enum ('MAIN_ADMIN', 'ADMIN', 'MEMBER');
create type public.record_status as enum ('ACTIVE', 'SUSPENDED');
create type public.kuri_frequency as enum ('MONTHLY');
create type public.kuri_status as enum ('DRAFT', 'ACTIVE', 'COMPLETED', 'CANCELLED');
create type public.membership_status as enum ('PENDING', 'ACTIVE', 'SUSPENDED', 'EXITED', 'COMPLETED', 'TRANSFERRED');
create type public.cycle_status as enum ('UPCOMING', 'OPEN', 'PAYMENT_CLOSED', 'DRAW_PENDING', 'COMPLETED', 'CANCELLED');
create type public.installment_status as enum ('UNPAID', 'PARTIAL', 'PAID', 'PAID_LATE', 'ADVANCE', 'WAIVED');
create type public.payment_method as enum ('UPI', 'BANK_TRANSFER', 'CASH', 'OTHER');
create type public.payment_status as enum ('PENDING_VERIFICATION', 'APPROVED', 'REJECTED', 'CANCELLED');
create type public.muppu_status as enum ('UNPAID', 'PAID', 'DEDUCTED', 'WAIVED');
create type public.muppu_settlement_method as enum ('PAID_IN_ADVANCE', 'DEDUCTED_FROM_PRIZE', 'WAIVED');
create type public.draw_status as enum ('DRAFT', 'POOL_READY', 'DRAWING', 'RESULTS_READY', 'FINALIZED', 'CANCELLED');
create type public.winner_source as enum ('RANDOM_DRAW', 'ADMIN_OVERRIDE');
create type public.winner_status as enum ('SELECTED', 'PAYOUT_PENDING', 'PAID', 'CANCELLED');
create type public.payout_status as enum ('PENDING', 'PROCESSING', 'PAID', 'CANCELLED');
create type public.exit_reason as enum ('VOLUNTARY_EXIT', 'DEATH', 'OTHER');
create type public.refund_policy as enum ('AT_MATURITY', 'IMMEDIATE');
create type public.settlement_status as enum ('PENDING', 'APPROVED', 'SETTLED', 'CANCELLED');

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  phone text,
  email text,
  address text,
  logo_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.people (
  id uuid primary key default gen_random_uuid(),
  registered_name text not null,
  display_name text,
  address text,
  photo_url text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  person_id uuid references public.people(id) on delete set null,
  status public.record_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  last_login_at timestamptz
);

create table public.organization_users (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references public.users(id) on delete cascade,
  role public.user_role not null,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table public.person_phones (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  phone_number text not null,
  label text,
  is_primary boolean not null default false
);

create table public.person_emails (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  email text not null,
  label text,
  is_primary boolean not null default false
);

create table public.kuris (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  name text not null,
  description text,
  start_date date not null,
  number_of_cycles integer not null check (number_of_cycles > 0),
  membership_limit integer not null check (membership_limit > 0),
  installment_amount bigint not null check (installment_amount >= 0),
  frequency public.kuri_frequency not null default 'MONTHLY',
  due_day integer not null check (due_day between 1 and 31),
  draw_day integer not null check (draw_day between 1 and 31),
  gross_prize_amount bigint not null check (gross_prize_amount >= 0),
  muppu_amount bigint not null default 0 check (muppu_amount >= 0),
  draw_eligibility_rule text not null default 'PAID_INSTALLMENT',
  winner_rule text not null default 'ALL_PERSON_MEMBERSHIPS',
  exit_refund_rule public.refund_policy not null default 'AT_MATURITY',
  status public.kuri_status not null default 'DRAFT',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  person_id uuid not null references public.people(id) on delete restrict,
  membership_number text not null,
  status public.membership_status not null default 'PENDING',
  joined_at timestamptz not null default now(),
  exited_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (kuri_id, membership_number)
);

create index memberships_person_idx on public.memberships(person_id);
create index memberships_kuri_idx on public.memberships(kuri_id);

create table public.cycles (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  cycle_number integer not null check (cycle_number > 0),
  period_start date not null,
  period_end date not null,
  due_date date not null,
  draw_date date not null,
  status public.cycle_status not null default 'UPCOMING',
  created_at timestamptz not null default now(),
  unique (kuri_id, cycle_number),
  check (period_end >= period_start)
);

create index cycles_kuri_idx on public.cycles(kuri_id);

create table public.installments (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.memberships(id) on delete restrict,
  cycle_id uuid not null references public.cycles(id) on delete restrict,
  amount_due bigint not null check (amount_due >= 0),
  amount_paid bigint not null default 0 check (amount_paid >= 0),
  status public.installment_status not null default 'UNPAID',
  due_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (membership_id, cycle_id)
);

create index installments_cycle_idx on public.installments(cycle_id);
create index installments_membership_idx on public.installments(membership_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete restrict,
  amount bigint not null check (amount > 0),
  payment_date timestamptz not null,
  method public.payment_method not null,
  reference_number text,
  proof_url text,
  status public.payment_status not null default 'PENDING_VERIFICATION',
  submitted_at timestamptz not null default now(),
  verified_at timestamptz,
  verified_by uuid references public.users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create index payments_person_idx on public.payments(person_id);
create index payments_status_idx on public.payments(status);

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  installment_id uuid not null references public.installments(id) on delete restrict,
  amount bigint not null check (amount > 0),
  allocated_at timestamptz not null default now(),
  allocated_by uuid references public.users(id) on delete set null
);

create index payment_allocations_payment_idx on public.payment_allocations(payment_id);
create index payment_allocations_installment_idx on public.payment_allocations(installment_id);

create table public.muppu_records (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  cycle_id uuid not null references public.cycles(id) on delete restrict,
  person_id uuid not null references public.people(id) on delete restrict,
  amount bigint not null check (amount >= 0),
  status public.muppu_status not null default 'UNPAID',
  settlement_method public.muppu_settlement_method,
  paid_at timestamptz,
  payment_reference text,
  created_at timestamptz not null default now(),
  unique (kuri_id, cycle_id, person_id)
);

create table public.draw_sessions (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  cycle_id uuid not null references public.cycles(id) on delete restrict,
  conducted_by uuid not null references public.users(id) on delete restrict,
  status public.draw_status not null default 'DRAFT',
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (kuri_id, cycle_id)
);

create table public.draw_pool_entries (
  id uuid primary key default gen_random_uuid(),
  draw_session_id uuid not null references public.draw_sessions(id) on delete cascade,
  membership_id uuid not null references public.memberships(id) on delete restrict,
  system_eligible boolean not null,
  admin_included boolean not null default false,
  override boolean not null default false,
  override_reason text,
  modified_by uuid references public.users(id) on delete set null,
  modified_at timestamptz not null default now(),
  unique (draw_session_id, membership_id)
);

create table public.draw_selections (
  id uuid primary key default gen_random_uuid(),
  draw_session_id uuid not null references public.draw_sessions(id) on delete cascade,
  membership_id uuid not null references public.memberships(id) on delete restrict,
  selection_order integer not null check (selection_order > 0),
  selected_at timestamptz not null default now(),
  randomization_id text
);

create table public.monthly_winners (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.cycles(id) on delete restrict,
  person_id uuid not null references public.people(id) on delete restrict,
  selection_source public.winner_source not null,
  finalized_by uuid not null references public.users(id) on delete restrict,
  finalized_at timestamptz not null default now(),
  status public.winner_status not null default 'SELECTED',
  notes text
);

create table public.monthly_winner_memberships (
  id uuid primary key default gen_random_uuid(),
  monthly_winner_id uuid not null references public.monthly_winners(id) on delete cascade,
  membership_id uuid not null references public.memberships(id) on delete restrict,
  award_amount bigint not null check (award_amount >= 0),
  created_at timestamptz not null default now(),
  unique (monthly_winner_id, membership_id)
);

create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  monthly_winner_id uuid not null references public.monthly_winners(id) on delete restrict,
  gross_amount bigint not null check (gross_amount >= 0),
  muppu_amount bigint not null default 0 check (muppu_amount >= 0),
  other_deductions bigint not null default 0 check (other_deductions >= 0),
  net_amount bigint not null check (net_amount >= 0),
  payment_date timestamptz,
  method public.payment_method,
  reference_number text,
  status public.payout_status not null default 'PENDING',
  processed_by uuid references public.users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create table public.membership_exits (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.memberships(id) on delete restrict,
  reason public.exit_reason not null,
  exit_date date not null,
  refund_policy public.refund_policy not null default 'AT_MATURITY',
  amount_contributed bigint not null default 0 check (amount_contributed >= 0),
  refund_amount bigint not null default 0 check (refund_amount >= 0),
  status public.settlement_status not null default 'PENDING',
  approved_by uuid references public.users(id) on delete set null,
  settled_at timestamptz,
  notes text
);

create table public.nominees (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  name text not null,
  relationship text,
  phone text,
  address text,
  notes text
);

create table public.files (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  uploaded_by uuid references public.users(id) on delete set null,
  file_type text not null,
  storage_key text not null unique,
  original_name text,
  mime_type text,
  size_bytes bigint,
  created_at timestamptz not null default now()
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid references public.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  reason text,
  created_at timestamptz not null default now()
);

create index audit_logs_org_idx on public.audit_logs(organization_id, created_at desc);

-- Auth profile bootstrap
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.users (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

-- Generic updated_at helper
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists organizations_set_updated_at on public.organizations;
create trigger organizations_set_updated_at before update on public.organizations for each row execute function public.set_updated_at();
drop trigger if exists people_set_updated_at on public.people;
create trigger people_set_updated_at before update on public.people for each row execute function public.set_updated_at();
drop trigger if exists kuris_set_updated_at on public.kuris;
create trigger kuris_set_updated_at before update on public.kuris for each row execute function public.set_updated_at();
drop trigger if exists installments_set_updated_at on public.installments;
create trigger installments_set_updated_at before update on public.installments for each row execute function public.set_updated_at();

-- Helper: organization membership
create or replace function public.is_org_member(target_org uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.organization_users ou
    where ou.organization_id = target_org and ou.user_id = auth.uid()
  );
$$;

create or replace function public.is_org_admin(target_org uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.organization_users ou
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.role in ('MAIN_ADMIN', 'ADMIN')
  );
$$;

create or replace function public.is_org_main_admin(target_org uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.organization_users ou
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.role = 'MAIN_ADMIN'
  );
$$;

create or replace function public.person_is_current_user(target_person uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.users u
    where u.id = auth.uid() and u.person_id = target_person
  );
$$;

-- RLS
alter table public.organizations enable row level security;
alter table public.people enable row level security;
alter table public.users enable row level security;
alter table public.organization_users enable row level security;
alter table public.person_phones enable row level security;
alter table public.person_emails enable row level security;
alter table public.kuris enable row level security;
alter table public.memberships enable row level security;
alter table public.cycles enable row level security;
alter table public.installments enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.muppu_records enable row level security;
alter table public.draw_sessions enable row level security;
alter table public.draw_pool_entries enable row level security;
alter table public.draw_selections enable row level security;
alter table public.monthly_winners enable row level security;
alter table public.monthly_winner_memberships enable row level security;
alter table public.payouts enable row level security;
alter table public.membership_exits enable row level security;
alter table public.nominees enable row level security;
alter table public.files enable row level security;
alter table public.audit_logs enable row level security;

create policy organizations_select on public.organizations for select using (public.is_org_member(id));
create policy organizations_admin_write on public.organizations for all using (public.is_org_admin(id)) with check (public.is_org_admin(id));

create policy users_self_select on public.users for select using (id = auth.uid());
create policy users_admin_select on public.users for select using (
  exists (select 1 from public.organization_users me join public.organization_users target on target.organization_id = me.organization_id where me.user_id = auth.uid() and me.role in ('MAIN_ADMIN','ADMIN') and target.user_id = users.id)
);

create policy organization_users_select on public.organization_users for select using (user_id = auth.uid() or public.is_org_admin(organization_id));
create policy organization_users_main_admin_write on public.organization_users for all using (public.is_org_main_admin(organization_id)) with check (public.is_org_main_admin(organization_id));

create policy people_org_select on public.people for select using (
  person_is_current_user(id) or exists (
    select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id join public.organization_users ou on ou.organization_id = k.organization_id
    where m.person_id = people.id and ou.user_id = auth.uid()
  )
);
create policy people_admin_write on public.people for all using (
  exists (select 1 from public.organization_users ou where ou.user_id = auth.uid() and ou.role in ('MAIN_ADMIN','ADMIN'))
) with check (
  exists (select 1 from public.organization_users ou where ou.user_id = auth.uid() and ou.role in ('MAIN_ADMIN','ADMIN'))
);

create policy person_phones_select on public.person_phones for select using (public.person_is_current_user(person_id) or exists (
  select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = person_phones.person_id and public.is_org_admin(k.organization_id)
));
create policy person_phones_admin_write on public.person_phones for all using (public.person_is_current_user(person_id) or exists (
  select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = person_phones.person_id and public.is_org_admin(k.organization_id)
)) with check (public.person_is_current_user(person_id) or exists (
  select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = person_phones.person_id and public.is_org_admin(k.organization_id)
));

create policy person_emails_select on public.person_emails for select using (public.person_is_current_user(person_id) or exists (
  select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = person_emails.person_id and public.is_org_admin(k.organization_id)
));
create policy person_emails_admin_write on public.person_emails for all using (public.person_is_current_user(person_id) or exists (
  select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = person_emails.person_id and public.is_org_admin(k.organization_id)
)) with check (public.person_is_current_user(person_id) or exists (
  select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = person_emails.person_id and public.is_org_admin(k.organization_id)
));

create policy kuris_select on public.kuris for select using (public.is_org_member(organization_id));
create policy kuris_admin_write on public.kuris for all using (public.is_org_admin(organization_id)) with check (public.is_org_admin(organization_id));

create policy memberships_select on public.memberships for select using (
  public.person_is_current_user(person_id) or exists (select 1 from public.kuris k where k.id = memberships.kuri_id and public.is_org_member(k.organization_id))
);
create policy memberships_admin_write on public.memberships for all using (exists (select 1 from public.kuris k where k.id = memberships.kuri_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.kuris k where k.id = memberships.kuri_id and public.is_org_admin(k.organization_id)));

create policy cycles_select on public.cycles for select using (exists (select 1 from public.kuris k where k.id = cycles.kuri_id and public.is_org_member(k.organization_id)));
create policy cycles_admin_write on public.cycles for all using (exists (select 1 from public.kuris k where k.id = cycles.kuri_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.kuris k where k.id = cycles.kuri_id and public.is_org_admin(k.organization_id)));

create policy installments_select on public.installments for select using (
  public.person_is_current_user((select m.person_id from public.memberships m where m.id = installments.membership_id))
  or exists (select 1 from public.installments i join public.memberships m on m.id = i.membership_id join public.kuris k on k.id = m.kuri_id where i.id = installments.id and public.is_org_admin(k.organization_id))
);
create policy installments_admin_write on public.installments for all using (exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.id = installments.membership_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.id = installments.membership_id and public.is_org_admin(k.organization_id)));

create policy payments_select on public.payments for select using (public.person_is_current_user(person_id) or exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = payments.person_id and public.is_org_admin(k.organization_id)));
create policy payments_insert_self on public.payments for insert with check (public.person_is_current_user(person_id));
create policy payments_admin_write on public.payments for update using (exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = payments.person_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = payments.person_id and public.is_org_admin(k.organization_id)));

create policy payment_allocations_select on public.payment_allocations for select using (exists (select 1 from public.payments p where p.id = payment_allocations.payment_id and (public.person_is_current_user(p.person_id) or exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = p.person_id and public.is_org_admin(k.organization_id)))));
create policy payment_allocations_admin_write on public.payment_allocations for all using (exists (select 1 from public.payments p join public.memberships m on m.person_id = p.person_id join public.kuris k on k.id = m.kuri_id where p.id = payment_allocations.payment_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.payments p join public.memberships m on m.person_id = p.person_id join public.kuris k on k.id = m.kuri_id where p.id = payment_allocations.payment_id and public.is_org_admin(k.organization_id)));

create policy muppu_select on public.muppu_records for select using (public.person_is_current_user(person_id) or exists (select 1 from public.kuris k where k.id = muppu_records.kuri_id and public.is_org_admin(k.organization_id)));
create policy muppu_admin_write on public.muppu_records for all using (exists (select 1 from public.kuris k where k.id = muppu_records.kuri_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.kuris k where k.id = muppu_records.kuri_id and public.is_org_admin(k.organization_id)));

create policy draw_sessions_admin on public.draw_sessions for all using (exists (select 1 from public.kuris k where k.id = draw_sessions.kuri_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.kuris k where k.id = draw_sessions.kuri_id and public.is_org_admin(k.organization_id)));
create policy draw_pool_admin on public.draw_pool_entries for all using (exists (select 1 from public.draw_sessions ds join public.kuris k on k.id = ds.kuri_id where ds.id = draw_pool_entries.draw_session_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.draw_sessions ds join public.kuris k on k.id = ds.kuri_id where ds.id = draw_pool_entries.draw_session_id and public.is_org_admin(k.organization_id)));
create policy draw_selections_admin on public.draw_selections for all using (exists (select 1 from public.draw_sessions ds join public.kuris k on k.id = ds.kuri_id where ds.id = draw_selections.draw_session_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.draw_sessions ds join public.kuris k on k.id = ds.kuri_id where ds.id = draw_selections.draw_session_id and public.is_org_admin(k.organization_id)));

create policy winners_member_select on public.monthly_winners for select using (public.person_is_current_user(person_id) or exists (select 1 from public.cycles c join public.kuris k on k.id = c.kuri_id where c.id = monthly_winners.cycle_id and public.is_org_member(k.organization_id)));
create policy winners_admin_write on public.monthly_winners for all using (exists (select 1 from public.cycles c join public.kuris k on k.id = c.kuri_id where c.id = monthly_winners.cycle_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.cycles c join public.kuris k on k.id = c.kuri_id where c.id = monthly_winners.cycle_id and public.is_org_admin(k.organization_id)));

create policy winner_memberships_member_select on public.monthly_winner_memberships for select using (exists (select 1 from public.monthly_winners w where w.id = monthly_winner_memberships.monthly_winner_id and (public.person_is_current_user(w.person_id) or exists (select 1 from public.cycles c join public.kuris k on k.id = c.kuri_id where c.id = w.cycle_id and public.is_org_member(k.organization_id)))));
create policy winner_memberships_admin_write on public.monthly_winner_memberships for all using (exists (select 1 from public.monthly_winners w join public.cycles c on c.id = w.cycle_id join public.kuris k on k.id = c.kuri_id where w.id = monthly_winner_memberships.monthly_winner_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.monthly_winners w join public.cycles c on c.id = w.cycle_id join public.kuris k on k.id = c.kuri_id where w.id = monthly_winner_memberships.monthly_winner_id and public.is_org_admin(k.organization_id)));

create policy payouts_member_select on public.payouts for select using (exists (select 1 from public.monthly_winners w where w.id = payouts.monthly_winner_id and public.person_is_current_user(w.person_id)) or exists (select 1 from public.monthly_winners w join public.cycles c on c.id = w.cycle_id join public.kuris k on k.id = c.kuri_id where w.id = payouts.monthly_winner_id and public.is_org_admin(k.organization_id)));
create policy payouts_admin_write on public.payouts for all using (exists (select 1 from public.monthly_winners w join public.cycles c on c.id = w.cycle_id join public.kuris k on k.id = c.kuri_id where w.id = payouts.monthly_winner_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.monthly_winners w join public.cycles c on c.id = w.cycle_id join public.kuris k on k.id = c.kuri_id where w.id = payouts.monthly_winner_id and public.is_org_admin(k.organization_id)));

create policy exits_member_select on public.membership_exits for select using (exists (select 1 from public.memberships m where m.id = membership_exits.membership_id and public.person_is_current_user(m.person_id)) or exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.id = membership_exits.membership_id and public.is_org_admin(k.organization_id)));
create policy exits_admin_write on public.membership_exits for all using (exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.id = membership_exits.membership_id and public.is_org_admin(k.organization_id))) with check (exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.id = membership_exits.membership_id and public.is_org_admin(k.organization_id)));

create policy nominees_self_select on public.nominees for select using (public.person_is_current_user(person_id));
create policy nominees_self_write on public.nominees for all using (public.person_is_current_user(person_id) or exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = nominees.person_id and public.is_org_admin(k.organization_id))) with check (public.person_is_current_user(person_id) or exists (select 1 from public.memberships m join public.kuris k on k.id = m.kuri_id where m.person_id = nominees.person_id and public.is_org_admin(k.organization_id)));

create policy files_org_admin on public.files for all using (public.is_org_admin(organization_id)) with check (public.is_org_admin(organization_id));
create policy audit_logs_org_admin on public.audit_logs for select using (public.is_org_admin(organization_id));

-- Enforce that payments cannot be allocated beyond the approved payment amount.
create or replace function public.validate_payment_allocation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  payment_total bigint;
  allocated_total bigint;
begin
  select amount into payment_total from public.payments where id = new.payment_id;
  select coalesce(sum(amount), 0) into allocated_total
  from public.payment_allocations
  where payment_id = new.payment_id and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);
  if allocated_total + new.amount > payment_total then
    raise exception 'Payment allocations cannot exceed the payment amount';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_payment_allocation on public.payment_allocations;
create trigger validate_payment_allocation before insert or update on public.payment_allocations for each row execute function public.validate_payment_allocation();

-- Keep installment paid totals synchronized with approved allocations.
create or replace function public.refresh_installment_paid_total(target_installment uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  total_paid bigint;
  due bigint;
begin
  select coalesce(sum(pa.amount), 0) into total_paid
  from public.payment_allocations pa
  join public.payments p on p.id = pa.payment_id
  where pa.installment_id = target_installment and p.status = 'APPROVED';
  select amount_due into due from public.installments where id = target_installment;
  update public.installments
  set amount_paid = least(total_paid, due),
      status = case
        when total_paid = 0 then 'UNPAID'::public.installment_status
        when total_paid < due then 'PARTIAL'::public.installment_status
        when total_paid >= due then 'PAID'::public.installment_status
        else status
      end
  where id = target_installment;
end;
$$;

create or replace function public.sync_installment_from_allocation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  perform public.refresh_installment_paid_total(coalesce(new.installment_id, old.installment_id));
  if tg_op = 'UPDATE' and old.installment_id <> new.installment_id then
    perform public.refresh_installment_paid_total(old.installment_id);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists sync_installment_from_allocation on public.payment_allocations;
create trigger sync_installment_from_allocation
after insert or update or delete on public.payment_allocations
for each row execute function public.sync_installment_from_allocation();

-- Audit helper for privileged operational changes.
create or replace function public.write_audit_log(
  target_org uuid,
  action_name text,
  entity_name text,
  target_entity uuid,
  before_data jsonb default null,
  after_data jsonb default null,
  change_reason text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, old_data, new_data, reason)
  values (target_org, auth.uid(), action_name, entity_name, target_entity, before_data, after_data, change_reason);
end;
$$;

revoke all on function public.write_audit_log(uuid, text, text, uuid, jsonb, jsonb, text) from public;
grant execute on function public.write_audit_log(uuid, text, text, uuid, jsonb, jsonb, text) to authenticated;
