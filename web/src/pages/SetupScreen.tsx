/** Rendered when VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are missing. */
export default function SetupScreen() {
  return (
    <div className="center-screen">
      <div className="auth-card">
        <div className="card">
          <h2 style={{ fontSize: 22 }}>
            Court<span className="logo-accent">Vision</span> setup
          </h2>
          <p className="card-sub">Supabase environment is not configured.</p>
          <ol className="setup-steps" style={{ paddingLeft: 18 }}>
            <li>Create a project at supabase.com.</li>
            <li>
              Apply <code>supabase/migrations/0001_init.sql</code> (SQL editor or{' '}
              <code>supabase db push</code>).
            </li>
            <li>
              Create <code>web/.env.local</code> with
              <br />
              <code>VITE_SUPABASE_URL=…</code>
              <br />
              <code>VITE_SUPABASE_ANON_KEY=…</code>
            </li>
            <li>
              Restart <code>npm run dev</code> — or set the same env vars in Vercel and
              redeploy.
            </li>
          </ol>
        </div>
      </div>
    </div>
  )
}
