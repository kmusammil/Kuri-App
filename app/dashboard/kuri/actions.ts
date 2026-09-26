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

  const name = String(formData.get("name") ?? "").trim();
  const description = String(formData.get("description") ?? "").trim();
  const startDate = String(formData.get("start_date") ?? "").trim();
  const numberOfCycles = toInteger(formData.get("number_of_cycles"));
  const membershipLimit = toInteger(formData.get("membership_limit"));
  const installmentAmount = toInteger(formData.get("installment_amount"));
  const dueDay = toInteger(formData.get("due_day"));
  const drawDay = toInteger(formData.get("draw_day"));
  const grossPrizeAmount = toInteger(formData.get("gross_prize_amount"));
  const expenseAmount = toInteger(formData.get("expense_amount"));
  const winnerRule = String(
    formData.get("winner_rule") ?? "ALL_PERSON_MEMBERSHIPS",
  );
  const exitRefundRule = String(
    formData.get("exit_refund_rule") ?? "AT_MATURITY",
  );

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
    redirect(
      "/dashboard/kuri/new?error=Please%20enter%20valid%20Kuri%20details.",
    );
  }

  const { data: kuriId, error } = await supabase.rpc("create_kuri_for_admin", {
    name,
    description: description || null,
    start_date: startDate,
    number_of_cycles: numberOfCycles,
    membership_limit: membershipLimit,
    installment_amount: installmentAmount,
    due_day: dueDay,
    draw_day: drawDay,
    gross_prize_amount: grossPrizeAmount,
    expense_amount: expenseAmount,
    frequency_value: "MONTHLY",
    schedule_mode_value: "STANDARD",
    winner_rule: winnerRule,
    exit_refund_rule: exitRefundRule,
  });

  if (error || !kuriId) {
    console.error("createKuri RPC failed:", error);
    redirect(
      `/dashboard/kuri/new?error=${encodeURIComponent(
        `Unable to create Kuri: ${error?.message ?? "Unknown error"}`,
      )}`,
    );
  }

  revalidatePath("/dashboard");
  revalidatePath("/dashboard/kuri");
  redirect(`/dashboard/kuri/${kuriId}`);
}
