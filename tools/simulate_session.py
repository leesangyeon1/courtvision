#!/usr/bin/env python3
"""CourtVision acceptance simulator.

Plays a scripted 25-shot practice session against a real Supabase project
(auth -> player -> session -> events -> aggregate views) and verifies that
session_box_scores / session_zone_splits match locally recomputed values,
including idempotency of duplicate event re-sends.

Stdlib only. Exit 0 = PASS, 1 = FAIL, 2 = setup problem.
"""

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

# ---------------------------------------------------------------- geometry
# Half court: 50 ft wide x 47 ft deep, origin at left end of the baseline,
# rim center at (25, 5.25). Normalized: court_x = x/50, court_y = y/47.

RIM = (25.0, 5.25)


def is_three(x, y):
    if y <= 14 and (x <= 3 or x >= 47):
        return True
    return math.hypot(x - RIM[0], y - RIM[1]) >= 23.75


def classify(x, y, free_throw=False):
    if free_throw:
        return "ft_line"
    if is_three(x, y):
        if y <= 14:
            return "left_corner_3" if x < 25 else "right_corner_3"
        if abs(x - 25) <= 9:
            return "top_arc_3"
        return "left_wing_3" if x < 25 else "right_wing_3"
    if abs(x - 25) <= 8:
        return "paint" if y <= 19 else "top_key"
    return "mid_left" if x < 25 else "mid_right"


# ---------------------------------------------------------------- script
# 25 shots covering all 10 zones: (x_ft, y_ft, category, made, confidence).

SHOTS = [
    (25.0, 7.0, "layup", True, 0.95),
    (24.0, 6.5, "layup", False, 0.90),
    (26.0, 7.5, "dunk", True, 0.98),
    (23.0, 9.0, "floater", True, 0.85),
    (27.0, 10.0, "layup", True, 0.92),          # paint x5
    (12.0, 10.0, "mid_range", True, 0.80),
    (14.0, 12.0, "mid_range", False, 0.78),     # mid_left x2
    (38.0, 10.0, "mid_range", True, 0.82),
    (36.0, 12.0, "floater", False, 0.75),       # mid_right x2
    (25.0, 21.0, "mid_range", True, 0.88),
    (23.0, 22.0, "mid_range", False, 0.70),     # top_key x2
    (2.0, 8.0, "three", True, 0.91),
    (2.5, 10.0, "three", False, 0.86),          # left_corner_3 x2
    (48.0, 8.0, "three", True, 0.93),
    (47.5, 10.0, "three", False, 0.84),         # right_corner_3 x2
    (6.0, 24.0, "three", True, 0.87),
    (7.0, 22.0, "three", False, 0.76),          # left_wing_3 x2
    (44.0, 24.0, "three", False, 0.81),
    (43.0, 22.0, "three", True, 0.89),          # right_wing_3 x2
    (25.0, 30.0, "three", True, 0.94),
    (27.0, 29.0, "three", False, 0.72),         # top_arc_3 x2
    (25.0, 19.0, "free_throw", True, 0.97),
    (25.0, 19.0, "free_throw", True, 0.96),
    (25.0, 19.0, "free_throw", False, 0.95),
    (25.0, 19.0, "free_throw", True, 0.94),     # ft_line x4
]


def build_events(session_id, player_id):
    events = []
    for i, (x, y, category, made, conf) in enumerate(SHOTS):
        zone = classify(x, y, free_throw=(category == "free_throw"))
        events.append({
            "id": str(uuid.uuid4()),
            "session_id": session_id,
            "player_id": player_id,
            "ts": i * 15000,
            "confidence": conf,
            "made": made,
            "category": category,
            "zone": zone,
            "court_x": x / 50.0,
            "court_y": y / 47.0,
        })
    return events


def expected_metrics(events):
    fga = sum(1 for e in events if e["category"] != "free_throw")
    fgm = sum(1 for e in events if e["category"] != "free_throw" and e["made"])
    tpa = sum(1 for e in events if e["category"] == "three")
    tpm = sum(1 for e in events if e["category"] == "three" and e["made"])
    fta = sum(1 for e in events if e["category"] == "free_throw")
    ftm = sum(1 for e in events if e["category"] == "free_throw" and e["made"])
    pts = 2 * (fgm - tpm) + 3 * tpm + ftm
    box = {
        "fga": fga, "fgm": fgm, "three_pa": tpa, "three_pm": tpm,
        "fta": fta, "ftm": ftm, "pts": pts,
        "fg_pct": fgm / fga if fga else 0.0,
        "three_pct": tpm / tpa if tpa else 0.0,
        "ft_pct": ftm / fta if fta else 0.0,
        "efg_pct": (fgm + 0.5 * tpm) / fga if fga else 0.0,
        "ts_pct": pts / (2 * (fga + 0.44 * fta)) if fga or fta else 0.0,
    }
    zones = {}
    for e in events:
        z = zones.setdefault(e["zone"], {"made": 0, "attempted": 0})
        z["attempted"] += 1
        if e["made"]:
            z["made"] += 1
    return box, zones


# ---------------------------------------------------------------- HTTP


class Api:
    def __init__(self, url, key):
        self.url = url.rstrip("/")
        self.key = key
        self.token = None

    def request(self, method, path, body=None, prefer=None):
        headers = {"apikey": self.key, "Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if prefer:
            headers["Prefer"] = prefer
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.url + path, data=data,
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            sys.exit("HTTP %s on %s %s\n%s" % (e.code, method, path, detail))
        except urllib.error.URLError as e:
            sys.exit("Cannot reach %s: %s" % (self.url, e.reason))
        return json.loads(raw) if raw else None


def authenticate(api, email, password):
    if email:
        body = api.request("POST", "/auth/v1/token?grant_type=password",
                           {"email": email, "password": password})
        api.token = body["access_token"]
        return email
    email = "courtvision-sim-%s@example.com" % uuid.uuid4().hex[:8]
    password = "Sim-" + uuid.uuid4().hex[:16]
    body = api.request("POST", "/auth/v1/signup",
                       {"email": email, "password": password})
    if not body or "access_token" not in body:
        print("Signup succeeded but returned no access_token — the project "
              "requires email confirmation.\nFix: disable 'Confirm email' in "
              "Supabase Auth settings, or pass --email/--password of a "
              "confirmed user.")
        sys.exit(2)
    api.token = body["access_token"]
    return email


# ---------------------------------------------------------------- main


def main():
    p = argparse.ArgumentParser(description="CourtVision acceptance simulator")
    p.add_argument("--url", default=os.environ.get("SUPABASE_URL"))
    p.add_argument("--key", default=os.environ.get("SUPABASE_ANON_KEY"))
    p.add_argument("--email", help="existing confirmed account (optional)")
    p.add_argument("--password")
    p.add_argument("--delay", type=float, default=0.4,
                   help="seconds between event inserts (default 0.4)")
    args = p.parse_args()
    if not args.url or not args.key:
        print("Missing Supabase config. Set SUPABASE_URL and SUPABASE_ANON_KEY "
              "(or pass --url/--key). Find both in your Supabase project: "
              "Settings -> API.")
        sys.exit(2)
    if bool(args.email) != bool(args.password):
        p.error("--email and --password must be given together")

    t0 = time.time()
    api = Api(args.url, args.key)
    email = authenticate(api, args.email, args.password)
    print("Authenticated as", email)

    player = api.request("POST", "/rest/v1/players",
                         {"name": "Sim Shooter", "jersey_number": 23},
                         prefer="return=representation")[0]
    session = api.request("POST", "/rest/v1/sessions",
                          {"player_id": player["id"], "mode": "practice"},
                          prefer="return=representation")[0]
    print("Player %s  Session %s" % (player["id"], session["id"]))

    events = build_events(session["id"], player["id"])
    for i, e in enumerate(events):
        api.request("POST", "/rest/v1/events?on_conflict=id", e,
                    prefer="resolution=ignore-duplicates")
        print("shot %2d/25  %-14s %-10s %s" %
              (i + 1, e["zone"], e["category"],
               "MAKE" if e["made"] else "miss"))
        time.sleep(args.delay)

    # Re-send 3 events with the same uuids: must be ignored (idempotency).
    for e in events[:3]:
        api.request("POST", "/rest/v1/events?on_conflict=id", e,
                    prefer="resolution=ignore-duplicates")
    print("Re-sent 3 duplicate events (same ids)")

    api.request("PATCH", "/rest/v1/sessions?id=eq." + session["id"],
                {"status": "ended",
                 "ended_at": time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                           time.gmtime())})

    box_rows = api.request("GET", "/rest/v1/session_box_scores?session_id=eq."
                           + session["id"])
    zone_rows = api.request("GET", "/rest/v1/session_zone_splits?session_id=eq."
                            + session["id"])
    if not box_rows:
        sys.exit("session_box_scores returned no row for the session")

    exp_box, exp_zones = expected_metrics(events)
    got_box = box_rows[0]
    got_zones = {r["zone"]: r for r in zone_rows}

    ok = True
    rows = []
    for metric, exp in exp_box.items():
        got = got_box.get(metric)
        match = got is not None and abs(float(got) - float(exp)) <= 1e-6
        ok &= match
        rows.append((metric, exp, got, match))
    for zone, exp in sorted(exp_zones.items()):
        got = got_zones.get(zone)
        for field in ("made", "attempted"):
            g = got[field] if got else None
            match = g == exp[field]
            ok &= match
            rows.append(("%s.%s" % (zone, field), exp[field], g, match))
    extra = set(got_zones) - set(exp_zones)
    if extra:
        ok = False
        rows.append(("unexpected zones", "-", sorted(extra), False))

    print("\n%-24s %-12s %-12s %s" % ("metric", "expected", "got", "result"))
    print("-" * 60)
    for metric, exp, got, match in rows:
        print("%-24s %-12s %-12s %s" %
              (metric, round(exp, 6) if isinstance(exp, float) else exp,
               round(float(got), 6) if isinstance(got, float) else got,
               "PASS" if match else "FAIL"))

    print("\n%s in %.1fs  (session %s)" %
          ("PASS" if ok else "FAIL", time.time() - t0, session["id"]))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
