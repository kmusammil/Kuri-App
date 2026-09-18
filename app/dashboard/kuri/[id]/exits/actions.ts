"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

async function client() {
  const s = await createClient();
  const {
    data: { user },
  } = await s.auth.getUser();
  if (!user) redirect("/login");
  return s;
}

function path(kuriId: string) {
  return "/dashboard/kuri/" + kuriId + "/exits";
}

export async function createExit(formData: FormData) {
  const s = await client();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const membershipId = String(formData.get("membership_id") || "").trim();
  const reason = String(formData.get("reason") || "").trim();
  const exitDate = String(formData.get("exit_date") || "").trim();
  const policy = String(formData.get("refund_policy") || "").trim();
  const raw = String(formData.get("refund_amount") || "").trim();
  const refund = raw ? Number(raw) : null;

  const { error } = await s.rpc("create_membership_exit_for_admin", {
    target_membership_id: membershipId,
    exit_reason: reason,
    target_exit_date: exitDate,
    target_refund_policy: policy,
    target_refund_amount: refund,
    target_notes: String(formData.get("notes") || "").trim() || null,
  });

  if (error) redirect(path(kuriId) + "?error=" + encodeURIComponent(error.message));
  revalidatePath(path(kuriId));
  revalidatePath("/dashboard/kuri/" + kuriId);
  redirect(path(kuriId));
}

export async function approveExit(formData: FormData) {
  const s = await client();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const exitId = String(formData.get("exit_id") || "").trim();

  const { error } = await s.rpc("approve_membership_exit_for_admin", {
    target_exit_id: exitId,
  });

  if (error) redirect(path(kuriId) + "?error=" + encodeURIComponent(error.message));
  revalidatePath(path(kuriId));
  redirect(path(kuriId));
}

export async function recordImmediateRefund(formData: FormData) {
  const s = await client();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const exitId = String(formData.get("exit_id") || "").trim();
  const amount = Number(String(formData.get("refund_amount") || "0").trim());
  const method = String(formData.get("refund_method") || "").trim();
  const reference = String(formData.get("refund_reference") || "").trim() || null;
  const notes = String(formData.get("refund_notes") || "").trim() || null;

  const { error } = await s.rpc("record_membership_exit_refund_for_admin", {
    target_exit_id: exitId,
    refund_amount: amount,
    refund_payment_method: method,
    refund_reference: reference,
    refund_paid_at: new Date().toISOString(),
    refund_notes: notes,
  });

  if (error) redirect(path(kuriId) + "?error=" + encodeURIComponent(error.message));
  revalidatePath(path(kuriId));
  revalidatePath("/dashboard/kuri/" + kuriId);
  redirect(path(kuriId));
}

export async function settleExit(formData: FormData) {
  const s = await client();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const exitId = String(formData.get("exit_id") || "").trim();
  const reference = String(formData.get("settlement_reference") || "").trim() || null;

  const { error } = await s.rpc("settle_membership_exit_for_admin", {
    target_exit_id: exitId,
    settlement_payment_method: "WAIVED",
    settlement_reference: reference,
    settlement_date: new Date().toISOString(),
  });

  if (error) redirect(path(kuriId) + "?error=" + encodeURIComponent(error.message));
  revalidatePath(path(kuriId));
  revalidatePath("/dashboard/kuri/" + kuriId);
  redirect(path(kuriId));
}
