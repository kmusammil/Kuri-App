-- Kuri-App foundation schema
create extension if not exists pgcrypto;

create type app_role as enum ('MAIN_ADMIN','ADMIN','MEMBER');
create type user_status as enum ('ACTIVE','SUSPENDED');
create type kuri_frequency as enum ('MONTHLY');
create type kuri_status as enum ('DRAFT','OPEN','ACTIVE','COMPLETED','ARCHIVED');
create type membership_status as enum ('PENDING','ACTIVE','SUSPENDED','EXITED','COMPLETED','TRANSFERRED');
create type cycle_status as enum ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING','COMPLETED','CANCELLED');
create type installment_status as enum ('UNPAID','PARTIAL','PAID','PAID_LATE','ADVANCE','WAIVED');
create type payment_method as enum ('UPI','BANK_TRANSFER','CASH','OTHER');
create type payment_status as enum ('PENDING_VERIFICATION','APPROVED','REJECTED','CANCELLED');
create type muppu_status as enum ('UNPAID','PAID','DEDUCTED','WAIVED');
create type muppu_settlement_method as enum ('PAID_IN_ADVANCE','DEDUCTED_FROM_PRIZE','WAIVED');
create type draw_status as enum ('DRAFT','POOL_READY','DRAWING','RESULTS_READY','FINALIZED','CANCELLED');
create type payout_status as enum ('PENDING','PROCESSING','PAID','CANCELLED');
create type settlement_reason as enum ('VOLUNTARY_EXIT','DEATH','OTHER');
create type refund_policy as enum ('AT_MATURITY','IMMEDIATE');
create type settlement_status as enum ('PENDING','APPROVED','SETTLED','CANCELLED');
create type winner_source as enum ('RANDOM_DRAW','ADMIN_OVERRIDE');

create table organizations (
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

create table people (
  id uuid primary key default gen_random_uuid(),
  registered_name text not null,
  display_name text,
  address text,
  photo_url text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table users (
  id uuid primary key references auth.users(id) on delete cascade,
  person_id uuid references people(id) on delete set null,
  email text,
  phone text,
  status user_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  last_login_at timestamptz
);

create table organization_users (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role app_role not null,
  created_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create table person_phones (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references people(id) on delete cascade,
  phone_number text not null,
  label text,
  is_primary boolean not null default false
);

create table person_emails (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references people(id) on delete cascade,
  email text not null,
  label text,
  is_primary boolean not null default false
);

create table kuris (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete restrict,
  name text not null,
  description text,
  start_date date not null,
  number_of_cycles integer not null check (number_of_cycles > 0),
  membership_limit integer not null check (membership_limit > 0),
  installment_amount bigint not null check (installment_amount >= 0),
  frequency kuri_frequency not null default 'MONTHLY',
  due_day integer not null check (due_day between 1 and 31),
  draw_day integer not null check (draw_day between 1 and 31),
  gross_prize_amount bigint not null check (gross_prize_amount >= 0),
  muppu_amount bigint not null default 0 check (muppu_amount >= 0),
  draw_eligibility_rule text not null default 'PAID_INSTALLMENT',
  winner_rule text not null default 'ALL_PERSON_MEMBERSHIPS',
  exit_refund_rule refund_policy not null default 'AT_MATURITY',
  status kuri_status not null default 'DRAFT',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table memberships (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references kuris(id) on delete restrict,
  person_id uuid not null references people(id) on delete restrict,
  membership_number text not null,
  status membership_status not null default 'PENDING',
  joined_at timestamptz not null default now(),
  exited_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (kuri_id, membership_number)
);

create table cycles (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references kuris(id) on delete restrict,
  cycle_number integer not null check (cycle_number > 0),
  period_start date not null,
  period_end date not null,
  due_date date not null,
  draw_date date not null,
  status cycle_status not null default 'UPCOMING',
  created_at timestamptz not null default now(),
  unique (kuri_id, cycle_number),
  check (period_end >= period_start)
);

create table installments (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references memberships(id) on delete restrict,
  cycle_id uuid not null references cycles(id) on delete restrict,
  amount_due bigint not null check (amount_due >= 0),
  amount_paid bigint not null default 0 check (amount_paid >= 0),
  status installment_status not null default 'UNPAID',
  due_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (membership_id, cycle_id)
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references people(id) on delete restrict,
  amount bigint not null check (amount > 0),
  payment_date timestamptz not null,
  method payment_method not null,
  reference_number text,
  proof_file_id uuid,
  status payment_status not null default 'PENDING_VERIFICATION',
  submitted_at timestamptz not null default now(),
  verified_at timestamptz,
  verified_by uuid references users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create table payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references payments(id) on delete restrict,
  installment_id uuid not null references installments(id) on delete restrict,
  amount bigint not null check (amount > 0),
  allocated_at timestamptz not null default now(),
  allocated_by uuid references users(id) on delete set null,
  unique (payment_id, installment_id)
);

create table muppu_records (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references kuris(id) on delete restrict,
  cycle_id uuid not null references cycles(id) on delete restrict,
  person_id uuid not null references people(id) on delete restrict,
  amount bigint not null check (amount >= 0),
  status muppu_status not null default 'UNPAID',
  settlement_method muppu_settlement_method,
  paid_at timestamptz,
  payment_reference text,
  created_at timestamptz not null default now()
);

create table draw_sessions (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references kuris(id) on delete restrict,
  cycle_id uuid not null references cycles(id) on delete restrict,
  conducted_by uuid not null references users(id) on delete restrict,
  status draw_status not null default 'DRAFT',
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (kuri_id, cycle_id)
);

create table draw_pool_entries (
  id uuid primary key default gen_random_uuid(),
  draw_session_id uuid not null references draw_sessions(id) on delete cascade,
  membership_id uuid not null references memberships(id) on delete restrict,
  system_eligible boolean not null,
  admin_included boolean not null,
  override boolean not null default false,
  override_reason text,
  modified_by uuid references users(id) on delete set null,
  modified_at timestamptz not null default now(),
  unique (draw_session_id, membership_id)
);

create table draw_selections (
  id uuid primary key default gen_random_uuid(),
  draw_session_id uuid not null references draw_sessions(id) on delete cascade,
  membership_id uuid not null references memberships(id) on delete restrict,
  selection_order integer not null check (selection_order > 0),
  selected_at timestamptz not null default now(),
  randomization_id text
);

create table monthly_winners (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references cycles(id) on delete restrict,
  person_id uuid not null references people(id) on delete restrict,
  selection_source winner_source not null,
  finalized_by uuid not null references users(id) on delete restrict,
  finalized_at timestamptz not null default now(),
  status text not null default 'FINALIZED',
  notes text
);

create table monthly_winner_memberships (
  id uuid primary key default gen_random_uuid(),
  monthly_winner_id uuid not null references monthly_winners(id) on delete cascade,
  membership_id uuid not null references memberships(id) on delete restrict,
  award_amount bigint not null default 0 check (award_amount >= 0),
  created_at timestamptz not null default now(),
  unique (monthly_winner_id, membership_id)
);

create table payouts (
  id uuid primary key default gen_random_uuid(),
  monthly_winner_id uuid not null references monthly_winners(id) on delete restrict,
  gross_amount bigint not null check (gross_amount >= 0),
  muppu_amount bigint not null default 0 check (muppu_amount >= 0),
  other_deductions bigint not null default 0 check (other_deductions >= 0),
  net_amount bigint not null check (net_amount >= 0),
  payment_date timestamptz,
  method payment_method,
  reference_number text,
  status payout_status not null default 'PENDING',
  processed_by uuid references users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create table membership_exits (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references memberships(id) on delete restrict,
  reason settlement_reason not null,
  exit_date date not null,
  refund_policy refund_policy not null default 'AT_MATURITY',
  amount_contributed bigint not null default 0 check (amount_contributed >= 0),
  refund_amount bigint not null default 0 check (refund_amount >= 0),
  status settlement_status not null default 'PENDING',
  approved_by uuid references users(id) on delete set null,
  settled_at timestamptz,
  notes text
);

create table nominees (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references people(id) on delete cascade,
  name text not null,
  relationship text,
  phone text,
  address text,
  notes text
);

create table files (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete restrict,
  uploaded_by uuid references users(id) on delete set null,
  file_type text not null,
  storage_key text not null,
  original_name text,
  mime_type text,
  size_bytes bigint check (size_bytes >= 0),
  created_at timestamptz not null default now()
);

alter table payments add constraint payments_proof_file_fk foreign key (proof_file_id) references files(id) on delete set null;

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete restrict,
  user_id uuid references users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  reason text,
  created_at timestamptz not null default now()
);

create index memberships_kuri_idx on memberships(kuri_id);
create index memberships_person_idx on memberships(person_id);
create index cycles_kuri_idx on cycles(kuri_id);
create index installments_membership_idx on installments(membership_id);
create index installments_cycle_idx on installments(cycle_id);
create index payments_person_idx on payments(person_id);
create index payment_allocations_installment_idx on payment_allocations(installment_id);
create index draw_pool_session_idx on draw_pool_entries(draw_session_id);
create index draw_selections_session_idx on draw_selections(draw_session_id);
create index monthly_winners_cycle_idx on monthly_winners(cycle_id);
create index payouts_winner_idx on payouts(monthly_winner_id);
create index audit_logs_org_time_idx on audit_logs(organization_id, created_at desc);

create or replace function public.is_org_member(target_org uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from organization_users ou
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
  );
$$;

create or replace function public.has_org_role(target_org uuid, target_roles app_role[])
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from organization_users ou
    where ou.organization_id = target_org
      and ou.user_id = auth.uid()
      and ou.role = any(target_roles)
  );
$$;

alter table organizations enable row level security;
alter table users enable row level security;
alter table organization_users enable row level security;
alter table people enable row level security;
alter table person_phones enable row level security;
alter table person_emails enable row level security;
alter table kuris enable row level security;
alter table memberships enable row level security;
alter table cycles enable row level security;
alter table installments enable row level security;
alter table payments enable row level security;
alter table payment_allocations enable row level security;
alter table muppu_records enable row level security;
alter table draw_sessions enable row level security;
alter table draw_pool_entries enable row level security;
alter table draw_selections enable row level security;
alter table monthly_winners enable row level security;
alter table monthly_winner_memberships enable row level security;
alter table payouts enable row level security;
alter table membership_exits enable row level security;
alter table nominees enable row level security;
alter table files enable row level security;
alter table audit_logs enable row level security;

-- Organization-scoped reads.
create policy organizations_select on organizations for select using (public.is_org_member(id));
create policy organization_users_select on organization_users for select using (public.is_org_member(organization_id));
create policy kuris_select on kuris for select using (public.is_org_member(organization_id));
create policy memberships_select on memberships for select using (
  exists (select 1 from kuris k where k.id = memberships.kuri_id and public.is_org_member(k.organization_id))
);
create policy cycles_select on cycles for select using (
  exists (select 1 from kuris k where k.id = cycles.kuri_id and public.is_org_member(k.organization_id))
);
create policy people_select on people for select using (
  exists (
    select 1 from organization_users ou
    where ou.user_id = auth.uid()
      and exists (select 1 from memberships m join kuris k on k.id=m.kuri_id where m.person_id=people.id and k.organization_id=ou.organization_id)
  )
  or exists (select 1 from users u where u.id=auth.uid() and u.person_id=people.id)
);

-- Additional organization-scoped tables. Privileged mutations are implemented through server-side actions.
create policy installments_select on installments for select using (
  exists (select 1 from memberships m join kuris k on k.id=m.kuri_id where m.id=installments.membership_id and public.is_org_member(k.organization_id))
);
create policy payments_select on payments for select using (
  exists (select 1 from users u where u.id=auth.uid() and u.person_id=payments.person_id)
  or public.has_org_role((select k.organization_id from memberships m join kuris k on k.id=m.kuri_id join installments i on i.membership_id=m.id join payment_allocations pa on pa.installment_id=i.id where pa.payment_id=payments.id limit 1), array['MAIN_ADMIN','ADMIN']::app_role[])
);
create policy payment_allocations_select on payment_allocations for select using (
  exists (
    select 1 from installments i join memberships m on m.id=i.membership_id join kuris k on k.id=m.kuri_id
    where i.id=payment_allocations.installment_id and public.is_org_member(k.organization_id)
  )
);
create policy audit_logs_select on audit_logs for select using (public.is_org_member(organization_id));

-- Members can view their own authentication/application record.
create policy users_self_select on users for select using (id = auth.uid());

-- Sensitive draw/payment/winner tables are organization-scoped; detailed member exposure is restricted further in application queries/views.
create policy muppu_select on muppu_records for select using (public.is_org_member((select k.organization_id from kuris k where k.id=muppu_records.kuri_id)));
create policy draw_sessions_select on draw_sessions for select using (public.is_org_member((select k.organization_id from kuris k where k.id=draw_sessions.kuri_id)));
create policy draw_pool_select on draw_pool_entries for select using (
  public.is_org_member((select k.organization_id from draw_sessions d join kuris k on k.id=d.kuri_id where d.id=draw_pool_entries.draw_session_id))
);
create policy draw_selection_select on draw_selections for select using (
  public.is_org_member((select k.organization_id from draw_sessions d join kuris k on k.id=d.kuri_id where d.id=draw_selections.draw_session_id))
);
create policy winner_select on monthly_winners for select using (
  public.is_org_member((select k.organization_id from cycles c join kuris k on k.id=c.kuri_id where c.id=monthly_winners.cycle_id))
);
create policy winner_membership_select on monthly_winner_memberships for select using (
  public.is_org_member((select k.organization_id from monthly_winners w join cycles c on c.id=w.cycle_id join kuris k on k.id=c.kuri_id where w.id=monthly_winner_memberships.monthly_winner_id))
);
create policy payouts_select on payouts for select using (
  public.is_org_member((select k.organization_id from monthly_winners w join cycles c on c.id=w.cycle_id join kuris k on k.id=c.kuri_id where w.id=payouts.monthly_winner_id))
);
create policy membership_exits_select on membership_exits for select using (
  public.is_org_member((select k.organization_id from memberships m join kuris k on k.id=m.kuri_id where m.id=membership_exits.membership_id))
);
create policy nominees_select on nominees for select using (
  exists (select 1 from users u where u.id=auth.uid() and u.person_id=nominees.person_id)
);
create policy files_select on files for select using (public.is_org_member(organization_id));

-- Bootstrap trigger: create application user row after Supabase Auth signup.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, phone)
  values (new.id, new.email, new.phone)
  on conflict (id) do update set email = excluded.email, phone = excluded.phone;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_auth_user();
