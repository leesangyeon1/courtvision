# Tracking Engine — Design

Date: 2026-08-17
Status: approved (Approach A — tracking engine rebuild; single phone; two
fidelity tiers; own-labeled court keypoints)
Branch base: `dev`
Supersedes nothing — builds on `2026-08-12-layered-detection-design.md`.

## Problem

CourtVision is a shot-event app: the phone runs three independent detector
loops (rim+court 1 Hz, ball 8 Hz, player 2 Hz) inside `RecordModel`
(`Views/RecordView.swift`), and the only data product is a `shot` row. On
`dev` the shot pipeline is deleted (V1 trajectory approach produced junk), so
the app currently emits **no events at all**.

The target is the shape of an NBA official tracking program (Hawk-Eye
Innovations, NBA since 2023-24): continuous player + ball positions on a
common clock, events *derived* from tracking, a live feed plus a cleaner
post-processed feed, and accuracy that is measured against ground truth. The
physical gap (14 fixed cameras, 60 Hz, 3D skeletons vs one moving phone) is
accepted; the data model, pipeline shape, and rigor are portable.

Structural problems in the current code that block that:

1. **Three loops, three clocks.** Each loop grabs `latestPixelBuffer` on its
   own timer, calls the *same* unified model separately (~11 inferences/s of
   one model), and stamps samples with `Date()`, not frame PTS. Nothing can
   be fused or post-processed reliably.
2. **Orchestrator in a View.** `RecordModel` (~300 lines) is the pipeline;
   it cannot run in a test or on a video file.
3. **Court = rectangles.** `VNDetectRectanglesRequest` + rim-projection
   scoring (accept ≤ 15–25 ft error). Gyms rarely show a clean quad; the
   references (01/02/05) all use a court-keypoint model.
4. **No tracking product.** No positional rows, no team assignment, ID
   churn at 2 Hz greedy IoU, `PoseService` unwired.
5. **No event-level or location-level accuracy measurement.** Only
   per-class detector AP (`tools/eval_model.py`).

## Decisions (from brainstorming)

- Single phone. No multi-camera schema (a rig later is a migration).
- Scope: shooting metrics **and** tracking data (moments, team, speed /
  distance, closest defender at attempt, possession). No officiating calls.
- Two fidelity tiers: live (events ≤ 10 s, coarse tracks) + on-device
  post-process at session end from a buffered `Moment` stream. No video
  storage.
- Court keypoints: label 300–500 own courtside frames (33-point schema from
  ref 02), model-assisted labeling; broadcast weights are not the target
  domain.
- Principles unchanged: on-device CV, Supabase-only backend, zero new
  dependencies, no fake data ever, one module per branch, integrate on `dev`.

## Design (Approach A)

### Architecture

```
CameraService ──frames(PTS)──▶ Engine.tick @ tickHz (~10; knob, thermal-adaptive)
                                   │ ONE unified inference (all 10 classes)
                                   │ + court-keypoint model @ 2 Hz, HoopDetector @ 1 Hz (union kept)
                                   ▼
                     rim → ball → players → team → court(H) → pose(shooter ROI only)
                                   ▼
                              Moment {pts, H, players[], ball, rim}
                        ┌──────────┴───────────┐
                   live consumers          MomentBuffer (whole session, RAM)
                overlay · ShotEventTracker        │ session end
                        │ events ≤10 s            ▼
                        ▼                    PostProcessor: re-ID merge → MAD outlier →
                   Supabase.events            interpolate → smooth → speed/distance
                   (OfflineQueue)                 ▼
                                             Supabase.moments + tracks (batched, idempotent)
```

### Components (iOS)

| Piece | Status | Change |
|---|---|---|
| `Services/Engine/Engine.swift` | new | Owns the tick loop, keyed to frame PTS. Replaces the three loops in `RecordModel`; `RecordModel` becomes a thin ViewModel that subscribes to `Moment`s and status. Runs without SwiftUI (tests, replay). `tickHz` is a knob; default chosen from the P0 cost table. |
| `ObjectDetector.detectAll(in:minConfidence:)` | edit | One call per tick returns all classes; finders filter by label set. Removes the 3× redundant inference. `detect(labels:…)` stays as a filter over `detectAll`. |
| `RimFinder`, `BallFinder`, `PlayerFinder`, `PlayerTracker`, `ActionClassifier`, `NumberReader` | keep | Fed from the tick; no own loops. `PlayerTracker` adds a center-distance gate (the existing `ponytail:` upgrade note); Kalman only if churn numbers demand it. |
| `CourtModel` | new (wraps `CourtFinder`) | Keypoint detections (conf ≥ 0.5, ≥ 4 points) → `Homography` (Hartley normalization; RANSAC when > 4 pairs) → **average H over a 5-tick window** (ref 01) → rim-reprojection sanity gate (project tracked rim through H; must land within a tolerance of the hoop — reuse `scoreCourtAssignments` math). Rectangle detection is the fallback; no fix → `H = nil`. |
| `TeamAssigner` | new | Core-player crops @ 1 Hz → `VNGenerateImageFeaturePrintRequest` embeddings → 2-means → per-track majority vote (ref 02's SigLIP/UMAP/K-means, native edition). `referee` class excluded from clustering. Team ↔ A/B mapping via the session's attacking-team state. |
| `PoseService` | rewire | `VNDetectHumanBodyPoseRequest` on the possession-track ROI only, each tick → ankle-midpoint history per track. At attempt start the shot location is the last ground-contact ankle midpoint (fixes ref 02's mid-air bbox-bottom error). Full-frame pose is never run. |
| `ShotEventTracker` | new (port of ref 02 / roboflow-sports) | ≥ N consecutive ticks of `jumpShot`/`layupDunk` on one track → attempt (pts, shooter track, feet → H → ft, closest-defender distance ft); `ball-in-basket` on the ball track near the tracked rim within the window → made, window expiry → missed; cooldown between attempts. Emits the existing `EventRow`. Free-throw sessions keep mode-based category. |
| `MomentBuffer` | new | Whole-session `[Moment]` in RAM (~24k moments / 40 min at 10 Hz; a few MB). |
| `PostProcessor` | new | Over the buffer: merge tracks on strong evidence (same team + same jersey number + gap ≤ 4 s); per-track speed series → median/MAD outlier flags (+ padding) → linear interpolation → moving-average smoothing (window 5); H smoothed over time; per-track distance / avg / max speed. Re-projects attempt locations from cleaned feet and updates events by id. |
| Upload | edit | Moments batched per second and `tracks` rows go through the existing `OfflineQueue` (idempotent by client id). |

`Moment` (Swift, mirrored in `moments.payload`):

```
Moment { pts: Double, h: [Double]?, rim: CGRect?,
         players: [{ trackId, team: "A"|"B"|nil, box, xFt?, yFt?, action, number? }],
         ball: { box, label, xFt?, yFt? }? }
```

### Data model (Supabase, additive `supabase/migrations/0004_tracking.sql`)

- `moments(session_id uuid, second int, payload jsonb, primary key (session_id, second))` — one row per session-second holding that second's ticks as SportVU-style arrays `[ts_ms, team, track_id, x_ft, y_ft]` plus ball `[ts_ms, x_ft, y_ft]`. RLS: same owner pattern as `events`. **Not** added to the realtime publication.
- `tracks(session_id, track_id, team, jersey_number, player_id?, distance_ft, avg_speed_fps, max_speed_fps, first_ts, last_ts, primary key (session_id, track_id))` — computed on-device by `PostProcessor`, upserted.
- `events` new columns: `attempt_ts int`, `shooter_track_id int`, `defender_dist_ft real`; `type` check widened to `('shot','possession')`. `possession` = ball acquisition change (min-distance ball ↔ player with hysteresis, ref 05); feeds possession %.
- Views: `session_shot_cells` (1-ft cells from `court_x·50`, `court_y·47`: fga, fgm, pts, ppa) for Goldsberry maps; `player_spread_range` (Spread = cells with fga ≥ 1; Range = cells with ppa > 1; both also as % of scoring-area cells, scoring area = cell centers ≤ 27.25 ft from the rim center or in the corner band y ≤ 14 ft — the count is computed, not hard-coded to Goldsberry's 1,284).
- Mirrors: `ios/CourtVision/Models/Contract.swift`, `web/src/types/contract.ts`; `tools/simulate_session.py` gains moments + tracks so the dashboard can be exercised without a phone.

### Web

- `HalfCourtShotChart` → graduated-symbol cell map (size ∝ FGA, diverging color centered on 1.0 PPA), Spread / Range stat tiles per player. Reuse `court.ts`.
- Tracking replay: top-down court + scrubber over `moments`.
- Tracks table (distance, avg/max speed) from `tracks`.
- Ref 06 discipline: ≤ 6 colors, one message per chart.

### Explicitly not doing (YAGNI)

Multi-camera / camera-aware schema, 3D ball or release angle, officiating
(travel, double-dribble, OOB), Voronoi control maps, dribble counting, video
storage, Kalman by default, SAM-2-style pixel tracking, any new dependency.

## Phases and gates

One branch each, integrate on `dev`. Every phase ends at a *measured* gate.

| # | Branch | Work | Exit gate |
|---|---|---|---|
| P0 | `engine` | Extract `Engine` + single tick + `Moment`; modules fed from tick; `RecordModel` → thin VM. Parity only. Measure ms/tick + thermal at 5 / 8 / 10 Hz. | Unit tests green; overlay parity on device; tick cost table recorded → chosen `tickHz` |
| P1 | `shots` | `ShotEventTracker` + pose feet on possession track + jersey → roster `player_id` + events flowing via `OfflineQueue`. Hand-label 5–10 own clips (attempt ts, made, x/y ft). `tools/eval_events.py`. | Attempt P/R (±1.5 s), make/miss accuracy, median location error on ≥ 5 clips, recorded in `docs/EVAL.md` |
| P2 | `court` (start day 1 — labeling is the long pole) | 33-pt schema; label 300–500 own frames (model-assisted, Roboflow); YOLO-pose n/s train; CoreML export; `CourtModel` (H average, RANSAC, rim gate); rectangles fallback. `tools/eval_court.py` (PCK / reprojection ft on a fixed val split). | Median shot-location error on GT clips drops vs the P1 baseline; keypoint reprojection error on fixed val ≤ the tolerance set from that baseline |
| P3 | `tracking` | `TeamAssigner`, `MomentBuffer`, `PostProcessor`, `0004_tracking.sql`, upload at session end, closest defender at attempt, possession events. | Post-processed ID churn < live churn on GT clips; distance / speed sane on known-length drills (baseline-to-baseline sprint = 94 ft) |
| P4 | `dashboard` | Cell shot map + Spread / Range, tracking replay, tracks table. | Renders from a real session; the 10 s event contract still holds |
| P5 | ongoing | Flywheel: engine emits hard-frame markers (track break, low-confidence band) → mine → label → retrain. Build the fixed 100+ image own-domain val set (open item from the layered-detection work). | Per-class table on the fixed val set each retrain |

Rough elapsed: P0 1 wk · P1 2 wk · P2 3–5 wk (labeling-bound, parallel) ·
P3 2 wk · P4 2 wk. P1 ships user value first — the app emits shots again.

## Error handling

- No court fix → moment keeps boxes, `xFt/yFt = nil`; attempts queue ≤ 20 s
  for a fix, then drop (existing rule). Never an invented location.
- Thermal (`ProcessInfo.thermalState` serious / critical) → engine halves
  `tickHz`; modules are never silently dropped; status shows the rate.
- Post-processor failure → live data stands; nothing overwritten. All writes
  idempotent by client id; moments and tracks go through `OfflineQueue`.
- Keypoint model missing or < 4 confident points → rectangle fallback → else
  `H = nil`.
- Track merge only on strong evidence (same team + same number + gap ≤ 4 s);
  ambiguous → separate IDs stay.

## Testing

- Keep existing pure-logic tests. New: `ShotEventTrackerTests`,
  `CourtModelTests` (H averaging, RANSAC, rim gate), `PostProcessorTests`
  (outlier / interpolate / smooth on synthetic tracks), `TeamAssignerTests`
  (2-means on synthetic embeddings).
- `EngineReplayTests`: run `Engine` over a bundled short clip via
  `AVAssetReader` → deterministic event / track counts. The off-device
  regression test for the whole pipeline.
- `tools/eval_events.py` and `tools/eval_court.py` join `tools/eval_model.py`;
  results per model / engine version live in `docs/EVAL.md`.
- Field checklist unchanged: rim holds through occlusion, ball trail sticks
  through a flight, player count ≈ bodies, numbers on facing jerseys, no
  thermal throttling in 10 min.

## Reference traceability

- 01 (Roboflow football): H averaging over a time window; ball outlier
  rejection by max travel; per-class mAP discipline.
- 02 (Roboflow basketball): 10-class taxonomy; ShotEventTracker
  (start → made / missed window); 33-point court keypoints; number ↔ player
  by containment; trajectory cleanup (MAD, interpolate, smooth) as a
  post-process.
- 04: model-assisted labeling loop; raise input resolution for small objects;
  eyeballing validation is the anti-pattern.
- 05 (NBA analysis, YOLO/OpenCV): possession by min-distance ball ↔ player;
  passes / interceptions from possession changes; speed / distance in real
  units via homography.
- 06 (The Athletic charts): ≤ 6 colors, one message per chart, consistent
  style.
- 07 (AI referee): pose ankles / wrists as action evidence.
- Goldsberry, SSAC 2012 *CourtVision*: 1-ft shooting cells; Spread; Range
  (PPA > 1); graduated-symbol maps (size = attempts, color = PPA).
- Hawk-Eye (NBA official tracking): continuous positions on one clock,
  events derived from tracking, live vs processed feeds, ground-truth gates.
