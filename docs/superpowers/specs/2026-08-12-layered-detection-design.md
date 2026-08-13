# Layered Detection Pipeline — Design

Date: 2026-08-12
Status: approved (Approach A + persistent jersey numbers)
Branch base: `dev`

## Problem

Wrong-class detections corrupt game events. Two causes, one from the model,
one from the code:

1. **Model:** the unified 10-class detector mixes physical objects (`ball`,
   `rim`, `player`, `referee`) with player *states* (`player-in-possession`,
   `player-jump-shot`, `player-layup-dunk`, `player-shot-block`) and ball
   states (`ball-in-basket`). States are not mutually exclusive with their
   base object, so the detector head fights itself — a jump-shooting player
   is both `player` and `player-jump-shot`, and per-class NMS emits both.
2. **Code:** `ObjectDetector.detect()` returns bare `[CGRect]` — label and
   confidence are discarded at the boundary. Downstream cannot distinguish
   classes, rank rivals, or classify state even when the model got it right.

ML-expert guidance (adopted): detect core physical objects first, track them,
classify player state/action as a separate layer on top; keep the dedicated
rim detector (it outperforms the unified rim class in the field); strengthen
per-class validation *before* any further model split or retrain.

## Design (Approach A — code-only layering, existing models)

### Layer 1 — Detect (core physical objects)

- New `Detection` struct: `{ box: CGRect, label: String, confidence: Float }`
  (normalized box, top-left origin — same convention as today).
- `ObjectDetector.detect(labels:in:maxCount:minConfidence:)` returns
  `[Detection]` instead of `[CGRect]`. Same Vision plumbing, label and
  confidence survive.
- Finders keep their roles and thresholds:
  - `RimFinder`: HoopDetector ∪ unified `rim`, IoU-deduped, 0.30 floor,
    orange-blob fallback — **unchanged** except `Detection` plumbing.
  - `BallFinder`: `ball` + `ball-in-basket` labels, 0.25 floor — unchanged,
    but the chosen sample's label is kept (see Layer 2).
  - `PlayerFinder`: detects with the full player label set (state classes are
    still evidence of a player), shape filter + cross-class IoU dedupe stay.
    When deduping an overlapping pair, the surviving box keeps the **base
    `player` geometry** where available; state labels are passed through to
    Layer 3, never dropped. `referee` stays excluded from the player set.

### Layer 2 — Track

- New `PlayerTracker` (Services/Player/PlayerTracker.swift): greedy IoU
  association between the previous tick's tracks and this tick's player
  boxes. Stable integer IDs; a track dies after `maxMissedTicks` (default 4
  ticks ≈ 2 s at the 2 Hz player cadence). No Kalman, no re-id embedding —
  `ponytail:` comment marks the upgrade path if greedy IoU proves too weak.
- `BallTrack.Sample` gains `label: String` — `ball-in-basket` is a state
  observation the future make/miss logic reads from the *track*, not from a
  raw frame.
- Rim tracking (continuity gate, occlusion tolerance, tap anchors) is
  untouched.

### Layer 3 — Classify state + identity

- New `ActionClassifier` (Services/Player/ActionClassifier.swift): pure
  function. Input: this tick's raw state-class detections
  (`player-in-possession`, `player-jump-shot`, `player-layup-dunk`,
  `player-shot-block`) + current player tracks. Output: per-track
  `PlayerAction` enum (`none`, `possession`, `jumpShot`, `layupDunk`,
  `shotBlock`). Assignment by IoU between state box and track box (threshold
  0.45, same as the dedupe constant); best IoU wins; a state box matching no
  track is dropped (it is a detector mistake by construction — states cannot
  exist without a player).
- **Persistent jersey numbers (user requirement):** `NumberReader` output is
  assigned to *tracks*, not per-frame boxes. Each track keeps a tally of
  OCR'd digit strings; the track's displayed number is the majority vote.
  Once established, the number persists while the track lives — a jersey
  turning away no longer blanks the number. A new majority (sustained
  misread correction) may replace it.
- `RecordModel` player loop wires the layers:
  detect → `PlayerTracker.update` → `ActionClassifier.classify` → number
  tally → published `[TrackedPlayer]` (id, box, number, action) for the
  overlay. Overlay shows number and (when not `none`) the action state.

### Validation tooling

- `tools/eval_model.py`: thin wrapper over ultralytics `model.val()` — runs
  a `.pt` checkpoint against a fixed val set (`data.yaml` path argument),
  prints a per-class precision/recall/AP table and writes the confusion
  matrix ultralytics already produces. No custom metric code.
- `docs/MODEL_PIPELINE.md` updated: layered pipeline section (detect → track
  → classify), persistent-number rule, and the guardrail adopted from the
  expert: **no model split or retrain without per-class failure evidence
  from the fixed val set** (the 14-image val set and the zero-rim-instance
  incident are the cautionary examples).

### Explicitly not doing (YAGNI, per expert)

- No retraining, no new models, no 4-class core-model split.
- No Kalman/re-id tracking, no folder restructure (module folders mirror the
  `rim`/`ball`/`player`/`court` branch layout).
- No make/miss shot pipeline in this refactor — the layers are its
  foundation, the pipeline itself stays future work (`onCourtFix` marker).
- detectron2/transformers installed for research use only; the app pipeline
  does not depend on them.

## Error handling

- Missing model → `detect` returns `[]`, finders fall back exactly as today
  (orange-blob rim, "—" statuses). No fake detections, ever.
- OCR misreads → majority vote absorbs them; 1–2 digit numeric guard stays.
- Track ID churn (player fully leaves frame) → new ID; number tally restarts.

## Testing

Unit tests (XCTest, same style as existing gate/dedupe tests):

1. `PlayerTracker`: association keeps IDs across ticks; track dies after
   `maxMissedTicks`; crossing players with modest overlap keep their IDs.
2. `ActionClassifier`: state box annotates best-IoU track; orphan state box
   dropped; `none` when no state detected.
3. Number persistence: majority vote; number survives frames without a read;
   sustained new majority replaces old number.
4. `Detection` plumbing: label/confidence survive `ObjectDetector` mapping
   (coordinate flip unchanged).

Existing tests must stay green. Field-test checklist in MODEL_PIPELINE.md §6
applies before merging `dev`.
