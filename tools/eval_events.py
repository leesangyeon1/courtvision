#!/usr/bin/env python3
"""Shot-event eval — the P1 gate (docs/EVAL.md).

Compares app-emitted shot events against a hand-labeled ground truth:
attempt precision/recall (±tolerance s), make/miss accuracy on matched
attempts, and location error in feet (median, p90) where both sides have a
court point. Stdlib only.

Ground truth CSV (attempt_s = seconds from clip/session start; x/y in feet on
the standard half court, rim at (25, 5.25)):

    attempt_s,made,x_ft,y_ft
    2.4,1,25,19

Events come from either
  * a replay export (EngineReplayTests → <clip>.events.json), or
  * Supabase (`--session ID`, env SUPABASE_URL / SUPABASE_ANON_KEY as in
    simulate_session.py; `ts` is ms since the session's first tick).

Usage:
    python3 tools/eval_events.py clip.gt.csv clip.events.json
    python3 tools/eval_events.py game.gt.csv --session <uuid> --email you@x.com --password ...
    ... --append docs/EVAL.md --clip freethrow --commit $(git rev-parse --short HEAD)
"""
import argparse
import csv
import json
import os
import statistics
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from simulate_session import Api, authenticate  # noqa: E402  (stdlib REST helper)

COURT_W, COURT_H = 50.0, 47.0


def load_gt(path):
    with open(path, newline="") as f:
        return [{"t": float(r["attempt_s"]), "made": r["made"].strip() in ("1", "true", "True"),
                 "x": float(r["x_ft"]), "y": float(r["y_ft"])} for r in csv.DictReader(f)]


def load_replay_events(path):
    """[ShotEvent] JSON from EngineReplayTests: resolutions only (kind != attempt)."""
    with open(path) as f:
        raw = json.load(f)
    out = []
    for e in raw:
        if e.get("kind") == "attempt":
            continue
        court = e.get("court")
        out.append({"t": float(e["pts"]), "made": e["kind"] == "made",
                    "x": float(court[0]) if court else None,
                    "y": float(court[1]) if court else None})
    return out


def load_session_events(api, session_id):
    rows = api.request("GET", "/rest/v1/events?session_id=eq.%s&type=eq.shot"
                              "&select=ts,made,court_x,court_y&order=ts" % session_id)
    return [{"t": r["ts"] / 1000.0, "made": bool(r["made"]),
             "x": r["court_x"] * COURT_W, "y": r["court_y"] * COURT_H} for r in rows]


def match(gt, events, tolerance):
    """Greedy nearest-in-time matching, each event used at most once."""
    events = sorted(events, key=lambda e: e["t"])
    used = set()
    tp = []
    for g in sorted(gt, key=lambda g: g["t"]):
        best, best_dt = None, None
        for i, e in enumerate(events):
            if i in used:
                continue
            dt = abs(e["t"] - g["t"])
            if dt <= tolerance and (best_dt is None or dt < best_dt):
                best, best_dt = i, dt
        if best is not None:
            used.add(best)
            tp.append((g, events[best]))
    fp = len(events) - len(used)
    fn = len(gt) - len(tp)
    errs = [((g["x"] - e["x"]) ** 2 + (g["y"] - e["y"]) ** 2) ** 0.5
            for g, e in tp if e["x"] is not None and e["y"] is not None]
    n = len(tp)
    return {
        "tp": n, "fp": fp, "fn": fn,
        "precision": n / (n + fp) if n + fp else 0.0,
        "recall": n / (n + fn) if n + fn else 0.0,
        "outcome_acc": sum(1 for g, e in tp if g["made"] == e["made"]) / n if n else 0.0,
        "loc_n": len(errs),
        "loc_median_ft": statistics.median(errs) if errs else None,
        "loc_p90_ft": sorted(errs)[max(0, int(round(0.9 * (len(errs) - 1))))] if errs else None,
    }


def fmt(v):
    return "—" if v is None else ("%.2f" % v)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("gt", help="ground-truth CSV")
    p.add_argument("events", nargs="?", help="<clip>.events.json from EngineReplayTests")
    p.add_argument("--session", help="Supabase session id (instead of an events file)")
    p.add_argument("--email"); p.add_argument("--password")
    p.add_argument("--url", default=os.environ.get("SUPABASE_URL"))
    p.add_argument("--key", default=os.environ.get("SUPABASE_ANON_KEY"))
    p.add_argument("--tolerance", type=float, default=1.5, help="attempt match window, seconds")
    p.add_argument("--append", help="markdown file to append a result row to (docs/EVAL.md)")
    p.add_argument("--clip", default="", help="label for the appended row")
    p.add_argument("--commit", default="", help="commit sha for the appended row")
    a = p.parse_args()

    gt = load_gt(a.gt)
    if a.session:
        if not (a.url and a.key):
            sys.exit("--session needs SUPABASE_URL and SUPABASE_ANON_KEY (env or --url/--key)")
        api = Api(a.url, a.key)
        authenticate(api, a.email, a.password)
        events = load_session_events(api, a.session)
    elif a.events:
        events = load_replay_events(a.events)
    else:
        sys.exit("give an events JSON or --session")

    r = match(gt, events, a.tolerance)
    print("attempts GT %d | app %d | TP %d FP %d FN %d" % (len(gt), len(events), r["tp"], r["fp"], r["fn"]))
    print("precision %.2f  recall %.2f  make/miss acc %.2f (n=%d)"
          % (r["precision"], r["recall"], r["outcome_acc"], r["tp"]))
    print("location error ft: median %s  p90 %s (n=%d)" % (fmt(r["loc_median_ft"]), fmt(r["loc_p90_ft"]), r["loc_n"]))
    if a.append:
        row = "| %s | %s | %s | %d | %.2f | %.2f | %.2f | %s | %s |\n" % (
            date.today().isoformat(), a.commit, a.clip or (a.session or a.events), len(gt),
            r["precision"], r["recall"], r["outcome_acc"], fmt(r["loc_median_ft"]), fmt(r["loc_p90_ft"]))
        with open(a.append, "a") as f:
            f.write(row)
        print("appended to", a.append)


if __name__ == "__main__":
    main()
