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

`eval_events.py GT.csv EVENTS.json` / `eval_events.py GT.csv --session ID …` —
attempt precision/recall (±1.5 s), make/miss accuracy, location error (ft)
against a hand-labeled CSV. Events come from `EngineReplayTests`
(`TEST_RUNNER_COURTVISION_REPLAY_CLIP=/abs/clip.mp4 xcodebuild … test
-only-testing:CourtVisionTests/EngineReplayTests/testReplayClipFromEnvironment`
writes `clip.events.json`) or from Supabase. `--append docs/EVAL.md` records
the row. Stdlib only. Tests: `python3 -m unittest tools/test_eval_events.py`.

`render_moments.py CLIP MOMENTS.json OUT.mp4` — draws the replay's Moments
(teams, numbers, rims, ball, refs) onto the clip. `EngineReplayTests`'
env-var replay writes `CLIP.moments.json` next to the clip. Needs `.venv`.

`clean_paths.py MOMENTS.json [-o OUT]` — ref 02's path cleanup: speed-outlier
removal (median+MAD, padded), linear interpolation, Savitzky-Golay smooth;
per-track distance/avg speed. Post-session only. Needs `.venv`.
Tests: `.venv/bin/python -m unittest tools/test_clean_paths.py`.
