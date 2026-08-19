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
Correction (commit "letterbox the unified model"): that 0.27 s attempt was a
`player-jump-shot` false positive on a *different* player's legs under
`.scaleFill`; under `.scaleFit` the shooter is labeled possession →
shot-block and no attempt opens. The fixture row above is therefore a false
positive matched by luck, not a detection — the P1 numbers must come from
jump-shot clips.
The P1 baseline paragraph (≥ 5 field clips) goes below this line.

## Detector input scaling (fixture clip, 45 ticks @ 6 Hz, unified model)

| option | player-family boxes ≥0.10 | in 0.7–1.0 conf | dedupe drops | core/tick | ball ticks ≥0.25 | unified rim ticks | HoopDetector rim ticks |
|---|---|---|---|---|---|---|---|
| `.scaleFill` (stretch) | 393 | 95 | 133 | 5.4 | 12 | 44 | 45 |
| `.scaleFit` (letterbox) | 282 | 143 | 67 | 4.5 | 30 | 3 | 44 |

At t = 1 s `.scaleFill` had no box at any confidence on the two largest
people (near #26, the shooter); `.scaleFit` finds both. Decision: unified →
`.scaleFit`; HoopDetector stays `.scaleFill` (its rim recall is unchanged
and it is the primary rim source). Commit: see git log for
"letterbox the unified model".

## Gym clip (IMG_1673.mov, 720p, 60 s, own footage) — tracking

| build | players/tick median | far segment 20–30 s | distinct ids / 60 s | ids ≥ 5 s | #3 / #8 ticks | ref ticks |
|---|---|---|---|---|---|---|
| v1 (`7abeff3`: scaleFit, ghost fix, containment) | 7 | 4.7 | 240 | 27 | 228 / 121 | 113 |
| v2 (far-band lane, reach + resurrect tracker, draw grace, containment keeps people-behind) | 11 | 10.4 | 51 | 29 | 509 / 498 | 232 |

Levers measured on the way: confidence floor 0.30 → 0.15 adds 0.2 boxes/tick
(not the lever); far-band second pass adds 2.1 people/tick; containment rule
removed 91 true fragments and 12 real people (fixed: narrow/offset contained
boxes stay). Remaining false boxes: floor-light reflections and a ceiling
light (small, stationary) — hard negatives for the retrain, not tracker work.
No court fix in 60 s (rectangles) — the keypoint court model (P2) is the fix.
`tickHz` is now really 6 in `Engine.Config` (the earlier commit missed the
code; docs said 6, code said 8).
