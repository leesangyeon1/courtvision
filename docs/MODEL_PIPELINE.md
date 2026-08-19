# CourtVision Model Pipeline

How the app runs multiple specialist models on top of each other (court, rim,
ball, player, jersey number), how each model is trained and swapped, and how
to keep improving accuracy and recall. Distilled from the V1 build sessions.

---

## 1. Architecture: a stack of small specialists, not one big model

One giant model is a server-side idea. On-device, the winning shape is
**several small specialist models, each running only as often as its object
actually changes**. Cost is not "number of models" — it is
`Σ (model size × call frequency)`. A nano model at the right cadence is
cheaper than one large model called for everything.

| Layer | Model (bundle file) | Lane | Why |
|---|---|---|---|
| All classes | `BasketballDetector.mlmodelc` (unified 10-class) | every tick (`Engine.Config.tickHz`, see docs/EVAL.md) | ONE inference feeds ball, players, states, numbers, unified rim |
| Rim | `HoopDetector.mlmodelc` ∪ unified `rim` | slow lane (`slowEvery` ticks ≈ 1 Hz) | Rims don't move; only the camera does |
| Court | Geometric (`VNDetectRectanglesRequest` + rim scoring) → keypoint model in P2 | slow lane | Continuous estimate, never a hard lock |
| Jersey number | unified `number` regions + `VNRecognizeTextRequest` (ROI only) | `numberEvery` ticks ≈ 2 Hz | OCR is the expensive part, not detection |

Rules that make the stack work:

- **One clock, one inference.** `Services/Engine/Engine.swift` runs the
  unified model once per tick keyed to the frame's presentation time and
  emits a `Moment`; modules filter the shared output. Never add a loop or a
  second call to the same model — add a lane in `Engine.Config`.
- **Cadence discipline.** Raising `tickHz` is a measured decision
  (docs/EVAL.md tick-cost table), never a guess. Thermal serious/critical
  halves the rate; modules are never dropped silently.
- **One `ObjectDetector` instance per model file** (`Services/ObjectDetector.swift`).
  Modules reference `ObjectDetector.hoop / .ball / .player / .unified`; swapping
  a model is a file replacement plus (at most) a label-set edit.
- **Label sets, not single labels.** Detection filters accept sets
  (`["rim", "Basketball Hoop"]`) so a model generation change never breaks a
  module.
- **No fake detections, ever.** A missing model returns nil → the module shows
  "—" or falls back to a heuristic (orange-blob rim). Never fabricate data.
- **Union detection for critical objects.** The rim queries BOTH the dedicated
  hoop model and the unified model's `rim` class and merges non-overlapping
  candidates — one model's missed tick doesn't drop the track.
- **Git layout mirrors the stack**: branches `rim`, `ball`, `player`, `court`,
  integration on `dev`. Each module is developed, field-tested, and rolled
  back independently.

## 2. Tracking algorithms (what sits on top of raw detections)

Raw detections are never used directly. Each module wraps them:

### The three layers (detect → track → classify)

Detection output is `Detection {box, label, confidence}` — labels survive.
1. **Detect** (`ObjectDetector` + finders): core physical objects only —
   ball, rim, player. State classes count as player *evidence*, never as
   extra players (`PlayerFinder.corePlayers` ranks base boxes first).
2. **Track** (`PlayerTracker`, `BallTrack`): greedy-IoU stable player IDs
   (2 s tolerance at 2 Hz); ball samples carry their label
   (`ball-in-basket` is a state read from the track, not a raw frame).
3. **Classify** (`ActionClassifier`): state-class boxes annotate the
   best-IoU track (`possession`/`jumpShot`/`layupDunk`/`shotBlock`);
   an orphan state box is a detector mistake by construction and is
   dropped. Jersey numbers tally per track — majority vote, persists
   while the track lives.

### Continuity gate (rim + ball)
`pickRim/pickBall(candidates, near: anchor, within: maxDistance)` — keep the
candidate nearest the current track (or the user's tap), and **reject
candidates beyond `within`**. This is what stops a side hoop, a second ball,
or a round false positive from stealing the track. A user tap is
authoritative: detections may refine it locally, never move it elsewhere.

- Rim: `within 0.15–0.25` of anchor; per-end anchors keyed by attacking team.
- Ball: reach scales with the time since last sighting
  (`min(0.15 + 0.35·gap, 0.5)`) — a ball unseen for half a second may
  legitimately reappear far away.

### Track memory (ball)
`BallTrack`: timestamped samples; >1 s gap resets the track (a new possession
must not smear into the old flight); samples age out at 1.5 s. The trail is
both the overlay and the raw material for the shot pipeline.

### Occlusion tolerance (rim)
The rim is occluded by players constantly. Rim-lost only triggers
reacquisition after **4 s** without a sighting; a big rim jump (>15% frame)
triggers it immediately (camera is panning).

### Court: continuous estimate, never a lock
The camera pans every possession, so the court is re-estimated every tick:
all rectangle candidates are scored by **rim-consistency** (project the
detected rim through each candidate homography; the orientation that puts the
rim at a real hoop position wins — NEX patent US11594029 style). A far court
jump + 5 s cooldown = camera swung to the other hoop → attacking team flips
automatically. Only the rim is required to start recording; shots queue
briefly (≤20 s) until the first court fix and are never given a fake location.

### Player quality passes
Raw player output needs three passes (in `PlayerFinder`):
1. **Low confidence floor (0.30)** so nobody on the floor is missed…
2. **Shape/size/position filter** kills what the low floor lets in:
   boxes must be taller-than-wide-ish, not specks, not huge, not floating in
   the scoreboard zone.
3. **Cross-class IoU dedupe (0.45)**: the model's NMS is per-class, so one
   player detected as both `player` and `player-jump-shot` arrives as two
   boxes — merge, best confidence wins.
4. **Containment dedupe (0.75 intersection-over-smaller)**: a near player
   yields a body box AND a torso/head fragment inside it (IoU small);
   the fragment is dropped.
5. **Only tracks seen this tick are emitted** (`Engine` → `Moment`): a
   track that missed a tick stays in the tracker for re-association, but its
   stale box is never drawn or recorded — ghosts read as duplicate players.

### Jersey numbers
The model detects `number` regions; Vision OCR (`.fast`, no language
correction) reads **only those ROIs** — never a full-frame text pass. Guards:
1–2 digit numerics only (sponsor logos ≠ numbers); a number is assigned only
to a player box that contains its center. Numbers persist per track via
majority vote (`PlayerTracker.assign`).

## 3. Training method (per specialist)

Environment (once):
```sh
cd research
uv venv --python 3.12 yolo-env          # coremltools breaks on 3.14
uv pip install --python yolo-env/bin/python ultralytics coremltools roboflow
```

Per-model recipe:
```sh
# 1. Dataset (Roboflow export, YOLOv8 format) — check the license field!
yolo-env/bin/python -c "
from roboflow import Roboflow
rf = Roboflow(api_key=API_KEY)
rf.workspace(WS).project(PROJ).version(N).download('yolov8', location='DS')"
# fix data.yaml paths to absolute

# 2. Train (Apple Silicon: device='mps'; cluster: device=0)
yolo-env/bin/python -c "
from ultralytics import YOLO
m = YOLO('yolov8n.pt')                  # n first; s only if n plateaus AND data supports it
m.train(data='DS/data.yaml', epochs=40, imgsz=640, batch=16,
        device='mps', patience=12)
print(m.val(device='mps').box.map50)"

# 3. Export CoreML (NMS baked in → Vision gives labeled observations)
#    third-party .pt files: static pickle-scan before loading (pickletools,
#    allowlist torch/ultralytics/collections globals only)
m.export(format='coreml', nms=True, imgsz=640)

# 4. Integrate
cp -R best.mlpackage ios/CourtVision/<Name>Detector.mlpackage
# xcodegen picks it up; Xcode compiles to .mlmodelc automatically
# add an ObjectDetector static + label set if it's a new slot
```

Rules learned the hard way:
- **Resolution before depth** for small objects: v8s@960 beat bigger nets at
  640 for the ball. The ball's failure mode is missing pixels, not missing
  capacity.
- **Don't let an unverified model take over a working module.** The unified
  model's val split had no rim instances → rim stayed on the proven weights,
  new model got ball/player. Verify per-class AP before switching a module.
- **Keep licenses clean**: prefer CC BY 4.0 datasets (eagle-eye,
  basketball-players-fy4c2). Unlicensed weights (avishah3) are fine for
  personal testing, not for public release.
- Resume interrupted runs from `weights/last.pt` with `resume=True` — never
  restart from zero.

## 4. Improving accuracy & recall (the flywheel)

### Why mAP plateaus (~0.88) no matter how hard you train
1. **Data ceiling, not model ceiling** — a few hundred/thousand images
   saturate v8n already; extra capacity memorizes, it doesn't learn.
2. **Label noise bounds mAP**: 5–15% missing/loose boxes ⇒ ~0.85–0.90 ceiling
   for ANY model.
3. **Tiny val sets can't measure improvement**: 14 val images swing several
   points on one image; differences < ±0.05 are noise. Roboflow default
   splits also leak same-game frames into train and val.
4. **mAP is a mean over classes** — rare classes drag it; improving what
   matters may not move the headline number. Track per-class P/R.
5. **Small-object physics** — a blurred distant ball has no information for a
   deeper net to recover; resolution and frame rate help, depth doesn't.

**Guardrail (adopted from expert review): no model split or retrain without
per-class failure evidence from the fixed val set** — run
`tools/eval_model.py` and read the per-class rows, not the mAP mean. The
14-image val set and the zero-rim-instance val split are the cautionary
examples.

### Active learning loop (highest payoff per hour)
```
record own footage → mine hard frames → model-assisted labeling →
retrain → deploy → new model's failures = next batch
```
Mine, don't sample: low-confidence band (0.2–0.5), track-break moments (the
app fires these live), model-vs-heuristic disagreement, frame-to-frame
flicker, rare-class moments (`ball-in-basket`). Pre-label with the current
model and only correct — 5–10× faster. Dedupe before labeling (min 1–2 s
spacing + perceptual hash): 500 diverse hard frames beat 5,000 near-dupes.
**Own-domain frames (courtside phone, your gyms) outweigh any public data** —
a 0.85 own-domain model beats a 0.92 broadcast model on your court.

### Dataset merging rules (for rare-class recall)
Merging external datasets helps recall ONLY under these rules:
1. **Label-policy match**: inspect ~50 images per source; if box conventions
   differ (rim = ring vs ring+net), relabel or reject the source.
2. **Full coverage**: every merged image must be labeled for EVERY class you
   keep — an unlabeled object trains the model to ignore that class
   (negative-label poisoning). Drop the image or the class otherwise.
3. **Two-stage training**: pretrain on merged pool → fine-tune last on
   own-domain frames. Evaluate on an own-domain val set.
4. **Hash-dedupe across sources** — Roboflow sets fork each other; duplicates
   leak into val and inflate scores.

### GPU runs = sweeps, not repetition
Re-running the same config is seed noise. Spend runs on a sweep (lr, epochs,
imgsz, augmentation), all judged against the **same fixed val set** —
100+ images, different games from anything in training.

## 5. Future: the shot pipeline (how the layers combine)

The specialist outputs compose into shot detection without trajectory
geometry (the V1 trajectory approach was deleted for producing junk):

1. `player-jump-shot` / `player-layup-dunk` detected → **shot attempt**, with
   the shooter box already identified → feet point → homography → court
   position → zone + category (3PT via ZoneMapper arc math).
2. `ball-in-basket` detected near the tracked rim → **MAKE**; attempt without
   it within the flight window → MISS. `BallTrack` supplies the flight window
   and disambiguates passes.
3. Jersey number on the shooter box → per-player attribution.
4. Attacking team (auto end-switch) → team attribution → existing
   Supabase events → live dashboard. The event contract does not change.

Plug-in point: `RecordModel.handleTrack` (`onCourtFix` marker).

## 6. Verification checklist (every model swap)

- [ ] Unit tests green (`xcodebuild … test`) — gates/dedupe/scoring logic
- [ ] Model compiles into bundle (`CoreMLModelCompile` in build log; check
      `.mlmodelc` inside the built .app)
- [ ] Field test on device per module: rim holds through occlusion; ball
      trail sticks through a full flight; player count matches bodies;
      numbers appear on facing jerseys; no thermal throttling after 10 min
- [ ] Per-class P/R recorded against the fixed val set (not just mAP mean)
- [ ] tools/eval_model.py per-class table reviewed for the swapped model
- [ ] Commit on the module's branch, push, merge to `dev` for integration
