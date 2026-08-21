# Fixed Camera, Full Court — Design

Date: 2026-08-21
Status: in progress — items 1, 3, 4, 5, 6, 7, 9 landed on `fullcourt`; 2 (fixture) and 8 (keypoint model, license open) pending
Branch base: `dev`
Builds on `2026-08-17-tracking-engine-design.md` and `docs/MODEL_PIPELINE.md`.

Reference under study: Roboflow `basketball-ai-how-to-detect-track-and-identify-basketball-players.ipynb`
(ref 02). Measured on the notebook's own saved outputs, not from its prose.

## Decision

**The camera is fixed on a tripod and frames the full 94 ft court for the
whole session.** The operator does not pan, zoom, or hold the phone.

This is a product decision before it is a technical one. It is the same
constraint HomeCourt enforces through its setup flow, and it is the single
largest accuracy lever available — larger than any model swap in this
document.

## What ref 02 actually is (measured)

The notebook's saved `nvidia-smi` output and tqdm widget state give hard
numbers that change what is worth porting:

| fact | value | source |
|---|---|---|
| GPU actually used | **A100-SXM4-80GB** (not the T4/L4 its markdown suggests) | cell 5 output, run 2025-11-26 |
| Heavy pass throughput | **2.22 it/s**, 238 frames in 01:50 | tqdm widget state |
| Clip length | 7.9 s (238 frames @ 30 fps) | filename `q1-04.28-04.20` |
| **Realtime factor** | **13.9× slower than realtime, on an A100** | derived |
| Jersey OCR frame | 1.43 s/it | cell 65 |

Consequences:

1. Ref 02 is a **multi-pass offline pipeline with lookahead**. It re-reads the
   whole clip per stage and holds every frame in RAM (`frames_history`,
   `detections_history`, cell 71) before rendering. It is not a realtime
   system and cannot be made into one by moving it to better hardware.
2. A server offload path with a 1–3 min latency budget **cannot run this
   stack**. At 13.9× realtime, latency grows without bound: a 30-minute
   recording finishes ~6.5 hours late. Keeping up would need ~14 A100s in
   parallel.
3. The bottleneck is **SAM2.1 hiera-large** (224 M params, ~450 ms/frame here).
   Replacing it with `sv.ByteTrack` removes essentially all of it.

Our unified model already shares ref 02's class list exactly:

```
{0:ball, 1:ball-in-basket, 2:number, 3:player, 4:player-in-possession,
 5:player-jump-shot, 6:player-layup-dunk, 7:player-shot-block, 8:referee, 9:rim}
```

Same dataset family, same event design (detect the action class, do not compute
trajectories). `ShotEventTracker.swift` is already a faithful port of
`sports.basketball.ShotEventTracker`.

## Ref 02 component triage

| component | ref 02 | verdict | rationale |
|---|---|---|---|
| Court keypoint model `basketball-court-detection-2/14` | keypoints → homography | **ADOPT** | ~6–12 MB, CoreML/ANE, 1 Hz slow lane. Directly addresses 0 court fixes / 60 s |
| IoS number↔player matching (`sv.OverlapMetric.IOS`, thr 0.9) | vs SAM2 masks | **ADOPT (adapted)** | Use box IoS. `PlayerFinder.containment()` already exists at line 86 |
| `clean_paths` (speed-outlier removal + Savitzky–Golay) | numpy, post-hoc | **ADOPT (offline)** | Pure numpy, no GPU. Belongs in `tools/`, runs after the session |
| `ConsecutiveValueTracker(n=3)` number validation | consecutive agreement | **ALREADY BETTER** | Our per-track majority vote persists for the track's life |
| RF-DETR detector | Roboflow hosted, CUDA | **REJECT** | Identical classes to our YOLOv8s@960. Deformable attention falls off ANE |
| SigLIP → UMAP-3D → KMeans teams | `google/siglip-base-patch16-224`, ~200 M | **REJECT** | UMAP has no on-device implementation at all. Our chest-color 2-means is the phone-shaped equivalent |
| SmolVLM2 jersey OCR | 256 M–2.2 B VLM | **REJECT** | Autoregressive generation per crop vs ~2 ms Vision OCR |
| SAM2.1 hiera-large tracking | 224 M, prompt-once | **REJECT (architecturally)** | See below |

### Why SAM2 is rejected on design grounds, not just cost

```python
predictor.add_new_prompt(frame_idx=0, obj_id=..., bbox=bbox)   # frame 0 only
tracker_ids, mask_logits = predictor.track(frame)              # propagate after
```

SAM2 is prompted once and propagates. **A player who enters frame at t = 10 s is
never tracked.** Ref 02's clips are 8 seconds partly for this reason. Over a
60-minute session with substitutions and rebound scrums, correctness requires
periodic re-prompting — which converges back to detect-every-frame-and-associate,
i.e. what `PlayerTracker` already does.

Our tracker is not a cheap compromise for SAM2. It is the correct shape for live.

## What the fixed camera changes

| module | today (panning camera) | fixed camera |
|---|---|---|
| `CourtEstimator` | re-estimate every tick; rectangle candidates scored by rim consistency; **0 fixes in 60 s on the gym clip** | solve once at calibration, then drift-check only |
| `RimTracker` | two ends, pan-driven reacquisition, far-court-jump + 5 s cooldown end flip | both rims tapped at setup and permanently visible; no flip logic |
| attacking team | inferred from camera swing | derived from ball / possession position |
| `Engine.Config.farBand` | guessed constant `CGRect(0.15, 0.10, 0.70, 0.50)` | **computed** from the court quad via `Homography` |
| player track churn | 51 distinct ids / 60 s at 11 players/tick median | frame exits become substitutions only |
| ball trail | contaminated by camera motion | pure ball motion |
| motion sensing | none | CoreMotion gyro = tripod-bump detector |

`ZoneMapper.fullCourtLengthFt = 94.0`, `CourtEstimator.fullCourt`, and
`Calibration {homography, imagePoints, courtPoints}` already exist. The
infrastructure for full court is in place.

## The one thing that gets harder: pixels per player

A fixed full-court frame means the camera never gets closer. From EVAL.md:

> far court sits in the upper-middle of the frame; a player is **~20 px** after
> the 960 letterbox
>
> far segment 20–30 s: v1 = 4.7 players → v2 = 10.4 players (far-band pass)

And from MODEL_PIPELINE.md §4:

> Small-object physics — a blurred distant ball has no information for a deeper
> net to recover; **resolution and frame rate help, depth doesn't.**

So the fixed camera trades geometric stability for resolution. Both must be
solved, or one failure mode is simply exchanged for another.

### Camera placement (zero code, largest effect)

| placement | farthest player | verdict |
|---|---|---|
| behind baseline | ~94 ft | far end unusable |
| corner | ~100 ft | unusable |
| **sideline, mid-court, 3–4 m elevated** | **~70 ft** | both baskets symmetric |

At mid-sideline the nearest player is ~18 ft and the farthest ~70 ft — a ~4×
size gradient. From a corner it is ~8×, which tiling cannot absorb. The setup
flow must enforce mid-sideline placement.

### Capture resolution

`CameraService.swift:71` currently sets `.hd1920x1080`. With a fixed full-court
frame this is the only source of far-player pixels and must go to 4K.

Note that 4K alone does nothing — the model input is 960 either way:

| input path | model scale | far player (est.) |
|---|---|---|
| 1080p full frame → 960 | 0.50× | ~20 px (today) |
| 4K full frame → 960 | 0.25× | ~20 px (**no gain**) |
| 4K + 3 tiles (1280 px wide → 960) | 0.75× | **~60 px** |

**4K only pays off together with ROI tiling.**

### Computed tiles

Today's `farBand` is a hardcoded guess because the camera moves. With a fixed
camera and a solved homography the tiles can be derived:

1. Split the court into N zones in **court feet** along the 94 ft length.
2. Project each zone's corners to image space through the inverse homography.
3. Pad, clamp to frame, use as `detectAll(roi:)` regions.
4. Compute once per session at calibration.

Reuses `Homography.swift` unchanged.

### Round-robin lane keeps tick cost flat

```
every tick      : full frame ×1        (ball, rim, near players)
one tile / tick : A → B → C → A ...    (far detail)
```

Structurally identical to the existing `farEvery: 2` lane — one guessed band
generalized to N computed tiles. **No additional inferences per tick.** A fixed
camera means each zone changes slowly, so a 1/N refresh rate per zone is
sufficient; players do not teleport.

## Change list, ordered

| # | change | files | size | unblocks |
|---|---|---|---|---|
| 1 | Capture at 4K | `CameraService.swift:71` | 1 line | #2 |
| 2 | Record fixed full-court 4K fixture (60 s, mid-sideline, tripod) | `CourtVisionTests/Fixtures/` | — | everything measurable |
| 3 | Computed ROI tiles + round-robin lane | `Engine.swift` (`Config`, tick lanes), `CourtEstimator` | medium | far-player recall |
| 4 | IoS number↔player matching | `PlayerTracker.swift:121` → `PlayerFinder.containment()` | few lines | jersey accuracy |
| 5 | `CourtEstimator`: solve-once + drift check | `CourtEstimator.swift` | medium | removes 0-fix failure |
| 6 | `RimTracker`: drop pan reacquisition / flip cooldown | `RimTracker.swift` | medium | simplification |
| 7 | CoreMotion tripod-bump detection | new, small | small | calibration validity |
| 8 | Court keypoint model (CoreML, 1 Hz slow lane) | new `ObjectDetector` slot | medium | backup for #5 |
| 9 | `clean_paths` port (savgol) | `tools/` | small | path quality, offline |

Items 3 and 5 are the pair that actually resolve the two measured failures.

Neither ARKit nor CoreMotion is currently used anywhere in the app — verified.
ARKit plane detection plus 6DoF camera pose is a stronger version of #7 (it
would survive accidental camera movement rather than merely detecting it), but
gym floors are low-texture and it adds a parallel tracking session. Evaluate
only if #7 proves insufficient.

## Gates (nothing merges without a number)

Recorded in `docs/EVAL.md`, same format as existing rows.

- [ ] Fixed full-court fixture recorded at 4K; frame count and duration logged
- [ ] Court fix rate: currently **0 / 60 s**. Target ≥ 95 % of ticks after #5
- [ ] Far-zone players per tick, 4K+tiles vs 1080p full frame, same clip
- [ ] Distinct track ids / 60 s: currently **51** at 11 players/tick median
- [ ] ms/tick median on device with the tiling lane; must stay under
      `1000 / tickHz` with headroom and no serious thermal state at 10 min
- [ ] Jersey number accuracy before/after IoS matching (#4)
- [ ] Per-class P/R on the fixed val set for any model swap (#8)

## Open questions

1. **Tile count N.** 2 tiles (each 1920 wide → 0.5× scale) versus 3 (1280 wide
   → 0.75×). More tiles means better far resolution but a slower refresh per
   zone. Decide from #3's measurement, not from theory.
2. **Capture frame rate at 4K.** The tick runs at 6 Hz regardless; capture rate
   affects motion blur and `ball-in-basket` sampling. 4K30 assumed until
   measured.
3. **`ball-in-basket` recall** was a *tick rate* problem (6 Hz), not a capture
   or model problem — the fixture's made shot scored MISSED because no
   observation landed in the window. Whether freed budget should go to a higher
   `tickHz` rather than more tiles is an open trade.
4. Whether ref 02's keypoint model (#8) is licensed for anything beyond
   personal testing — check the Roboflow Universe license field before shipping,
   per MODEL_PIPELINE.md §3.
