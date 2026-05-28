# Supabase/Postgres Scaffold (Money Copilot Reboot)

## 1) SQL scaffold
Use: `supabase/schema.sql`

## 2) Table-by-table explanation
- **profiles**: auth-linked user profile (1:1 with `auth.users`).
- **people**: contacts for debt/refund/transaction context.
- **accounts**: user financial accounts (cash, bank, card, etc.). No stored balances.
- **categories**: normalized category tree for spending/income grouping.
- **transactions**: canonical ledger and source of truth for money movement (`transfer_side` handles transfer in/out direction).
- **cashback_cycles**: cycle windows per account for card cashback accounting.
- **cashback_entries**: cashback amounts tied to a cycle and source/posting transaction.
- **debts**: debt principal/outstanding records, always linked to person + account.
- **debt_repayments**: repayment events linked to both debt and transaction.
- **refunds**: refund case tied to original transaction, status + current stage.
- **refund_stage_history**: normalized GD1/GD2/GD3 progression history.
- **budgets**: monthly per-owner per-category budget limits.
- **installment_plans**: installment contracts linked to either transaction or debt.
- **installment_payments**: per-installment payment rows and ledger linkage.
- **recurring_services**: subscription/recurring billing schedule with auto-generation support.
- **audit_logs**: append-only audit trail table for business events.
- **sheet_sync_queue** *(optional)*: outbound sheet sync retry queue.
- **account_posted_balances** *(view)*: computed posted balances from transactions.

## 3) Index recommendations
The SQL scaffold already creates workload-focused indexes, including:
- owner/date indexes for ledger and reporting (`transactions`, `budgets`, `audit_logs`)
- account/cycle indexes for cashback and card statements
- status/due-date indexes for recurring services and queue processing
- relationship indexes for debts, installments, refunds, and histories

## 4) Constraints/validation notes
- UUID primary keys on all tables.
- Explicit foreign keys on all relationships.
- Enums/check constraints for all typed status/type fields.
- Monetary values are integer VND (`*_vnd` integer columns).
- `transactions` are the ledger source of truth; `account_posted_balances` computes balances.
- Transfer rows must set `transfer_side` (`in` or `out`) for correct per-account balance math.
- Debt integrity enforced with required `person_id` and `account_id`.
- Budget uniqueness enforced by `(owner_id, category_id, cycle_month)`.
- Installment plans enforce exactly one source (`original_transaction_id` XOR `debt_id`).
- Refund workflow supports staged progression via `refund_stage_history`.
- `audit_logs` is append-only (update/delete blocked by trigger).
