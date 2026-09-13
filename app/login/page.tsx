import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function LoginPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (user) redirect("/");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-16 text-slate-900">
      <div className="mx-auto max-w-md rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
        <h1 className="text-2xl font-bold">Sign in</h1>
        <p className="mt-2 text-sm text-slate-600">Authentication is wired to Supabase. The full credential form will be added with the authenticated app shell.</p>
        <div className="mt-6 rounded-lg bg-slate-50 p-4 text-sm text-slate-600">Configure your Supabase project and environment variables first.</div>
        <a href="/" className="mt-6 inline-block text-sm font-medium text-slate-900 underline">Back to Kuri-App</a>
      </div>
    </main>
  );
}
