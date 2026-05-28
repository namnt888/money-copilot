-- Money Copilot reboot schema (Supabase/Postgres)
-- Amount convention: all monetary amounts are INTEGER VND (minor unit strategy: integer only).

create extension if not exists pgcrypto;

-- ---------- Enums ----------
create type public.account_type as enum ('cash', 'bank', 'credit_card', 'ewallet', 'loan', 'other');
create type public.account_status as enum ('active', 'inactive', 'closed');
create type public.transaction_type as enum ('expense', 'income', 'transfer', 'debt_disbursement', 'debt_repayment', 'refund', 'cashback', 'installment_payment', 'adjustment');
create type public.transaction_status as enum ('pending', 'posted', 'voided');
create type public.cashback_cycle_status as enum ('open', 'closed', 'paid_out');
create type public.debt_status as enum ('open', 'paid', 'written_off');
create type public.refund_status as enum ('initiated', 'in_review', 'approved', 'paid', 'rejected', 'cancelled');
create type public.refund_stage as enum ('gd1', 'gd2', 'gd3');
create type public.installment_status as enum ('active', 'completed', 'cancelled');
create type public.recurring_service_status as enum ('active', 'paused', 'cancelled');
create type public.audit_action as enum ('insert', 'update', 'delete', 'status_change');

-- ---------- User profile linked to auth.users ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  default_currency text not null default 'VND' check (default_currency = 'VND'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Reference / master entities ----------
create table public.people (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null,
  relationship text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, full_name)
);

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  type public.account_type not null,
  status public.account_status not null default 'active',
  institution_name text,
  credit_limit_vnd integer check (credit_limit_vnd is null or credit_limit_vnd >= 0),
  statement_day smallint check (statement_day between 1 and 31),
  payment_due_day smallint check (payment_due_day between 1 and 31),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, name)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  parent_id uuid references public.categories(id) on delete set null,
  direction text not null check (direction in ('expense', 'income', 'both')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, name)
);

-- ---------- Core ledger (source of truth) ----------
create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete restrict,
  category_id uuid references public.categories(id) on delete set null,
  related_person_id uuid references public.people(id) on delete set null,
  recurring_service_id uuid,
  type public.transaction_type not null,
  status public.transaction_status not null default 'posted',
  amount_vnd integer not null check (amount_vnd > 0),
  occurred_at timestamptz not null,
  description text,
  transfer_pair_id uuid,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Cashback ----------
create table public.cashback_cycles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete restrict,
  cycle_start date not null,
  cycle_end date not null,
  payout_date date,
  status public.cashback_cycle_status not null default 'open',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cycle_end >= cycle_start),
  unique (account_id, cycle_start, cycle_end)
);

create table public.cashback_entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  cashback_cycle_id uuid not null references public.cashback_cycles(id) on delete cascade,
  transaction_id uuid references public.transactions(id) on delete set null,
  cashback_amount_vnd integer not null check (cashback_amount_vnd >= 0),
  earned_at timestamptz not null,
  posted_transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now(),
  check (transaction_id is not null or posted_transaction_id is not null)
);

-- ---------- Debt tracking ----------
create table public.debts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete restrict,
  account_id uuid not null references public.accounts(id) on delete restrict,
  principal_vnd integer not null check (principal_vnd > 0),
  outstanding_vnd integer not null check (outstanding_vnd >= 0),
  issued_at timestamptz not null,
  due_at timestamptz,
  status public.debt_status not null default 'open',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (outstanding_vnd <= principal_vnd)
);

create table public.debt_repayments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  debt_id uuid not null references public.debts(id) on delete cascade,
  transaction_id uuid not null references public.transactions(id) on delete restrict,
  repaid_amount_vnd integer not null check (repaid_amount_vnd > 0),
  repaid_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (debt_id, transaction_id)
);

-- ---------- Refunds (multi-stage) ----------
create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  original_transaction_id uuid not null references public.transactions(id) on delete restrict,
  account_id uuid not null references public.accounts(id) on delete restrict,
  amount_vnd integer not null check (amount_vnd > 0),
  status public.refund_status not null default 'initiated',
  current_stage public.refund_stage not null default 'gd1',
  requested_at timestamptz not null,
  resolved_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.refund_stage_history (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.refunds(id) on delete cascade,
  stage public.refund_stage not null,
  entered_at timestamptz not null default now(),
  exited_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  unique (refund_id, stage)
);

-- ---------- Budgets ----------
create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  category_id uuid not null references public.categories(id) on delete restrict,
  cycle_month date not null,
  amount_limit_vnd integer not null check (amount_limit_vnd >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cycle_month = date_trunc('month', cycle_month)::date),
  unique (owner_id, category_id, cycle_month)
);

-- ---------- Installments ----------
create table public.installment_plans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete restrict,
  original_transaction_id uuid references public.transactions(id) on delete set null,
  debt_id uuid references public.debts(id) on delete set null,
  principal_vnd integer not null check (principal_vnd > 0),
  installment_count integer not null check (installment_count > 0),
  installment_amount_vnd integer not null check (installment_amount_vnd > 0),
  start_date date not null,
  status public.installment_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(original_transaction_id, debt_id) = 1)
);

create table public.installment_payments (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  installment_plan_id uuid not null references public.installment_plans(id) on delete cascade,
  transaction_id uuid not null references public.transactions(id) on delete restrict,
  installment_number integer not null check (installment_number > 0),
  amount_vnd integer not null check (amount_vnd > 0),
  due_date date,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (installment_plan_id, installment_number),
  unique (transaction_id)
);

-- ---------- Recurring services ----------
create table public.recurring_services (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete restrict,
  category_id uuid references public.categories(id) on delete set null,
  service_name text not null,
  expected_amount_vnd integer not null check (expected_amount_vnd >= 0),
  cadence text not null check (cadence in ('daily', 'weekly', 'monthly', 'yearly', 'custom')),
  cadence_interval integer not null default 1 check (cadence_interval > 0),
  next_due_at timestamptz not null,
  auto_generate_transaction boolean not null default true,
  status public.recurring_service_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, service_name, account_id)
);

-- After recurring_services exists, add deferred FK for transactions.recurring_service_id.
alter table public.transactions
  add constraint fk_transactions_recurring_service
  foreign key (recurring_service_id) references public.recurring_services(id) on delete set null;

-- ---------- Audit log (append-only) ----------
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  table_name text not null,
  record_id uuid not null,
  action public.audit_action not null,
  changed_at timestamptz not null default now(),
  change_summary jsonb,
  request_id text,
  ip_address inet
);

create or replace function public.prevent_audit_log_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_logs is append-only';
end;
$$;

create trigger trg_audit_logs_no_update
before update on public.audit_logs
for each row execute function public.prevent_audit_log_mutation();

create trigger trg_audit_logs_no_delete
before delete on public.audit_logs
for each row execute function public.prevent_audit_log_mutation();

-- ---------- Optional sheet sync queue ----------
create table public.sheet_sync_queue (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  entity_name text not null,
  entity_id uuid not null,
  operation text not null check (operation in ('upsert', 'delete')),
  status text not null default 'pending' check (status in ('pending', 'processing', 'done', 'failed')),
  retry_count integer not null default 0 check (retry_count >= 0),
  available_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- Derived balances ----------
create view public.account_posted_balances as
select
  a.id as account_id,
  a.owner_id,
  coalesce(sum(
    case t.type
      when 'income' then t.amount_vnd
      when 'refund' then t.amount_vnd
      when 'cashback' then t.amount_vnd
      when 'expense' then -t.amount_vnd
      when 'debt_disbursement' then -t.amount_vnd
      when 'debt_repayment' then t.amount_vnd
      when 'installment_payment' then -t.amount_vnd
      when 'adjustment' then t.amount_vnd
      else 0
    end
  ), 0) as balance_vnd
from public.accounts a
left join public.transactions t
  on t.account_id = a.id and t.status = 'posted'
group by a.id, a.owner_id;

-- ---------- Index recommendations (created) ----------
create index idx_people_owner on public.people(owner_id, is_active);
create index idx_accounts_owner_status on public.accounts(owner_id, status);
create index idx_categories_owner_direction on public.categories(owner_id, direction);
create index idx_transactions_owner_occurred on public.transactions(owner_id, occurred_at desc);
create index idx_transactions_account_status_occurred on public.transactions(account_id, status, occurred_at desc);
create index idx_transactions_type_status on public.transactions(type, status);
create index idx_cashback_cycles_account_dates on public.cashback_cycles(account_id, cycle_start, cycle_end);
create index idx_cashback_entries_cycle on public.cashback_entries(cashback_cycle_id, earned_at desc);
create index idx_debts_owner_status on public.debts(owner_id, status);
create index idx_debt_repayments_debt_repaid_at on public.debt_repayments(debt_id, repaid_at desc);
create index idx_refunds_owner_status_stage on public.refunds(owner_id, status, current_stage);
create index idx_refund_stage_history_refund_entered on public.refund_stage_history(refund_id, entered_at);
create index idx_budgets_owner_cycle on public.budgets(owner_id, cycle_month);
create index idx_installment_plans_owner_status on public.installment_plans(owner_id, status);
create index idx_installment_payments_plan_number on public.installment_payments(installment_plan_id, installment_number);
create index idx_recurring_services_due_status on public.recurring_services(owner_id, status, next_due_at);
create index idx_audit_logs_owner_changed on public.audit_logs(owner_id, changed_at desc);
create index idx_sheet_sync_queue_status_available on public.sheet_sync_queue(status, available_at);

-- ---------- Shared updated_at trigger ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger trg_people_updated_at before update on public.people for each row execute function public.set_updated_at();
create trigger trg_accounts_updated_at before update on public.accounts for each row execute function public.set_updated_at();
create trigger trg_categories_updated_at before update on public.categories for each row execute function public.set_updated_at();
create trigger trg_transactions_updated_at before update on public.transactions for each row execute function public.set_updated_at();
create trigger trg_cashback_cycles_updated_at before update on public.cashback_cycles for each row execute function public.set_updated_at();
create trigger trg_debts_updated_at before update on public.debts for each row execute function public.set_updated_at();
create trigger trg_refunds_updated_at before update on public.refunds for each row execute function public.set_updated_at();
create trigger trg_budgets_updated_at before update on public.budgets for each row execute function public.set_updated_at();
create trigger trg_installment_plans_updated_at before update on public.installment_plans for each row execute function public.set_updated_at();
create trigger trg_recurring_services_updated_at before update on public.recurring_services for each row execute function public.set_updated_at();
create trigger trg_sheet_sync_queue_updated_at before update on public.sheet_sync_queue for each row execute function public.set_updated_at();
