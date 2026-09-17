"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function toInteger(value: FormDataEntryValue | null) {
  const parsed = Number(String(value ?? "").trim());
  return Number.isFinite(parsed) ? Math.trunc(parsed) : NaN;
}

export async function createKuri(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id, role")
    .eq("user_id", user.id)
    .in("role", ["MAIN_ADMIN", "ADMIN"])
    .limit(1)
    .maybeSingle();

  if (!membership?.organization_id) {
    redirect("/workspace?error=No%20admin%20workspace%20was%20found.");
  }

  const name = String(formData.get("name") ?? "").trim();
  const description = String(formData.get("description") ?? "").trim();
  const startDate = String(formData.get("start_date") ?? "").trim();
  const numberOfCycles = toInteger(formData.get("number_of_cycles"));
  const membershipLimit = toInteger(formData.get("membership_limit"));
  const installmentAmount = toInteger(formData.get("installment_amount"));
  const dueDay = toInteger(formData.get("due_day"));
  const drawDay = toInteger(formData.get("draw_day"));
  const grossPrizeAmount = toInteger(formData.get("gross_prize_amount"));
  const muppuAmount = toInteger(formData.get("muppu_amount"));
  const winnerRule = String(formData.get("winner_rule") ?? "ALL_PERSON_MEMBERSHIPS");
  const exitRefundRule = String(formData.get("exit_refund_rule") ?? "AT_MATURITY");

  if (
    !name ||
    !startDate ||
    !Number.isInteger(numberOfCycles) ||
    numberOfCycles <= 0 ||
    !Number.isInteger(membershipLimit) ||
    membershipLimit <= 0 ||
    !Number.isInteger(installmentAmount) ||
    installmentAmount < 0 ||
    !Number.isInteger(dueDay) ||
    dueDay < 1 ||
    dueDay > 31 ||
    !Number.isInteger(drawDay) ||
    drawDay < 1 ||
    drawDay > 31 ||
    !Number.isInteger(grossPrizeAmount) ||
    grossPrizeAmount < 0 ||
    !Number.isInteger(muppuAmount) ||
    muppuAmount < 0
  ) {
    redirect("/dashboard/kuri/new?error=Please%20enter%20valid%20Kuri%20details.");
  }

  const { data: kuri, error } = await supabase
    .from("kuris")
    .insert({
      organization_id: membership.organization_id,
      name,
      description: description || null,
      start_date: startDate,
      number_of_cycles: numberOfCycles,
      membership_limit: membershipLimit,
      installment_amount: installmentAmount,
      frequency: "MONTHLY",
      due_day: dueDay,
      draw_day: drawDay,
      gross_prize_amount: grossPrizeAmount,
      muppu_amount: muppuAmount,
      winner_rule: winnerRule,
      exit_refund_rule: exitRefundRule,
    })
    .select("id")
    .single();

  if (error || !kuri) {
    console.error("createKuri failed:", error);
    redirect("/dashboard/kuri/new?error=Unable%20to%20create%20Kuri.");
  }

  revalidatePath("/dashboard");
  revalidatePath("/dashboard/kuri");
  redirect(`/dashboard/kuri/${kuri.id}`);
}
