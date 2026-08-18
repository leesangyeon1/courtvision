# CourtVision — Master Instruction

The single entry point for building, training, and improving this app.
Integrates `MODEL_PIPELINE.md` (architecture · training · accuracy playbook)
and `IOS_REFERENCES.md` (curated external references). Read this first;
dive into those two for depth.

---

## 0. What this app is

Basketball shooting analytics in the HomeCourt / SwingVision class: the
iPhone does all computer vision **on-device**, Supabase is the entire
backend, a React dashboard on Vercel shows stats live within 10 seconds.
Game filming model: the camera follows play — **one hoop in frame at a
time**, panning on possession change. Nothing about the court is ever a
hard lock.

Principles that override everything else:
- **No fake detections, ever.** Missing model → nil → heuristic fallback or
  an honest "—". A shot with no court fix queues briefly and is dropped,
  never given an invented location.
- **Zero dependencies** (Supabase SDK excepted). Native API first, pattern
  from a reference repo second, new dependency never.
- **One module, one branch**: `rim`, `ball`, `player`, `court`, integration
  on `dev`. Field-test a module before it graduates.

## 1. Architecture — a stack of small specialists

One big model is a server-side idea. On-device, cost is
`Σ (model size × call frequency)`, so the app layers small per-class
models, each at the slowest cadence its object allows:

| Layer | Model (bundle file) | Lane | Why |
|---|---|---|---|
| All classes | `BasketballDetector.mlmodelc` (unified 10-class) | every tick (`Engine.Config.tickHz`, see docs/EVAL.md) | ONE inference feeds ball, players, states, numbers, unified rim |
| Rim | `HoopDetector.mlmodelc` ∪ unified `rim` | slow lane (`slowEvery` ticks ≈ 1 Hz) | Rims don't move; only the camera does |
| Court | Geometric (`VNDetectRectanglesRequest` + rim scoring) → keypoint model in P2 | slow lane | Continuous estimate, never a hard lock |
| Jersey number | unified `number` regions + `VNRecognizeTextRequest` (ROI only) | `numberEvery` ticks ≈ 2 Hz | OCR is the expensive part, not detection |

- **One clock, one inference.** `Services/Engine/Engine.swift` runs the
  unified model once per tick keyed to the frame's presentation time and
  emits a `Moment`; modules filter the shared output. Never add a loop or a
  second call to the same model — add a lane in `Engine.Config`.
- **Cadence discipline.** Raising `tickHz` is a measured decision
  (docs/EVAL.md tick-cost table), never a guess. Thermal serious/critical
  halves the rate; modules are never dropped silently.

Code shape: one `ObjectDetector` instance per model file
(`Services/ObjectDetector.swift`); modules reference
`ObjectDetector.hoop/.ball/.player/.unified`. Detection filters take **label
sets** (`["rim", "Basketball Hoop"]`) so model swaps never break a module.
Swapping a model = replace the `.mlpackage`, adjust a label set, done.

## 2. Tracking algorithms (on top of raw detections)

Raw boxes are never used directly:

- **Continuity gate** (rim + ball): keep the candidate nearest the current
  track or the user's tap, reject anything beyond `within` — side hoops,
  second balls, round false positives can't steal a track. **A tap is
  authoritative**; detections may only refine it locally. Ball reach scales
  with time-since-last-sighting (`min(0.15 + 0.35·gap, 0.5)`).
- **Track memory** (`BallTrack`): timestamped samples; >1 s gap = new flight
  (possessions don't smear together); samples age out at 1.5 s.
- **Rim occlusion tolerance**: players block the rim constantly — only 4 s
  without a sighting triggers reacquisition; a >15%-frame jump triggers it
  immediately (camera panning).
- **Court**: every tick, all rectangle candidates are scored by projecting
  the detected rim through each candidate homography — the orientation that
  puts the rim at a real hoop position wins (NEX patent US11594029 style).
  Far court jump + 5 s cooldown = camera swung to the other hoop →
  **attacking team flips automatically** (manual ⇄ button as override).
  Only the rim is required to start recording.
- **Player quality passes** (`PlayerFinder`): ① low confidence floor (0.30)
  so nobody is missed → ② person shape/size/position filter kills what the
  low floor lets in → ③ cross-class IoU dedupe (per-class NMS leaves one
  player as both `player` and `player-jump-shot`).
- **Jersey numbers**: OCR only inside detected `number` ROIs; 1–2 digit
  numerics only; assigned only to a player box containing the number's
  center.

## 3. Training a specialist (recipe)

```sh
cd research
uv venv --python 3.12 yolo-env            # coremltools breaks on 3.14
uv pip install --python yolo-env/bin/python ultralytics coremltools roboflow

# 1. dataset (check the license — prefer CC BY 4.0)
#    Roboflow download → yolov8 format → fix data.yaml to absolute paths
# 2. train: n@640 first; s or @960 only when the failure mode is resolution
yolo-env/bin/python -c "
from ultralytics import YOLO
m = YOLO('yolov8n.pt')
m.train(data='DS/data.yaml', epochs=40, imgsz=640, batch=16,
        device='mps', patience=12)
print(m.val(device='mps').box.map50)"
# 3. export (NMS baked in → Vision yields labeled observations)
#    third-party .pt: static pickle-scan first (allowlist torch/ultralytics)
m.export(format='coreml', nms=True, imgsz=640)
# 4. integrate: cp -R best.mlpackage ios/CourtVision/<Name>Detector.mlpackage
#    xcodegen + Xcode compile it automatically; wire an ObjectDetector slot
```

Hard-won rules:
- **Resolution before depth** — v8s@960 beat bigger nets at 640 for the
  ball; blurred small objects lack pixels, not model capacity.
- **Never let an unverified model take over a working module** — check
  per-class AP on val before switching (the unified model's val had zero rim
  instances; rim stayed on proven weights).
- Resume crashed runs from `weights/last.pt` (`resume=True`).
- Two models can serve one object in union (rim) when reliability matters.

## 4. Improving accuracy & recall

Why mAP plateaus (~0.88): data ceiling not model ceiling · label noise sets
a hard bound (~0.85–0.90 at 10% noise) · tiny val sets (14 images) can't
measure change < ±0.05 · mAP is a mean that hides rare classes · small-object
physics. More epochs / bigger nets / reruns do NOT fix any of these.

**The flywheel (highest payoff per hour):**
```
record own footage → mine hard frames → model-assisted labeling →
retrain → deploy → the new model's failures are the next batch
```
Mine, don't sample: low-confidence band (0.2–0.5), track-break events (the
app fires them live), model-vs-heuristic disagreement, frame flicker,
rare-class moments. Pre-label with the current model, human only corrects.
Dedupe before labeling (1–2 s spacing + perceptual hash) — 500 diverse hard
frames beat 5,000 near-dupes. **Own-domain frames (courtside phone, your
gyms) outweigh any public dataset.**

**Dataset merging** (for rare-class recall) only under four rules:
① label-policy match (inspect ~50 imgs/source; rim=ring vs ring+net ⇒
relabel or reject) · ② every merged image fully labeled for every kept class
(else negative-label poisoning teaches the model to ignore objects) ·
③ two-stage: pretrain on merged pool → fine-tune last on own domain ·
④ hash-dedupe across sources (Roboflow sets fork each other → val leak).

**GPU runs = sweeps, not repetition**: same config rerun is seed noise.
Sweep lr/epochs/imgsz/augmentation against one fixed val set (100+ images,
different games from training). Track per-class P/R, not the mAP mean.

## 5. Future shot pipeline (composition, not new CV)

The V1 trajectory approach was deleted for producing junk. The rebuilt
pipeline composes existing layers — plug-in point:
`RecordModel.handleTrack` (`onCourtFix` marker).

0. Consumers read `Moment`s from `Engine`; the plug-in point is
   `RecordModel.publish`.
1. `player-jump-shot` / `player-layup-dunk` → **attempt**, shooter box known
   → feet → homography → court position → zone/category (3PT via ZoneMapper).
2. `ball-in-basket` near the tracked rim → **MAKE**; attempt without it in
   the flight window (`BallTrack`) → MISS.
3. Jersey number on the shooter box → per-player attribution.
4. Auto end-switch → team attribution → existing Supabase events → live
   dashboard. The event contract does not change.

## 6. External references (short list — full table in IOS_REFERENCES.md)

- **[Ultralytics YOLO iOS app](https://github.com/ultralytics/yolo-ios-app)**
  — same stack as ours, full source; frame plumbing + thermal patterns.
- [ObjectDetection-CoreML](https://github.com/tucan9389/ObjectDetection-CoreML)
  — minimal real-time Vision+CoreML loop.
- [NextLevel](https://github.com/NextLevel/NextLevel) — AVFoundation capture
  deep reference (fps, lenses, buffers).
- [swift-algorithm-club](https://github.com/kodecocodes/swift-algorithm-club)
  — first stop before writing any nontrivial algorithm.
- [Awesome-CoreML-Models](https://github.com/likedan/Awesome-CoreML-Models)
  — scouting pretrained models (court keypoints).
- Rule: pattern first, dependency never, native API before either.

## 7. Every-change checklist

- [ ] Unit tests green (`xcodebuild … test`) — gate/dedupe/scoring logic
- [ ] Model compiles into the bundle (`CoreMLModelCompile` in build log)
- [ ] Device field test per module: rim holds through occlusion · ball trail
      sticks through a flight · player count ≈ bodies on court · numbers on
      facing jerseys · no thermal throttling in 10 min
- [ ] Per-class P/R vs the fixed val set recorded
- [ ] Commit on the module branch → push → merge to `dev`
