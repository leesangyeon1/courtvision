# EVAL — measured numbers, per engine / model version

Every gate in `docs/superpowers/specs/2026-08-17-tracking-engine-design.md`
lands here. No number, no merge.

## Engine tick cost (P0)

Device / build → run a 10-minute practice session at each rate; read the
`NN ms` in the record status line every ~30 s and note the median; note the
thermal state at 10 min (Settings → Battery shows throttling; the status
tick rate halves under serious/critical).

| date | device | commit | tickHz | slowEvery | ms/tick (median) | thermal @10 min | notes |
|---|---|---|---|---|---|---|---|
| YYYY-MM-DD | iPhone … | … | 5 | 5 | | | |
| 2026-08-18 | iPhone 15 Plus (iPhone (5)) | fae8a8a | 8 | 8 | ~159 (125–217 across 6 status readings, field session, incl. pose) | not recorded | rate self-throttles to ~6 Hz; 8 not sustainable |
| YYYY-MM-DD | iPhone … | … | 10 | 10 | | | |

Chosen default: `Engine.Config.tickHz = 8` (provisional — the pre-engine ball
loop ran at 8 Hz; replace with the highest rate whose ms/tick stays under
1000/tickHz with headroom and no serious thermal state at 10 min).

## Shot events (P1)

Filled by `tools/eval_events.py --append docs/EVAL.md`.

| date | commit | clip | attempts GT | P | R | make/miss acc | loc median ft | loc p90 ft |
|---|---|---|---|---|---|---|---|---|
| 2026-08-17 | 102d842 | freethrow | 1 | 1.00 | 1.00 | 0.00 | — | — |

Observations, fixture clip (commit 102d842, simulator replay, tickHz 8):
the attempt opened at 0.27 s — the shooter's set position already read as
`player-jump-shot`, 1.4 s before the release (inside the ±1.5 s match window,
barely); the make was scored *missed* — no `ball-in-basket` observation near
the rim within the 3 s window (rim sits at the frame edge, ball passes
through the net at ~2.9 s); no court fix from rectangle detection on that
scene, so no location. Three concrete P1/P2 targets: shooting-state onset vs
release, ball-in-basket recall at partial rims, and the keypoint court model.
The P1 baseline paragraph (≥ 5 field clips) goes below this line.
