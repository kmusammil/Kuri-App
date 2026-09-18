"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function cyclePath(cycleId: string, kuriId?: string) {
  return kuriId ? "/dashboard/kuri/" + kuriId + "/cycles/" + cycleId : "/dashboard/kuri";
}

export async function prepareDraw(formData: FormData) {
  const supabase=await createClient();
  const {data:{user}}=await supabase.auth.getUser();
  if(!user) redirect("/login");
  const cycleId=String(formData.get("cycle_id")||"").trim();
  if(!cycleId) redirect("/dashboard/kuri/"+cycleId+"/cycles/"+cycleId);
  const {error}=await supabase.rpc("prepare_draw_for_admin",{target_cycle_id:cycleId});
  if(error) redirect("/dashboard/kuri?error="+encodeURIComponent(error.message));
  revalidatePath("/dashboard/kuri");
  redirect("/dashboard/kuri/"+cycleId+"/cycles/"+cycleId);
}

export async function setPoolEntry(formData: FormData) {
  const supabase=await createClient();
  const {data:{user}}=await supabase.auth.getUser();
  if(!user) redirect("/login");
  const entryId=String(formData.get("entry_id")||"").trim();
  const cycleId=String(formData.get("cycle_id")||"").trim();
  const include=String(formData.get("include")||"") === "true";
  if(!entryId || !cycleId) redirect("/dashboard/kuri");
  const {error}=await supabase.rpc("set_draw_pool_entry_for_admin",{target_entry_id:entryId,include_in_draw:include});
  if(error) redirect("/dashboard/kuri?error="+encodeURIComponent(error.message));
  revalidatePath("/dashboard/kuri/"+cycleId);
  redirect("/dashboard/kuri/"+cycleId+"/cycles/"+cycleId);
}

export async function runRandomDraw(formData: FormData) {
  const supabase=await createClient();
  const {data:{user}}=await supabase.auth.getUser();
  if(!user) redirect("/login");
  const cycleId=String(formData.get("cycle_id")||"").trim();
  const selectionCount=Number(formData.get("selection_count")||1);
  if(!cycleId || !Number.isInteger(selectionCount) || selectionCount<1) redirect("/dashboard/kuri");
  const {error}=await supabase.rpc("run_random_draw_for_admin",{target_cycle_id:cycleId,selection_count:selectionCount});
  if(error) redirect("/dashboard/kuri?error="+encodeURIComponent(error.message));
  revalidatePath("/dashboard/kuri/"+cycleId);
  redirect("/dashboard/kuri/"+cycleId+"/cycles/"+cycleId);
}