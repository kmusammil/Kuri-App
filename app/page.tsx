import Link from "next/link";

const checks = [
  "Next.js + TypeScript application shell",
  "Supabase client/server integration",
  "PostgreSQL foundation migration",
  "Authentication and role model",
  "Row-level security foundation",
];

export default function HomePage() {
  return (
    <main className="min-h-screen bg-slate-50 px-6 py-16 text-slate-900">
      <div className="mx-auto max-w-4xl">
        <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
        <h1 className="mt-4 text-4xl font-bold tracking-tight sm:text-5xl">Kuri management, built around the real workflow.</h1>
        <p className="mt-5 max-w-2xl text-lg text-slate-600">The application foundation is in place. The next layers will add real Kuri administration, member management, payments, draws, winners, payouts, and reporting.</p>

        <section className="mt-10 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Foundation status</h2>
          <ul className="mt-4 space-y-3">
            {checks.map((check) => (
              <li key={check} className="flex items-center gap-3 text-slate-700">
                <span className="inline-flex h-6 w-6 items-center justify-center rounded-full bg-emerald-100 text-sm text-emerald-700">✓</span>
                {check}
              </li>
            ))}
          </ul>
        </section>

        <div className="mt-8 flex flex-wrap gap-3">
          <Link href="/login" className="rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white hover:bg-slate-800">Open sign in</Link>
          <span className="rounded-lg border border-slate-200 bg-white px-4 py-2.5 text-sm text-slate-600">Browser test page</span>
        </div>
      </div>
    </main>
  );
}
