# CourtVision

Basketball shooting analytics in the class of HomeCourt / Ball AI / SwingVision /
Rapsodo MLM: the phone does all the computer vision **on-device**, Supabase is
the entire backend, and a web dashboard on Vercel shows shooting analytics live.

**V1 scope (this repo): shooting metrics only** — make/miss, shot category,
court location (homography → heatmap), and shooting splits (FG% / 3P% / FT% /
eFG% / TS%), live on the dashboard within 10 seconds.

```
iOS app (on-device CV) ──insert──▶ Supabase (Postgres + Auth + Realtime)
                                        │
                          Realtime push / 10 s poll of SQL views
                                        ▼
                          React dashboard (Vercel)
```

No servers to run: aggregates are Postgres **views**, live updates are Supabase
**Realtime**, auth is Supabase **Auth**. RLS scopes every row to its owner.

## Layout

| Path | What |
|---|---|
| `supabase/migrations/0001_init.sql` | **The contract.** Tables, RLS, aggregate views, realtime. |
| `web/` | React 18 + Vite + TanStack Query dashboard (Realtime push + 10 s poll). |
| `ios/` | SwiftUI capture app: Vision trajectory + pose, rim detection, homography. |
| `tools/simulate_session.py` | Replays a scripted session against your Supabase project. |

## Setup (once)

1. Create a project at [supabase.com](https://supabase.com) → SQL editor →
   paste `supabase/migrations/0001_init.sql` → run.
   (Or `supabase link && supabase db push` with the CLI.)
2. `web/.env.local`:
   ```
   VITE_SUPABASE_URL=https://<ref>.supabase.co
   VITE_SUPABASE_ANON_KEY=<anon key>
   ```
3. iOS: set the same URL + anon key in `ios/CourtVision/Config.swift`.

## Run

```sh
cd web && npm i && npm run dev     # dashboard on :5173
cd web && vercel --prod            # deploy (set the two env vars in Vercel too)
python3 tools/simulate_session.py  # fake shooter: proves the live pipeline
```

## The 10-second contract

Every shot the app detects must appear on the dashboard within 10 s: Supabase
Realtime is the fast path (<1 s), a 10 s poll of the `session_box_scores` view
is the guaranteed fallback. No hardcoded data anywhere — if Supabase is
unreachable, the dashboard shows *reconnecting*, not fakes.
