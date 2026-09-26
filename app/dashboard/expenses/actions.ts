"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

async function client() {
  const s = await createClient();
  const { data: { user } } = await s.auth.getUser();
  if (!user) redirect("/login");
  return s;
}

const pagePath = () => "/dashboard/expenses";

export async function createExpenseRule(formData: FormData) {
  const s = await client();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const name = String(formData.get("name") || "").trim();
  const description = String(formData.get("description") || "").trim() || null;
  const amount = Number(String(formData.get("amount") || "0").trim());
  const mode = String(formData.get("mode") || "ONE_TIME").trim();
  const intervalRaw = String(formData.get("interval") || "").trim();
  const startDate = String(formData.get("start_date") || "").trim();
  const endDate = String(formData.get("end_date") || "").trim();
  const customRaw = String(formData.get("custom_dates") || "").trim();

  const isOneTime = mode === "ONE_TIME";
  const recurrencePattern =
    isOneTime ? null : mode as "PER_CYCLE" | "WEEKLY" | "MONTHLY" | "YEARLY" | "CUSTOM";

  const recurrenceInterval =
    recurrencePattern && ["WEEKLY", "MONTHLY", "YEARLY"].includes(recurrencePattern)
      ? (intervalRaw ? Number(intervalRaw) : 1)
      : null;

  const customDates = recurrencePattern === "CUSTOM"
    ? customRaw.split(",").map((value) => value.trim()).filter(Boolean)
    : [];

  if (
    !kuriId ||
    !name ||
    !Number.isInteger(amount) ||
    amount <= 0 ||
    (recurrenceInterval !== null &&
      (!Number.isInteger(recurrenceInterval) || recurrenceInterval <= 0)) ||
    (recurrencePattern === "CUSTOM" && customDates.length === 0)
  ) {
    redirect(pagePath() + "?error=" + encodeURIComponent("Enter valid Expense rule details."));
  }

  const { error } = await s.rpc("create_expense_rule_for_admin", {
    target_kuri_id: kuriId,
    expense_name: name,
    expense_description: description,
    expense_frequency_value: isOneTime ? "ONE_TIME" : "RECURRING",
    expense_amount: amount,
    recurrence_pattern_value: recurrencePattern,
    recurrence_interval_value: recurrenceInterval,
    recurrence_start_date_value: recurrencePattern ? (startDate || null) : null,
    recurrence_end_date_value: recurrencePattern ? (endDate || null) : null,
    custom_schedule_dates: customDates.length ? customDates : null,
    activate_rule: true,
  });

  if (error) {
    redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  }

  revalidatePath(pagePath());
  redirect(pagePath());
}

export async function markPaid(formData: FormData) {
  const s = await client();
  const id = String(formData.get("obligation_id") || "").trim();
  const reference = String(formData.get("reference") || "").trim() || null;
  const paidAt = String(formData.get("paid_at") || "").trim() || null;

  const { error } = await s.rpc("mark_expense_obligation_paid_for_admin", {
    target_obligation_id: id,
    paid_reference: reference,
    target_paid_at: paidAt ? new Date(paidAt).toISOString() : null,
  });

  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}

export async function waive(formData: FormData) {
  const s = await client();
  const id = String(formData.get("obligation_id") || "").trim();
  const reason = String(formData.get("reason") || "").trim();

  const { error } = await s.rpc("waive_expense_obligation_for_admin", {
    target_obligation_id: id,
    waiver_reason: reason,
  });

  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}

export async function deduct(formData: FormData) {
  const s = await client();
  const id = String(formData.get("obligation_id") || "").trim();
  const payoutId = String(formData.get("payout_id") || "").trim();
  const reference = String(formData.get("reference") || "").trim() || null;

  const { error } = await s.rpc("deduct_expense_from_prize_for_admin", {
    target_obligation_id: id,
    target_payout_id: payoutId,
    deduction_reference: reference,
  });

  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}
