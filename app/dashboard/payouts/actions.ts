"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function payoutPath(winnerId: string) {
  return "/dashboard/payouts/" + winnerId;
}

async function getClient() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  return supabase;
}

export async function preparePayout(formData: FormData) {
  const supabase = await getClient();
  const winnerId = String(formData.get("winner_id") || "").trim();
  if (!winnerId) redirect("/dashboard/payouts");

  const { error } = await supabase.rpc("prepare_payout_for_admin", {
    target_winner_id: winnerId,
  });
  if (error) {
    redirect(
      "/dashboard/payouts?error=" + encodeURIComponent(error.message),
    );
  }

  revalidatePath("/dashboard/payouts");
  revalidatePath(payoutPath(winnerId));
  redirect(payoutPath(winnerId));
}

export async function markPayoutPaid(formData: FormData) {
  const supabase = await getClient();
  const winnerId = String(formData.get("winner_id") || "").trim();
  const paymentDate = String(formData.get("payment_date") || "").trim();
  const method = String(formData.get("method") || "").trim();
  const deductions = Number(formData.get("other_deductions") || 0);

  if (
    !winnerId ||
    !paymentDate ||
    !["UPI", "BANK_TRANSFER", "CASH", "OTHER"].includes(method) ||
    !Number.isInteger(deductions) ||
    deductions < 0
  ) {
    redirect(
      payoutPath(winnerId) +
        "?error=" +
        encodeURIComponent("Invalid payout details."),
    );
  }

  const parsedDate = new Date(paymentDate);
  if (Number.isNaN(parsedDate.getTime())) {
    redirect(
      payoutPath(winnerId) +
        "?error=" +
        encodeURIComponent("Invalid payment date."),
    );
  }

  const { error } = await supabase.rpc("mark_payout_paid_for_admin", {
    target_winner_id: winnerId,
    payout_payment_date: parsedDate.toISOString(),
    payout_method: method,
    payout_reference:
      String(formData.get("reference") || "").trim() || null,
    payout_notes: String(formData.get("notes") || "").trim() || null,
    payout_other_deductions: deductions,
  });

  if (error) {
    redirect(
      payoutPath(winnerId) + "?error=" + encodeURIComponent(error.message),
    );
  }

  revalidatePath("/dashboard/payouts");
  revalidatePath(payoutPath(winnerId));
  redirect(payoutPath(winnerId));
}
