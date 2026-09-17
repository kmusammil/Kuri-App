"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function createMembership(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const kuriId = String(formData.get("kuri_id") ?? "").trim();
  const personId = String(formData.get("person_id") ?? "").trim();
  const membershipNumber = String(formData.get("membership_number") ?? "").trim();

  if (!kuriId || !personId || !membershipNumber) {
    redirect(
      `/dashboard/kuri/${kuriId}/memberships/new?error=Please%20select%20a%20person%20and%20enter%20a%20membership%20number.`,
    );
  }

  const { data: membershipId, error } = await supabase.rpc(
    "create_membership_for_admin",
    {
      target_kuri_id: kuriId,
      target_person_id: personId,
      membership_number: membershipNumber,
    },
  );

  if (error || !membershipId) {
    console.error("createMembership RPC failed:", error);
    redirect(
      `/dashboard/kuri/${kuriId}/memberships/new?error=${encodeURIComponent(
        `Unable to create membership: ${error?.message ?? "Unknown error"}`,
      )}`,
    );
  }

  revalidatePath(`/dashboard/kuri/${kuriId}`);
  revalidatePath(`/dashboard/people/${personId}`);
  redirect(`/dashboard/kuri/${kuriId}`);
}
