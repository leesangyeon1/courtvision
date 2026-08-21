#!/usr/bin/env python3
"""Offline path cleanup — ref 02's `clean_paths`, ported.

Takes a replay's moments.json (per-tick player court positions), removes
teleport-like jumps (speed outliers vs median + k·MAD, padded), fills the
gaps by linear interpolation, and smooths with Savitzky-Golay. Emits
cleaned per-track paths + distance/speed stats. Post-session only — the
cleanup needs the whole trajectory (ref 02's own caveat).

Usage:
    .venv/bin/python tools/clean_paths.py clip.moments.json [-o clip.paths.json]

Needs the repo .venv (numpy/scipy via ultralytics).
"""
import argparse
import json

import numpy as np
from scipy.signal import savgol_filter


def clean_path(xy, k=3.0, min_jump_ft=6.0, pad=2, window=7):
    """xy: (N,2) court-feet samples at a fixed tick rate; NaN rows = unseen.

    Returns (cleaned (N,2) with NaN only where nothing surrounds the gap,
    outlier_mask). Speeds are per-tick distances; a step > median + k·MAD and
    > min_jump_ft flags a run, padded by `pad` samples each side, then the
    run is rebuilt by linear interpolation and the path smoothed.
    """
    xy = np.asarray(xy, dtype=float)
    n = len(xy)
    if n < 3:
        return xy, np.zeros(n, bool)
    step = np.linalg.norm(np.diff(xy, axis=0), axis=1)
    ok = ~np.isnan(step)
    if ok.sum() >= 3:
        med = np.median(step[ok])
        mad = np.median(np.abs(step[ok] - med)) or 1e-9
        bad = np.zeros(n, bool)
        hits = np.where(ok & (step > med + k * mad) & (step > min_jump_ft))[0]
        for i in hits:                                    # pad around each jump
            bad[max(0, i - pad):min(n, i + 2 + pad)] = True
    else:
        bad = np.zeros(n, bool)
    out = xy.copy()
    out[bad] = np.nan
    for c in range(2):                                    # interpolate gaps
        col = out[:, c]
        good = ~np.isnan(col)
        if good.sum() >= 2:
            out[:, c] = np.interp(np.arange(n), np.flatnonzero(good), col[good])
    good = ~np.isnan(out).any(axis=1)
    if good.sum() > window:
        w = window if window % 2 else window + 1
        out[good] = savgol_filter(out[good], min(w, good.sum() // 2 * 2 + 1), 2, axis=0)
    return out, bad


def paths_from_moments(moments):
    """{trackId: [(pts, x_ft, y_ft) …]} — only samples with a court fix."""
    paths = {}
    for m in moments:
        for p in m["players"]:
            if p.get("xFt") is not None and p.get("yFt") is not None:
                paths.setdefault(p["trackId"], []).append((m["pts"], p["xFt"], p["yFt"]))
    return paths


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("moments", help="moments.json from a replay/export")
    ap.add_argument("-o", "--out", help="output path (default: <moments>.paths.json)")
    a = ap.parse_args()
    moments = json.load(open(a.moments))
    out = {}
    for tid, samples in sorted(paths_from_moments(moments).items()):
        ts = [s[0] for s in samples]
        xy, bad = clean_path([(s[1], s[2]) for s in samples])
        good = ~np.isnan(xy).any(axis=1)
        dist = float(np.linalg.norm(np.diff(xy[good], axis=0), axis=1).sum()) if good.sum() > 1 else 0.0
        dur = ts[-1] - ts[0] if len(ts) > 1 else 0.0
        out[str(tid)] = {
            "t": ts,
            "xy": [[None, None] if np.isnan(x) else [round(x, 2), round(y, 2)] for x, y in xy],
            "outliers": int(bad.sum()),
            "distance_ft": round(dist, 1),
            "avg_speed_fps": round(dist / dur, 2) if dur > 0 else 0.0,
        }
    target = a.out or a.moments.replace(".moments.json", "").replace(".json", "") + ".paths.json"
    json.dump(out, open(target, "w"))
    print("tracks %d -> %s" % (len(out), target))
    for tid, p in list(out.items())[:8]:
        print("  t%s: %d samples, %d outliers, %.0f ft @ %.1f ft/s"
              % (tid, len(p["t"]), p["outliers"], p["distance_ft"], p["avg_speed_fps"]))


if __name__ == "__main__":
    main()
