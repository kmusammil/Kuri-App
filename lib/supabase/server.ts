import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/**
 * Creates the Supabase client for Server Components, Route Handlers,
 * and other server-side Next.js code.
 *
 * Cookie reads are always available. Cookie writes may be rejected by a
 * Server Component; in that case the caller should rely on the request/session
 * refresh layer when it is added to the application shell.
 */
export async function createClient() {
  const cookieStore = await cookies();
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!url || !key) {
    throw new Error(
      "Missing Supabase environment variables. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY."
    );
  }

  return createServerClient(url, key, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Server Components may not be allowed to mutate response cookies.
          // Session refresh handling will own cookie writes at the boundary.
        }
      },
    },
  });
}
