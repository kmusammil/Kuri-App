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

function pagePath() { return "/dashboard/muppu"; }

export async function createMuppu(formData: FormData) {
  const s = await client();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const cycleId = String(formData.get("cycle_id") || "").trim();
  const personId = String(formData.get("person_id") || "").trim();
  const amount = Number(String(formData.get("amount") || "0").trim());

  const { error } = await s.rpc("create_muppu_record_for_admin", {
    target_kuri_id: kuriId,
    target_cycle_id: cycleId,
    target_person_id: personId,
    target_amount: amount,
  });

  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}

export async function markPaid(formData: FormData) {
  const s = await client();
  const id = String(formData.get("muppu_id") || "").trim();
  const reference = String(formData.get("reference") || "").trim() || null;
  const { error } = await s.rpc("mark_muppu_paid_for_admin", {
    target_muppu_id: id,
    paid_payment_reference: reference,
    paid_at_value: new Date().toISOString(),
  });
  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}

export async function waive(formData: FormData) {
  const s = await client();
  const id = String(formData.get("muppu_id") || "").trim();
  const reference = String(formData.get("reference") || "").trim() || null;
  const { error } = await s.rpc("waive_muppu_for_admin", {
    target_muppu_id: id,
    waiver_reference: reference,
  });
  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}

export async function deduct(formData: FormData) {
  const s = await client();
  const id = String(formData.get("muppu_id") || "").trim();
  const reference = String(formData.get("reference") || "").trim() || null;
  const { error } = await s.rpc("deduct_muppu_from_prize_for_admin", {
    target_muppu_id: id,
    deduction_reference: reference,
  });
  if (error) redirect(pagePath() + "?error=" + encodeURIComponent(error.message));
  revalidatePath(pagePath());
  redirect(pagePath());
}
