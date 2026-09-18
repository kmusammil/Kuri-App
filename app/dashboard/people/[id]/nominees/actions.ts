"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

async function client(){const s=await createClient();const{data:{user}}=await s.auth.getUser();if(!user)redirect("/login");return s;}
function personPath(personId:string){return "/dashboard/people/"+personId;}
export async function createNominee(formData:FormData){const s=await client();const personId=String(formData.get("person_id")||"").trim();const{error}=await s.rpc("create_nominee_for_admin",{target_person_id:personId,nominee_name:String(formData.get("name")||"").trim(),nominee_relationship:String(formData.get("relationship")||"").trim()||null,nominee_phone:String(formData.get("phone")||"").trim()||null,nominee_address:String(formData.get("address")||"").trim()||null,nominee_notes:String(formData.get("notes")||"").trim()||null});if(error)redirect(personPath(personId)+"/nominees/new?error="+encodeURIComponent(error.message));revalidatePath(personPath(personId));redirect(personPath(personId));}
