# CourtVision tools

`simulate_session.py` — acceptance simulator ("fake shooter"). Stdlib-only Python 3.
Plays a scripted 25-shot practice session against a real Supabase project and
verifies the aggregate views match locally recomputed expectations.

Usage:

    export SUPABASE_URL=https://<ref>.supabase.co
    export SUPABASE_ANON_KEY=<anon key>          # Settings -> API
    python3 tools/simulate_session.py            # signs up a throwaway user
    python3 tools/simulate_session.py --email you@x.com --password ...  # reuse account
    # --delay 0.4 (seconds between inserts), --url/--key override env

PASS proves: event inserts are idempotent (3 duplicate re-sends change nothing),
session_box_scores / session_zone_splits math is correct (FG/3P/FT/PTS/eFG/TS and
all 10 zone counts), and the live rows the dashboard will show exist in Supabase.

`eval_model.py MODEL DATA [--imgsz N]` — per-class P/R/AP table +
confusion matrix for a checkpoint against the fixed val set (the gate
before any model swap; see docs/MODEL_PIPELINE.md §4). Needs the repo
`.venv` (ultralytics).
