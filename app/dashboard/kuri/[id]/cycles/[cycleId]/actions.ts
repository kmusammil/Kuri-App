"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function cyclePath(kuriId: string, cycleId: string) {
  return "/dashboard/kuri/" + kuriId + "/cycles/" + cycleId;
}

async function getSessionOrLogin() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  return supabase;
}

export async function prepareDraw(formData: FormData) {
  const supabase = await getSessionOrLogin();
  const cycleId = String(formData.get("cycle_id") || "").trim();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  if (!cycleId || !kuriId) redirect("/dashboard/kuri");

  const { error } = await supabase.rpc("prepare_draw_for_admin", { target_cycle_id: cycleId });
  if (error) redirect(cyclePath(kuriId, cycleId) + "?error=" + encodeURIComponent(error.message));

  revalidatePath(cyclePath(kuriId, cycleId));
  redirect(cyclePath(kuriId, cycleId));
}

export async function setPoolEntry(formData: FormData) {
  const supabase = await getSessionOrLogin();
  const entryId = String(formData.get("entry_id") || "").trim();
  const cycleId = String(formData.get("cycle_id") || "").trim();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const include = String(formData.get("include") || "") === "true";

  if (!entryId || !cycleId || !kuriId) redirect("/dashboard/kuri");

  const { error } = await supabase.rpc("set_draw_pool_entry_for_admin", {
    target_entry_id: entryId,
    include_in_draw: include,
    reason_text: null,
  });
  if (error) redirect(cyclePath(kuriId, cycleId) + "?error=" + encodeURIComponent(error.message));

  revalidatePath(cyclePath(kuriId, cycleId));
  redirect(cyclePath(kuriId, cycleId));
}

export async function finalizeDraw(formData: FormData) {
  const supabase=await getSessionOrLogin();
  const cycleId=String(formData.get("cycle_id")||"").trim();
  const kuriId=String(formData.get("kuri_id")||"").trim();
  const membershipIds=String(formData.get("membership_ids")||"").split(",").map(s=>s.trim()).filter(Boolean);
  if(!cycleId||!kuriId) redirect("/dashboard/kuri");
  const {error}=await supabase.rpc("finalize_draw_for_admin",{target_cycle_id:cycleId,final_membership_ids:membershipIds});
  if(error) redirect(cyclePath(kuriId,cycleId)+"?error="+encodeURIComponent(error.message));
  revalidatePath(cyclePath(kuriId,cycleId));
  redirect(cyclePath(kuriId,cycleId));
}

export async function runRandomDraw(formData: FormData) {
  const supabase = await getSessionOrLogin();
  const cycleId = String(formData.get("cycle_id") || "").trim();
  const kuriId = String(formData.get("kuri_id") || "").trim();
  const selectionCount = Number(formData.get("selection_count") || 1);

  if (!cycleId || !kuriId || !Number.isInteger(selectionCount) || selectionCount < 1) {
    redirect(cycleId && kuriId ? cyclePath(kuriId, cycleId) : "/dashboard/kuri");
  }

  const { error } = await supabase.rpc("run_random_draw_for_admin", {
    target_cycle_id: cycleId,
    selection_count: selectionCount,
  });
  if (error) redirect(cyclePath(kuriId, cycleId) + "?error=" + encodeURIComponent(error.message));

  revalidatePath(cyclePath(kuriId, cycleId));
  redirect(cyclePath(kuriId, cycleId));
}
