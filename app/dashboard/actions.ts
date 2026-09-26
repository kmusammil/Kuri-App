"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function createKuri(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const name = String(formData.get("name") ?? "").trim();
  const startDate = String(formData.get("start_date") ?? "").trim();
  const numberOfCycles = Number(formData.get("number_of_cycles"));
  const membershipLimit = Number(formData.get("membership_limit"));
  const installmentAmount = Number(formData.get("installment_amount"));
  const dueDay = Number(formData.get("due_day"));
  const drawDay = Number(formData.get("draw_day"));
  const grossPrizeAmount = Number(formData.get("gross_prize_amount"));
  const expenseAmount = Number(formData.get("expense_amount"));

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
    !Number.isInteger(expenseAmount) ||
    expenseAmount < 0
  ) {
    redirect("/dashboard?error=Please%20enter%20valid%20Kuri%20details.");
  }

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id, role")
    .eq("user_id", user.id)
    .limit(10);

  const organizationMembership = (memberships ?? []).find(
    (item) => item.role === "MAIN_ADMIN" || item.role === "ADMIN"
  );

  if (!organizationMembership?.organization_id) {
    redirect("/workspace?error=Create%20a%20workspace%20before%20creating%20a%20Kuri.");
  }

  const { data: kuriId, error } = await supabase.rpc("create_kuri_for_admin", {
    name,
    description: null,
    start_date: startDate,
    number_of_cycles: numberOfCycles,
    membership_limit: membershipLimit,
    installment_amount: installmentAmount,
    due_day: dueDay,
    draw_day: drawDay,
    gross_prize_amount: grossPrizeAmount,
    expense_amount: expenseAmount,
    winner_rule: "ALL_PERSON_MEMBERSHIPS",
    exit_refund_rule: "AT_MATURITY",
    frequency_value: "MONTHLY",
    schedule_mode_value: "STANDARD",
  });

  if (error || !kuriId) {
    console.error("createKuri failed:", error);
    redirect("/dashboard?error=Unable%20to%20create%20Kuri.");
  }

  revalidatePath("/dashboard");
  redirect(`/dashboard/kuri/${kuriId}`);
}
