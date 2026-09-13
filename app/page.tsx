export default function Home() {
  return (
    <main className="min-h-screen p-8">
      <div className="mx-auto max-w-5xl">
        <p className="text-sm font-medium text-gray-500">Kuri-App</p>
        <h1 className="mt-2 text-4xl font-semibold tracking-tight">Foundation ready</h1>
        <p className="mt-4 max-w-2xl text-gray-600">
          The initial Next.js application foundation is in place. Kuri management,
          members, payments, draws, winners, payouts, and settlements will be built
          on top of the architecture documented in <code>docs/TECHNICAL_BLUEPRINT.md</code>.
        </p>
      </div>
    </main>
  )
}
