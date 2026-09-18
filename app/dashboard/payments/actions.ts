"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function createPayment(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const personId = String(formData.get("person_id") || "").trim();
  const amount = Number(formData.get("amount"));
  const paymentDate = String(formData.get("payment_date") || "").trim();
  const method = String(formData.get("method") || "").trim();

  if (!personId || !Number.isInteger(amount) || amount <= 0 || !paymentDate ||
      !["UPI", "BANK_TRANSFER", "CASH", "OTHER"].includes(method)) {
    redirect("/dashboard/payments/new?error=Invalid%20payment%20details.");
  }

  const { data: paymentId, error } = await supabase.rpc("create_payment_for_admin", {
    target_person_id: personId,
    payment_amount: amount,
    payment_date: new Date(paymentDate).toISOString(),
    payment_method: method,
    payment_reference: String(formData.get("reference_number") || "").trim() || null,
    payment_notes: String(formData.get("notes") || "").trim() || null,
  });

  if (error || !paymentId) {
    redirect("/dashboard/payments/new?error=" + encodeURIComponent(error?.message || "Unable to record payment."));
  }

  revalidatePath("/dashboard/payments");
  redirect("/dashboard/payments/" + paymentId);
}

export async function allocatePayment(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const paymentId = String(formData.get("payment_id") || "").trim();
  const installmentId = String(formData.get("installment_id") || "").trim();
  const amount = Number(formData.get("allocation_amount"));

  if (!paymentId || !installmentId || !Number.isInteger(amount) || amount <= 0) {
    redirect("/dashboard/payments/" + paymentId + "?error=Invalid%20allocation.");
  }

  const { error } = await supabase.rpc("allocate_payment_for_admin", {
    target_payment_id: paymentId,
    target_installment_id: installmentId,
    allocation_amount: amount,
  });

  if (error) redirect("/dashboard/payments/" + paymentId + "?error=" + encodeURIComponent(error.message));
  revalidatePath("/dashboard/payments/" + paymentId);
  revalidatePath("/dashboard/payments");
  redirect("/dashboard/payments/" + paymentId);
}
