# Tracking Engine — P0 (engine) + P1 (shots) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three independent detector loops with ONE engine tick on the frame clock that emits `Moment`s (P0), then derive shot events from Moments so the app emits shots again — with a replay harness and a ground-truth eval script that measure attempt precision/recall, make/miss accuracy and location error (P1).

**Architecture:** `Engine.process(pixelBuffer, pts) -> Moment` runs one unified CoreML inference per tick and feeds the existing rim / ball / player modules from it (rim + court on a 1 Hz slow lane, numbers at 2 Hz). `RecordModel` becomes a thin ViewModel that pumps camera frames through the engine and publishes Moments. `ShotEventTracker` (ref 02's shot event tracker) opens an attempt on consecutive shooting-state ticks and resolves it with `ball-in-basket` near the rim; `PoseReader`/`FeetHistory` give the shooter's ground-contact point; `ShotEventMapper` turns resolutions into the existing `EventRow` contract. `EngineReplay` runs the same engine over a video file for tests and ground truth.

**Tech Stack:** Swift 5 / iOS 17, AVFoundation, Apple Vision + CoreML, XCTest, xcodegen; Python 3 stdlib (`tools/eval_events.py`), repo `.venv` only for `eval_model.py`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-17-tracking-engine-design.md` (approved 2026-08-17). Phases P2–P5 are outlined in the appendix and get their own plans at their gates.
- Branches: P0 on `engine`, P1 on `shots`, both off `dev`; merge to `dev` at the end of each phase. Commit per task.
- Single phone; on-device CV; Supabase-only backend; **no new dependencies**; **no fake data** (no court fix → `nil`, never an invented number).
- All boxes/points normalized, TOP-LEFT origin (Vision's bottom-left flipped at the detector boundary — existing convention). Court coordinates in feet on the standard half court (`ZoneMapper`), rim at (25, 5.25).
- Confidence floors unchanged: rim 0.30, ball 0.25, player 0.30, number 0.30. Unified `detectAll` runs at the lowest floor (0.25); modules re-filter.
- Engine clock is the frame presentation time (`pts`, seconds). `Date()` is never used for pipeline decisions. `BallTrack` keeps its `Date` API — the engine passes `Date(timeIntervalSinceReferenceDate: pts)`.
- No DB migration in P0/P1. The event contract (`supabase/migrations/0001_init.sql`) is unchanged.
- Test command (from `ios/`):
  ```bash
  xcodegen generate
  SIM=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed -E 's/ *\(.*//' | xargs)
  xcodebuild -project CourtVision.xcodeproj -scheme CourtVision \
    -destination "platform=iOS Simulator,name=$SIM" test
  ```
  Expected on success: `** TEST SUCCEEDED **`. Run this at every "Run tests" step unless a narrower `-only-testing:` is given.
- Device build (parity checks) — same command with `-destination 'platform=iOS,name=<your iPhone>' build`, then run from Xcode or `xcrun devicectl`.

---

## Phase P0 — Engine (branch `engine`)

### Task 1: `Moment` — the tick output; action confidence rides the track

**Files:**
- Create: `ios/CourtVision/Services/Engine/Moment.swift`
- Modify: `ios/CourtVision/Services/Player/PlayerTracker.swift` (`TrackedPlayer` gets `actionConfidence`; reset per tick)
- Modify: `ios/CourtVision/Services/Player/ActionClassifier.swift:33-46` (`classify` sets `actionConfidence`)
- Test: `ios/CourtVisionTests/ActionClassifierTests.swift` (one assertion added)

**Interfaces:**
- Produces:
  ```swift
  struct Moment: Equatable {
      struct PlayerState: Equatable { let trackId: Int; var team: String?; var box: CGRect; var feet: CGPoint; var xFt: Double?; var yFt: Double?; var action: PlayerAction; var actionConfidence: Float; var number: String? }
      struct BallState: Equatable { var box: CGRect; var label: String; var xFt: Double?; var yFt: Double? }
      let pts: Double; var h: Homography?; var rim: CGRect?; var players: [PlayerState]; var ball: BallState?
  }
  ```
  `TrackedPlayer.actionConfidence: Float` (0 when `action == .none`). Every later task consumes `Moment`.

- [ ] **Step 1: Branch, then write the failing test** — `git checkout -b engine dev`; append to `ActionClassifierTests.testStateAnnotatesBestIoUTrack`:

```swift
        XCTAssertEqual(out[0].actionConfidence, 0.9, accuracy: 1e-6)
        XCTAssertEqual(out[1].actionConfidence, 0)
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Global Constraints test command with `-only-testing:CourtVisionTests/ActionClassifierTests`. Expected: build FAILS — `value of type 'TrackedPlayer' has no member 'actionConfidence'`.

- [ ] **Step 3: Write the implementation**

`ios/CourtVision/Services/Engine/Moment.swift`:

```swift
import CoreGraphics

/// One tick of the pipeline on the frame clock. Everything downstream — the
/// overlay, the shot tracker, the session buffer, post-processing — reads
/// Moments; nothing downstream reads a detector directly.
struct Moment: Equatable {
    struct PlayerState: Equatable {
        let trackId: Int
        /// "A" / "B" once the team assigner runs (P3); nil until then.
        var team: String?
        /// Normalized image box, TOP-LEFT origin.
        var box: CGRect
        /// Ground-contact estimate in image space: pose ankles when the
        /// player was on the floor recently (P1), else the box bottom-center.
        var feet: CGPoint
        /// `feet` through the homography, court feet. Nil without a court fix.
        var xFt: Double?
        var yFt: Double?
        var action: PlayerAction
        /// Confidence of the state detection that set `action` (0 for `.none`).
        var actionConfidence: Float
        var number: String?
    }

    struct BallState: Equatable {
        var box: CGRect
        /// "ball" or "ball-in-basket" — the state rides the track.
        var label: String
        /// Ground projection of the ball center through the homography (the
        /// ball is in the air; this is where it is *over* the floor).
        var xFt: Double?
        var yFt: Double?
    }

    /// Frame presentation time, seconds — the one clock.
    let pts: Double
    var h: Homography?
    var rim: CGRect?
    var players: [PlayerState]
    var ball: BallState?
}
```

`PlayerTracker.swift` — in `TrackedPlayer` add the field after `action`, and in `update` reset it with the action:

```swift
    var action: PlayerAction = .none
    /// Confidence of the state box that set `action` this tick (0 for `.none`).
    var actionConfidence: Float = 0
```

```swift
        // Action is per-tick: reset here, Layer 3 re-annotates.
        for i in tracks.indices { tracks[i].action = .none; tracks[i].actionConfidence = 0 }
```

`ActionClassifier.classify` — where the best track is annotated:

```swift
            if let i = bestIndex {
                out[i].action = PlayerAction(label: state.label)
                out[i].actionConfidence = state.confidence
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Engine/Moment.swift ios/CourtVision/Services/Player/PlayerTracker.swift \
        ios/CourtVision/Services/Player/ActionClassifier.swift ios/CourtVisionTests/ActionClassifierTests.swift
git commit -m "feat(engine): Moment struct; action confidence rides the track"
```

---

### Task 2: One inference per tick — `detectAll` + pure per-module filters

**Files:**
- Modify: `ios/CourtVision/Services/ObjectDetector.swift:38-56`
- Modify: `ios/CourtVision/Services/Ball/BallFinder.swift:15-21`
- Modify: `ios/CourtVision/Services/Player/PlayerFinder.swift:24-28`
- Modify: `ios/CourtVision/Services/Rim/RimFinder.swift:34-52`
- Modify: `ios/CourtVision/Services/Player/NumberReader.swift:11-16`
- Test: `ios/CourtVisionTests/TickFiltersTests.swift` (new)

**Interfaces:**
- Produces (all pure except `detectAll`):
  - `ObjectDetector.detectAll(in: CVPixelBuffer, minConfidence: Float, maxCount: Int = 64) -> [Detection]` — every class, best-first.
  - `BallFinder.balls(from all: [Detection], maxCount: Int = 4) -> [Detection]`
  - `PlayerFinder.playerFamily(from all: [Detection], maxCount: Int = 24) -> [Detection]`
  - `RimFinder.merge(hoop: [CGRect], unified: [CGRect], maxCount: Int) -> [CGRect]` — left→right sorted union.
  - `NumberReader.read(regions: [CGRect], in: CVPixelBuffer) -> [(point: CGPoint, digits: String)]`
  - The old `detectBalls / detectAll(in:) / detectRims / read(in:)` wrappers stay (calibration screen uses `detectRims`).

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/TickFiltersTests.swift
import XCTest
@testable import CourtVision

/// The engine calls the unified model ONCE per tick; each module filters the
/// shared output. These are the filters.
final class TickFiltersTests: XCTestCase {
    private func det(_ label: String, _ conf: Float, x: CGFloat = 0.5) -> Detection {
        Detection(box: CGRect(x: x, y: 0.4, width: 0.06, height: 0.22), label: label, confidence: conf)
    }

    func testBallFilterKeepsBallFamilyAboveFloor() {
        let all = [det("ball", 0.9), det("ball-in-basket", 0.3), det("ball", 0.2), det("player", 0.9)]
        XCTAssertEqual(BallFinder.balls(from: all).map(\.label), ["ball", "ball-in-basket"])
    }

    func testPlayerFamilyFilterKeepsStatesDropsRefsAndLowConf() {
        let all = [det("player", 0.9), det("player-jump-shot", 0.5), det("referee", 0.9), det("player", 0.29)]
        XCTAssertEqual(PlayerFinder.playerFamily(from: all).map(\.label), ["player", "player-jump-shot"])
    }

    func testRimMergeUnionsNonOverlappingAndSortsLeftToRight() {
        let hoop = CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.06)
        let sameRim = CGRect(x: 0.61, y: 0.21, width: 0.1, height: 0.06)     // IoU > 0.3 → duplicate
        let sideHoop = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.06)
        let merged = RimFinder.merge(hoop: [hoop], unified: [sameRim, sideHoop], maxCount: 4)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], sideHoop)      // rim 1 = left
        XCTAssertEqual(merged[1], hoop)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/TickFiltersTests`. Expected: build FAILS — `type 'BallFinder' has no member 'balls'`.

- [ ] **Step 3: Write the implementation**

`ObjectDetector.swift` — replace `detect(labels:in:maxCount:minConfidence:)` with:

```swift
    /// Every labeled detection in one frame above `minConfidence`, best
    /// first. ONE call per engine tick — modules filter this list by label
    /// set instead of each running the model.
    func detectAll(in pixelBuffer: CVPixelBuffer, minConfidence: Float,
                   maxCount: Int = 64) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return Array((request.results as? [VNRecognizedObjectObservation] ?? [])
            .compactMap { obs -> Detection? in
                guard let id = obs.labels.first?.identifier, obs.confidence >= minConfidence else {
                    return nil
                }
                return Detection.fromVision(label: id, confidence: obs.confidence,
                                            visionBox: obs.boundingBox)
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxCount))
    }

    /// Labeled detections matching any of `labels` — a filter over
    /// `detectAll` for callers outside the engine tick (calibration).
    func detect(labels: Set<String>, in pixelBuffer: CVPixelBuffer,
                maxCount: Int, minConfidence: Float) -> [Detection] {
        Array(detectAll(in: pixelBuffer, minConfidence: minConfidence)
            .filter { labels.contains($0.label) }
            .prefix(maxCount))
    }
```

`BallFinder.swift` — replace `detectBalls`:

```swift
    static let labels: Set<String> = ["ball", "ball-in-basket", "Basketball", "basketball", "sports ball"]
    /// Lower floor than the rim: the ball is small, fast, motion-blurred; the
    /// continuity gate does the filtering.
    static let minConfidence: Float = 0.25

    /// Ball-family detections out of one tick's unified output, best first.
    /// `ball-in-basket` is a STATE of the ball — the label rides along so
    /// make/miss logic can read it from the track.
    static func balls(from all: [Detection], maxCount: Int = 4) -> [Detection] {
        Array(all.filter { labels.contains($0.label) && $0.confidence >= minConfidence }
            .prefix(maxCount))
    }

    static func detectBalls(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [Detection] {
        balls(from: ObjectDetector.ball?.detectAll(in: pixelBuffer, minConfidence: minConfidence) ?? [],
              maxCount: maxCount)
    }
```

`PlayerFinder.swift` — replace `detectAll(in:)`:

```swift
    static let minConfidence: Float = 0.30

    /// Player-family detections (base + state classes) out of one tick's
    /// unified output. Refs are excluded — they don't shoot.
    static func playerFamily(from all: [Detection], maxCount: Int = 24) -> [Detection] {
        Array(all.filter { playerLabels.contains($0.label) && $0.confidence >= minConfidence }
            .prefix(maxCount))
    }

    /// Raw labeled player-family detections, one call per tick (non-engine callers).
    static func detectAll(in pixelBuffer: CVPixelBuffer) -> [Detection] {
        playerFamily(from: ObjectDetector.player?.detectAll(in: pixelBuffer, minConfidence: minConfidence) ?? [])
    }
```

`RimFinder.swift` — replace `detectRims(in:maxCount:)` (keep `overlaps` and the color fallback):

```swift
    /// Union of the two models' rim candidates: unified boxes that don't
    /// overlap a HoopDetector box are appended, so one model's miss
    /// (occlusion, ANE contention) doesn't drop the rim. Sorted left → right
    /// (rim 1 = left).
    static func merge(hoop: [CGRect], unified: [CGRect], maxCount: Int) -> [CGRect] {
        var candidates = hoop
        for box in unified where !candidates.contains(where: { overlaps($0, box) }) {
            candidates.append(box)
        }
        return Array(candidates.prefix(maxCount)).sorted { $0.midX < $1.midX }
    }

    /// Detects up to `maxCount` rims (calibration path — the engine merges
    /// from its own tick instead). Orange-blob heuristic is the last fallback.
    static func detectRims(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [CGRect] {
        let hoop = ObjectDetector.hoop?.detect(labels: ["rim", "Basketball Hoop"], in: pixelBuffer,
                                               maxCount: maxCount, minConfidence: 0.30).map(\.box) ?? []
        let unified = ObjectDetector.unified?.detect(labels: ["rim"], in: pixelBuffer,
                                                     maxCount: maxCount, minConfidence: 0.30).map(\.box) ?? []
        let merged = merge(hoop: hoop, unified: unified, maxCount: maxCount)
        return merged.isEmpty ? detectRimsByColor(in: pixelBuffer, maxCount: maxCount) : merged
    }
```

`NumberReader.swift` — split `read(in:)`:

```swift
    static func read(in pixelBuffer: CVPixelBuffer, maxCount: Int = 8) -> [(point: CGPoint, digits: String)] {
        let regions = ObjectDetector.unified?.detect(labels: ["number"], in: pixelBuffer,
                                                     maxCount: maxCount, minConfidence: 0.3)
            .map(\.box) ?? []
        return read(regions: regions, in: pixelBuffer)
    }

    /// OCR inside already-detected `number` regions (the engine passes the
    /// tick's unified `number` boxes — no second model call).
    static func read(regions: [CGRect], in pixelBuffer: CVPixelBuffer) -> [(point: CGPoint, digits: String)] {
        guard !regions.isEmpty else { return [] }
        // … existing body from `var results` to `return results`, unchanged …
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **` (all existing tests + `TickFiltersTests`).

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/ObjectDetector.swift ios/CourtVision/Services/Ball/BallFinder.swift \
        ios/CourtVision/Services/Player/PlayerFinder.swift ios/CourtVision/Services/Rim/RimFinder.swift \
        ios/CourtVision/Services/Player/NumberReader.swift ios/CourtVisionTests/TickFiltersTests.swift
git commit -m "refactor(detect): detectAll once per tick; modules filter the shared output"
```

---

### Task 3: `RimTracker` — the rim state machine, out of the view and under test

**Files:**
- Create: `ios/CourtVision/Services/Rim/RimTracker.swift`
- Test: `ios/CourtVisionTests/RimTrackerTests.swift`

**Interfaces:**
- Consumes: `RimFinder.pickRim(candidates:near:within:)`.
- Produces:
  ```swift
  struct RimTracker: Equatable {
      enum State: Equatable { case tracking, reacquiring }
      private(set) var state: State
      private(set) var rim: CGRect?               // padded 15%
      var anchors: [String: CGPoint]              // per attacking team
      private(set) var lastCandidates: [CGRect]
      private(set) var lastReacquirePts: Double?  // when reacquire last began
      init(rim: CGRect? = nil, anchors: [String: CGPoint] = [:])
      mutating func update(candidates: [CGRect], attackingTeam: String, pts: Double)
      mutating func designate(at point: CGPoint, attackingTeam: String, pts: Double)
      static func pad(_ r: CGRect) -> CGRect
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/RimTrackerTests.swift
import XCTest
@testable import CourtVision

final class RimTrackerTests: XCTestCase {
    private let hoop = CGRect(x: 0.45, y: 0.20, width: 0.10, height: 0.06)
    private let sideHoop = CGRect(x: 0.05, y: 0.15, width: 0.10, height: 0.06)

    func testAnchorGateKeepsTheDesignatedHoop() {
        var t = RimTracker()
        t.update(candidates: [sideHoop, hoop], attackingTeam: "A", pts: 0)   // no anchor → first
        XCTAssertEqual(t.rim?.midX ?? 0, sideHoop.midX, accuracy: 1e-9)
        t.designate(at: CGPoint(x: 0.5, y: 0.23), attackingTeam: "A", pts: 1) // snaps to hoop
        XCTAssertEqual(t.rim?.midX ?? 0, hoop.midX, accuracy: 1e-9)
        XCTAssertEqual(t.anchors["A"], CGPoint(x: 0.5, y: 0.23))
        t.update(candidates: [sideHoop], attackingTeam: "A", pts: 2)          // side hoop alone must not steal
        XCTAssertEqual(t.rim?.midX ?? 0, hoop.midX, accuracy: 1e-9)
        XCTAssertEqual(t.state, .tracking)
    }

    func testOcclusionToleranceThenReacquireAndRelock() {
        var t = RimTracker()
        t.update(candidates: [hoop], attackingTeam: "A", pts: 0)
        for s in 1...4 { t.update(candidates: [], attackingTeam: "A", pts: Double(s)) }
        XCTAssertEqual(t.state, .tracking)          // 4.0 s of occlusion is tolerated
        t.update(candidates: [], attackingTeam: "A", pts: 4.5)
        XCTAssertEqual(t.state, .reacquiring)
        XCTAssertEqual(t.lastReacquirePts, 4.5)
        t.update(candidates: [hoop], attackingTeam: "A", pts: 5)
        XCTAssertEqual(t.state, .reacquiring)       // one steady tick
        t.update(candidates: [hoop], attackingTeam: "A", pts: 6)
        XCTAssertEqual(t.state, .tracking)          // two → locked again
    }

    func testBigJumpTriggersReacquire() {
        var t = RimTracker()
        t.update(candidates: [hoop], attackingTeam: "A", pts: 0)
        // Inside the 0.2 continuity gate but beyond the 0.15 jump threshold: camera panning.
        t.update(candidates: [hoop.offsetBy(dx: 0.18, dy: 0)], attackingTeam: "A", pts: 1)
        XCTAssertEqual(t.state, .reacquiring)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/RimTrackerTests`. Expected: build FAILS — `cannot find 'RimTracker' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// ios/CourtVision/Services/Rim/RimTracker.swift
import CoreGraphics

/// Rim continuity state machine (RIM MODULE), extracted from the record
/// screen so it runs on the engine clock and under test. A tap per end
/// ("anchor") says "THIS hoop, not the side baskets"; detections may refine
/// the rim locally, never move it elsewhere.
struct RimTracker: Equatable {
    enum State: Equatable { case tracking, reacquiring }

    private(set) var state: State = .tracking
    /// Rim currently locked on (normalized, top-left origin, padded 15%).
    private(set) var rim: CGRect?
    /// Tap-designated rim spot per end, keyed by attacking team.
    var anchors: [String: CGPoint]
    /// Candidates from the last tick — a tap snaps to the nearest one.
    private(set) var lastCandidates: [CGRect] = []
    /// pts at which the last reacquire began (nil = never). Consumers use it
    /// to know whether a homography from before that instant still applies.
    private(set) var lastReacquirePts: Double?
    private var lastSeenPts: Double?
    private var stableTicks = 0

    /// Seconds without a sighting before reacquire — players occlude the rim
    /// constantly, a contested possession must not drop the track.
    var occlusionTolerance: Double = 4.0
    /// Rim-center jump (fraction of frame) that means the camera is panning.
    var jumpThreshold: CGFloat = 0.15

    init(rim: CGRect? = nil, anchors: [String: CGPoint] = [:]) {
        self.rim = rim
        self.anchors = anchors
    }

    /// One rim tick (≈1 Hz). `attackingTeam` selects the anchor.
    mutating func update(candidates: [CGRect], attackingTeam: String, pts: Double) {
        lastCandidates = candidates
        if lastSeenPts == nil { lastSeenPts = pts }
        switch state {
        case .tracking:
            let anchor = rim.map { CGPoint(x: $0.midX, y: $0.midY) } ?? anchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: candidates, near: anchor,
                                         within: anchor != nil ? 0.2 : nil) {
                let padded = Self.pad(r)
                if let current = rim,
                   hypot(padded.midX - current.midX, padded.midY - current.midY) > jumpThreshold {
                    beginReacquire(at: pts)          // rim jumped — camera moving
                } else {
                    lastSeenPts = pts
                    rim = padded
                }
            } else if pts - (lastSeenPts ?? pts) > occlusionTolerance {
                beginReacquire(at: pts)              // rim gone — camera swinging to other end
            }
        case .reacquiring:
            // Prefer the other end's anchor — that's the hoop we swing toward.
            let other = attackingTeam == "A" ? "B" : "A"
            let target = anchors[other] ?? anchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: candidates, near: target,
                                         within: target != nil ? 0.25 : nil) {
                lastSeenPts = pts
                rim = Self.pad(r)
                stableTicks += 1
                if stableTicks >= 2 { state = .tracking }   // steady two ticks → locked
            } else {
                stableTicks = 0
            }
        }
    }

    /// Tap = "track THIS hoop": snap to the nearest candidate within 12% of
    /// the frame, else a default box; remember the spot as this end's anchor;
    /// resume tracking on it immediately.
    mutating func designate(at point: CGPoint, attackingTeam: String, pts: Double) {
        let snapped = RimFinder.pickRim(candidates: lastCandidates, near: point, within: 0.12)
        rim = snapped.map(Self.pad)
            ?? CGRect(x: point.x - 0.05, y: point.y - 0.03, width: 0.10, height: 0.06)
        anchors[attackingTeam] = point
        lastSeenPts = pts
        state = .tracking
        stableTicks = 0
    }

    private mutating func beginReacquire(at pts: Double) {
        state = .reacquiring
        stableTicks = 0
        lastReacquirePts = pts
    }

    static func pad(_ r: CGRect) -> CGRect {
        r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `RimTrackerTests` 3/3.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Rim/RimTracker.swift ios/CourtVisionTests/RimTrackerTests.swift
git commit -m "feat(rim): RimTracker — continuity state machine on the engine clock"
```

---

### Task 4: `CourtEstimator` — the continuous court estimate, out of the view

**Files:**
- Create: `ios/CourtVision/Services/Court/CourtEstimator.swift`
- Test: `ios/CourtVisionTests/CourtEstimatorTests.swift`

**Interfaces:**
- Consumes: `CourtFinder.bestQuad`, `CourtFinder.scoreCourtAssignments`, `Homography(from:to:)`, `Calibration`.
- Produces:
  ```swift
  struct CourtEstimator {
      private(set) var h: Homography?
      private(set) var quad: [CGPoint]            // last accepted image quad
      private(set) var courtPoints: [CGPoint]     // court-feet targets parallel to quad
      private(set) var fitFt: Double?             // rim-projection error of the accepted fit
      init(calibration: Calibration?)
      /// true = court jumped far in game mode → caller flips the attacking team
      mutating func update(quadCandidates: [[CGPoint]], rim: CGRect?, isGame: Bool, pts: Double) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/CourtEstimatorTests.swift
import XCTest
@testable import CourtVision

final class CourtEstimatorTests: XCTestCase {
    /// Image quad in landmark order [near-left, far-left, near-right, far-right].
    /// Under the "left edge is the baseline" assignment, image x spans court
    /// depth (0…47 ft) and image y (0.9→0.1) spans court width (0…50 ft).
    private let quad = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.1, y: 0.1),
                        CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1)]
    /// Rim box whose center projects to the hoop (25, 5.25) under that assignment.
    private let rim = CGRect(x: 0.16, y: 0.48, width: 0.06, height: 0.04)

    func testAcceptsFitAndProjectsFeet() {
        var c = CourtEstimator(calibration: nil)
        XCTAssertNil(c.h)
        XCTAssertFalse(c.update(quadCandidates: [quad], rim: rim, isGame: false, pts: 0))
        XCTAssertNotNil(c.h)
        XCTAssertLessThan(c.fitFt ?? 99, 1)
        let feet = c.h!.apply(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(feet.x), 25, accuracy: 0.5)
        XCTAssertEqual(Double(feet.y), 23.5, accuracy: 0.5)
    }

    func testNoRimOrBadFitKeepsPreviousEstimate() {
        var c = CourtEstimator(calibration: nil)
        _ = c.update(quadCandidates: [quad], rim: rim, isGame: false, pts: 0)
        let h0 = c.h
        _ = c.update(quadCandidates: [quad], rim: nil, isGame: false, pts: 1)
        XCTAssertEqual(c.h, h0)
        // Rim far from any plausible hoop position → every assignment fails the 15 ft gate.
        _ = c.update(quadCandidates: [quad], rim: CGRect(x: 0.5, y: 0.5, width: 0.06, height: 0.04),
                     isGame: false, pts: 2)
        XCTAssertEqual(c.h, h0)
    }

    func testFarJumpFlipsOnceInGameModeWithCooldown() {
        let shifted = quad.map { CGPoint(x: $0.x, y: $0.y - 0.3) }   // seeded from a different pan
        let cal = Calibration(homography: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                              imagePoints: shifted.map { [Double($0.x), Double($0.y)] },
                              courtPoints: [])
        var c = CourtEstimator(calibration: cal)
        XCTAssertTrue(c.update(quadCandidates: [quad], rim: rim, isGame: true, pts: 0))    // jump → flip
        XCTAssertFalse(c.update(quadCandidates: [quad], rim: rim, isGame: true, pts: 1))   // same quad
        // Practice mode never flips, even on a jump.
        var p = CourtEstimator(calibration: cal)
        XCTAssertFalse(p.update(quadCandidates: [quad], rim: rim, isGame: false, pts: 0))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/CourtEstimatorTests`. Expected: build FAILS — `cannot find 'CourtEstimator' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// ios/CourtVision/Services/Court/CourtEstimator.swift
import CoreGraphics

/// Continuous court estimate (COURT MODULE) on the engine clock: each slow
/// tick the rectangle candidates are scored against the tracked rim and the
/// best fit replaces the homography. Never a hard lock — the camera pans all
/// game. In game mode a far quad jump = the camera swung to the other hoop.
struct CourtEstimator {
    private(set) var h: Homography?
    /// Last accepted image quad [near-left, far-left, near-right, far-right].
    private(set) var quad: [CGPoint]
    /// Court-feet targets parallel to `quad` (for persisting the calibration).
    private(set) var courtPoints: [CGPoint] = []
    /// Mean rim-projection error of the accepted fit, feet (nil = seeded only).
    private(set) var fitFt: Double?
    private var lastFlipPts: Double = -.infinity

    /// Accept a fit only when the rim projects within this many feet of the hoop.
    var maxFitFt: Double = 15
    /// Mean corner move (fraction of frame) that counts as "swung to the other end".
    var jumpDelta: CGFloat = 0.2
    /// Seconds between flips while the pan settles.
    var flipCooldown: Double = 5

    init(calibration: Calibration?) {
        h = calibration.flatMap { Homography(matrix: $0.homography) }
        quad = calibration?.imagePoints.compactMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        } ?? []
    }

    /// Returns true when the court jumped far enough to mean a possession
    /// switch (game mode only) — the caller flips the attacking team.
    mutating func update(quadCandidates: [[CGPoint]], rim: CGRect?, isGame: Bool, pts: Double) -> Bool {
        guard let rim,
              let best = CourtFinder.bestQuad(candidates: quadCandidates, rims: [rim], fullCourt: false),
              best.score <= maxFitFt,
              let pick = CourtFinder.scoreCourtAssignments(quad: best.quad, rims: [rim], fullCourt: false),
              let fit = Homography(from: best.quad, to: pick.courtPoints) else { return false }

        var flipped = false
        if isGame, !quad.isEmpty {
            let meanDelta = zip(best.quad, quad)
                .map { hypot($0.x - $1.x, $0.y - $1.y) }
                .reduce(0, +) / CGFloat(quad.count)
            if meanDelta > jumpDelta, pts - lastFlipPts > flipCooldown {
                flipped = true
                lastFlipPts = pts
            }
        }
        h = fit
        quad = best.quad
        courtPoints = pick.courtPoints
        fitFt = best.score
        return flipped
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `CourtEstimatorTests` 3/3.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Court/CourtEstimator.swift ios/CourtVisionTests/CourtEstimatorTests.swift
git commit -m "feat(court): CourtEstimator — continuous estimate on the engine clock"
```

---

### Task 5: `Engine` — one tick, one clock, one Moment

**Files:**
- Create: `ios/CourtVision/Services/Engine/Engine.swift`
- Test: `ios/CourtVisionTests/EngineTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4 (`Moment`, `detectAll`, filters, `RimTracker`, `CourtEstimator`), `BallTrack`, `PlayerTracker`, `ActionClassifier`, `PlayerFinder.corePlayers/states`, `NumberReader.read(regions:in:)`, `RimFinder.detectRimsByColor`.
- Produces:
  ```swift
  final class Engine {
      struct Config { var tickHz: Double = 8; var slowEvery: Int = 8; var numberEvery: Int = 4 }
      struct Detectors {
          var unified: (CVPixelBuffer) -> [Detection]
          var hoop: (CVPixelBuffer) -> [CGRect]
          var courtQuads: (CVPixelBuffer) -> [[CGPoint]]
          var numbers: ([CGRect], CVPixelBuffer) -> [(point: CGPoint, digits: String)]
          static let live: Detectors
      }
      var config: Config
      var attackingTeam: String
      let isGame: Bool
      private(set) var rim: RimTracker
      private(set) var court: CourtEstimator
      private(set) var lastMoment: Moment?
      private(set) var flippedThisTick: Bool
      var ballTrail: [BallTrack.Sample]
      init(config: Config = Config(), detectors: Detectors = .live, calibration: Calibration?, isGame: Bool, attackingTeam: String, rimAnchors: [String: CGPoint], initialRim: CGRect?)
      func shouldTick(at pts: Double, thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Bool
      func process(_ pixelBuffer: CVPixelBuffer, pts: Double) -> Moment
      func designateRim(at point: CGPoint)
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/EngineTests.swift
import CoreVideo
import XCTest
@testable import CourtVision

final class EngineTests: XCTestCase {
    private func blank() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }
    private func det(_ box: CGRect, _ label: String, _ conf: Float) -> Detection {
        Detection(box: box, label: label, confidence: conf)
    }
    // Same synthetic court as CourtEstimatorTests: feet at image (0.5, 0.5) → (25, 23.5) ft.
    private let quad = [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.1, y: 0.1),
                        CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.9, y: 0.1)]
    private let rim = CGRect(x: 0.16, y: 0.48, width: 0.06, height: 0.04)
    private let player = CGRect(x: 0.47, y: 0.28, width: 0.06, height: 0.22)   // bottom-center (0.5, 0.5)
    private let ball = CGRect(x: 0.6, y: 0.3, width: 0.03, height: 0.03)

    /// Reference box so a stored closure can count calls.
    private final class Counter { var n = 0 }

    private func engine(hoop counter: Counter = Counter(), isGame: Bool = false,
                        calibration: Calibration? = nil) -> Engine {
        let detectors = Engine.Detectors(
            unified: { _ in [self.det(self.player, "player", 0.9),
                             self.det(self.ball, "ball", 0.8),
                             self.det(self.rim, "rim", 0.9)] },
            hoop: { _ in counter.n += 1; return [] },
            courtQuads: { _ in [self.quad] },
            numbers: { _, _ in [] })
        return Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                      calibration: calibration, isGame: isGame, attackingTeam: "A",
                      rimAnchors: [:], initialRim: nil)
    }

    func testOneTickBuildsMomentWithRimCourtBallAndProjectedFeet() {
        let e = engine()
        let m = e.process(blank(), pts: 0)
        XCTAssertEqual(m.pts, 0)
        XCTAssertNotNil(m.rim)                     // slow lane ran on tick 1: unified rim → tracker
        XCTAssertNotNil(m.h)                       // quad scored against that rim
        XCTAssertEqual(m.players.count, 1)
        XCTAssertEqual(m.players[0].feet, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(m.players[0].xFt ?? 0, 25, accuracy: 0.5)
        XCTAssertEqual(m.players[0].yFt ?? 0, 23.5, accuracy: 0.5)
        XCTAssertEqual(m.ball?.label, "ball")
        XCTAssertEqual(e.lastMoment, m)
    }

    func testSlowLaneCadenceThrottleAndThermal() {
        let hoop = Counter()
        let e = engine(hoop: hoop)
        for i in 0..<16 { _ = e.process(blank(), pts: Double(i) / 8) }   // 2 s at 8 Hz
        XCTAssertEqual(hoop.n, 2)                                        // ticks 1 and 9
        // Last tick at 15/8 = 1.875 s.
        XCTAssertFalse(e.shouldTick(at: 1.9, thermal: .nominal))
        XCTAssertTrue(e.shouldTick(at: 2.0, thermal: .nominal))
        XCTAssertFalse(e.shouldTick(at: 2.0, thermal: .serious))         // halves to 4 Hz
        XCTAssertTrue(e.shouldTick(at: 2.125, thermal: .serious))
    }

    func testPlayerTrackToleranceScalesWithTickRate() {
        let e = engine()
        XCTAssertEqual(e.process(blank(), pts: 0).players[0].trackId, 1)
        XCTAssertEqual(e.playerMaxMissedTicks, 16)                       // 2 s × 8 Hz (was 4 ticks at 2 Hz)
    }

    func testCourtJumpFlipsAttackingTeamInGameMode() {
        let shifted = quad.map { CGPoint(x: $0.x, y: $0.y - 0.3) }
        let cal = Calibration(homography: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                              imagePoints: shifted.map { [Double($0.x), Double($0.y)] },
                              courtPoints: [])
        let e = engine(isGame: true, calibration: cal)
        _ = e.process(blank(), pts: 0)
        XCTAssertTrue(e.flippedThisTick)
        XCTAssertEqual(e.attackingTeam, "B")
    }

    func testDesignateRimSnapsAndAnchors() {
        let e = engine()
        _ = e.process(blank(), pts: 0)
        e.designateRim(at: CGPoint(x: 0.2, y: 0.5))       // within 0.12 of the unified rim → snaps
        XCTAssertEqual(e.rim.rim?.midX ?? 0, rim.midX, accuracy: 1e-9)
        XCTAssertEqual(e.rim.anchors["A"], CGPoint(x: 0.2, y: 0.5))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/EngineTests`. Expected: build FAILS — `cannot find 'Engine' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// ios/CourtVision/Services/Engine/Engine.swift
import CoreGraphics
import CoreVideo
import Foundation

/// The single-clock pipeline: ONE unified inference per tick keyed to the
/// frame's presentation time; the rim / ball / player / court modules are fed
/// from it and one `Moment` comes out. No module owns a loop or a clock.
///
/// Lanes: every tick → ball + players (+ numbers every `numberEvery` ticks);
/// every `slowEvery` ticks → HoopDetector ∪ unified rim, court rectangles.
/// Rims and courts don't move — the camera does.
final class Engine {
    struct Config {
        /// Ticks per second. Set from the P0 cost table (docs/EVAL.md); a
        /// serious/critical thermal state halves it.
        var tickHz: Double = 8
        /// Rim + court every N ticks (≈1 Hz at 8 Hz).
        var slowEvery: Int = 8
        /// Jersey OCR every N ticks (≈2 Hz at 8 Hz).
        var numberEvery: Int = 4
    }

    /// Detector seam: real models in the app, synthetic closures in tests.
    struct Detectors {
        var unified: (CVPixelBuffer) -> [Detection]
        var hoop: (CVPixelBuffer) -> [CGRect]
        var courtQuads: (CVPixelBuffer) -> [[CGPoint]]
        var numbers: ([CGRect], CVPixelBuffer) -> [(point: CGPoint, digits: String)]

        static let live = Detectors(
            unified: { ObjectDetector.unified?.detectAll(in: $0, minConfidence: 0.25) ?? [] },
            hoop: { ObjectDetector.hoop?.detect(labels: ["rim", "Basketball Hoop"], in: $0,
                                                maxCount: 4, minConfidence: 0.30).map(\.box) ?? [] },
            courtQuads: { CourtFinder.detectCourtQuadCandidates(in: $0) },
            numbers: { NumberReader.read(regions: $0, in: $1) })
    }

    var config: Config
    let detectors: Detectors
    let isGame: Bool
    /// Team attacking the hoop in frame; flips on a far court jump (game mode).
    var attackingTeam: String

    private(set) var rim: RimTracker
    private(set) var court: CourtEstimator
    private var ballTrack = BallTrack()
    private var playerTracker = PlayerTracker()
    private var tickCount = 0
    private var lastTickPts: Double = -.infinity
    private(set) var lastMoment: Moment?
    /// True when the last `process` flipped `attackingTeam`.
    private(set) var flippedThisTick = false
    /// `process` runs on the frame loop, `designateRim` on the main actor.
    private let lock = NSLock()

    var ballTrail: [BallTrack.Sample] { lock.withLock { ballTrack.samples } }
    /// Ticks a player track survives unmatched: 2 s at the tick rate.
    var playerMaxMissedTicks: Int { playerTracker.maxMissedTicks }

    init(config: Config = Config(), detectors: Detectors = .live,
         calibration: Calibration?, isGame: Bool, attackingTeam: String,
         rimAnchors: [String: CGPoint], initialRim: CGRect?) {
        self.config = config
        self.detectors = detectors
        self.isGame = isGame
        self.attackingTeam = attackingTeam
        rim = RimTracker(rim: initialRim, anchors: rimAnchors)
        court = CourtEstimator(calibration: calibration)
        playerTracker.maxMissedTicks = Int((2.0 * config.tickHz).rounded())
    }

    /// Whether a frame at `pts` is due: throttle to `tickHz`, halved when the
    /// device is hot (modules are never dropped, only the rate).
    func shouldTick(at pts: Double,
                    thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Bool {
        let hz = (thermal == .serious || thermal == .critical) ? config.tickHz / 2 : config.tickHz
        return pts - lastTickPts >= 1.0 / hz - 1e-6
    }

    /// One tick. Call only when `shouldTick` said so.
    func process(_ pixelBuffer: CVPixelBuffer, pts: Double) -> Moment {
        lock.lock(); defer { lock.unlock() }
        lastTickPts = pts
        tickCount += 1
        flippedThisTick = false

        let all = detectors.unified(pixelBuffer)

        // ---- slow lane: rim + court ------------------------------------
        if tickCount % config.slowEvery == 1 || config.slowEvery == 1 {
            let unifiedRims = all.filter { $0.label == "rim" && $0.confidence >= 0.30 }.map(\.box)
            var candidates = RimFinder.merge(hoop: detectors.hoop(pixelBuffer),
                                             unified: unifiedRims, maxCount: 4)
            if candidates.isEmpty {
                candidates = RimFinder.detectRimsByColor(in: pixelBuffer, maxCount: 4)
            }
            rim.update(candidates: candidates, attackingTeam: attackingTeam, pts: pts)
            if court.update(quadCandidates: detectors.courtQuads(pixelBuffer), rim: rim.rim,
                            isGame: isGame, pts: pts) {
                attackingTeam = attackingTeam == "A" ? "B" : "A"
                flippedThisTick = true
            }
        }

        // ---- ball: continuity gate scales with the gap since last sighting
        let anchor = ballTrack.last?.point
        let gap = ballTrack.last.map { pts - $0.at.timeIntervalSinceReferenceDate } ?? .infinity
        let reach: CGFloat? = anchor == nil ? nil : min(0.15 + 0.35 * gap, 0.5)
        let chosen = BallFinder.pickBall(candidates: BallFinder.balls(from: all), near: anchor, within: reach)
        ballTrack.update(with: chosen, at: Date(timeIntervalSinceReferenceDate: pts))

        // ---- players: detect → track → numbers → classify ---------------
        let family = PlayerFinder.playerFamily(from: all)
        playerTracker.update(with: PlayerFinder.corePlayers(family))
        if tickCount % config.numberEvery == 0 {
            let regions = all.filter { $0.label == "number" && $0.confidence >= 0.30 }.map(\.box)
            if !regions.isEmpty { playerTracker.assign(numbers: detectors.numbers(regions, pixelBuffer)) }
        }
        let tracks = ActionClassifier.classify(states: PlayerFinder.states(family),
                                               tracks: playerTracker.tracks)

        // ---- moment ------------------------------------------------------
        let h = court.h
        func toCourt(_ p: CGPoint) -> (Double?, Double?) {
            guard let h else { return (nil, nil) }
            let q = h.apply(p)
            return (Double(q.x), Double(q.y))
        }
        let moment = Moment(
            pts: pts, h: h, rim: rim.rim,
            players: tracks.map { t in
                let feet = CGPoint(x: t.box.midX, y: t.box.maxY)
                let (x, y) = toCourt(feet)
                return Moment.PlayerState(trackId: t.id, team: nil, box: t.box, feet: feet,
                                          xFt: x, yFt: y, action: t.action,
                                          actionConfidence: t.actionConfidence, number: t.number)
            },
            ball: ballTrack.last.map { s in
                let (x, y) = toCourt(s.point)
                return Moment.BallState(box: s.box, label: s.label, xFt: x, yFt: y)
            })
        lastMoment = moment
        return moment
    }

    /// Tap on the preview = "track THIS hoop" (see `RimTracker.designate`).
    func designateRim(at point: CGPoint) {
        lock.withLock {
            rim.designate(at: point, attackingTeam: attackingTeam, pts: max(lastTickPts, 0))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `EngineTests` 5/5.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Engine/Engine.swift ios/CourtVisionTests/EngineTests.swift
git commit -m "feat(engine): one inference per tick on the frame clock → Moment"
```

---

### Task 6: Wire the record screen to the engine (RecordModel → thin ViewModel)

**Files:**
- Modify: `ios/CourtVision/Services/CameraService.swift:33-40` (`frames` → `makeFrames()`)
- Modify: `ios/CourtVision/Views/RecordView.swift` (overlay types, status line, and the whole `RecordModel` class)

**Interfaces:**
- Consumes: `Engine`, `Moment`, `RimTracker.State`, `ManualRimDetector.shared`, `SupabaseService.saveCalibration`.
- Produces: `CameraService.makeFrames() -> AsyncStream<CMSampleBuffer>`; `RecordModel` published: `attackingTeam`, `trackState: RimTracker.State`, `trackingNote`, `courtStatus`, `ballStatus`, `ballTrail`, `playerStatus`, `players: [Moment.PlayerState]`, `tickStatus`. Methods: `start(session:calibration:camera:attackingTeam:rimAnchors:)`, `stop()`, `toggleTeam()`, `designateRim(at:)`. Task 13 extends `publish`.

- [ ] **Step 1: `CameraService.makeFrames()`** — replace the `frames` lazy var:

```swift
    /// Live camera frames for ONE consumer (the engine loop). Each call
    /// finishes the previous stream, so a new recording gets a fresh stream
    /// instead of a dead one. Buffers only the newest frames — a consumer
    /// that falls behind drops frames instead of building latency.
    func makeFrames() -> AsyncStream<CMSampleBuffer> {
        continuation?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { [weak self] continuation in
            self?.continuation = continuation
        }
    }
```

- [ ] **Step 2: Rewrite `RecordModel`** — replace the whole `RecordModel` class at the bottom of `RecordView.swift` (from the doc comment `/// Rim + court tracking only …` to the end of file) with:

```swift
/// Thin view-model over the `Engine`: pumps camera frames through it on the
/// engine clock, publishes each `Moment` for the overlay, keeps the server's
/// calibration current. Turning Moments into shot events is Task 13.
@MainActor
final class RecordModel: ObservableObject {
    @Published var attackingTeam = "A"
    @Published var trackState: RimTracker.State = .tracking
    @Published var trackingNote: String?
    @Published var courtStatus = "Court: waiting for first fix…"
    @Published var ballStatus = "Ball: searching…"
    /// Recent ball positions for the overlay trail (newest last).
    @Published var ballTrail: [BallTrack.Sample] = []
    @Published var playerStatus = "Players: —"
    @Published var players: [Moment.PlayerState] = []
    /// Engine cost per tick — the P0 cost table and the thermal watch.
    @Published var tickStatus = ""

    private var engine: Engine?
    private var session: Session?
    private var loopTask: Task<Void, Never>?
    private var lastPersistPts: Double = -.infinity

    func toggleTeam() {
        attackingTeam = attackingTeam == "A" ? "B" : "A"
        engine?.attackingTeam = attackingTeam
    }

    /// Tap = "track THIS hoop".
    func designateRim(at point: CGPoint) {
        guard let engine else { return }
        engine.designateRim(at: point)
        if let rim = engine.rim.rim { ManualRimDetector.shared.rimRects = [rim] }
        trackState = .tracking
        trackingNote = nil
    }

    func start(session: Session, calibration: Calibration,
               camera: CameraService, attackingTeam: String = "A",
               rimAnchors: [String: CGPoint] = [:]) {
        guard loopTask == nil else { return }
        self.session = session
        self.attackingTeam = attackingTeam
        let engine = Engine(calibration: calibration, isGame: session.mode == .game,
                            attackingTeam: attackingTeam, rimAnchors: rimAnchors,
                            initialRim: ManualRimDetector.shared.rimRects.first)
        self.engine = engine
        if engine.court.h != nil { courtStatus = "Court: fixed from calibration" }

        let frames = camera.makeFrames()
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await sample in frames {
                if Task.isCancelled { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard engine.shouldTick(at: pts),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let t0 = CFAbsoluteTimeGetCurrent()
                let moment = engine.process(pixelBuffer, pts: pts)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                await self?.publish(moment, tickMs: ms)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func publish(_ m: Moment, tickMs: Double) {
        guard let engine else { return }
        players = m.players
        ballTrail = engine.ballTrail
        let ballFresh = ballTrail.last.map { m.pts - $0.at.timeIntervalSinceReferenceDate < 0.5 } ?? false
        ballStatus = ballFresh ? "Ball: ✓" : "Ball: searching…"
        playerStatus = "Players: \(m.players.count)"
        tickStatus = String(format: "%.0f ms", tickMs)
        if engine.attackingTeam != attackingTeam { attackingTeam = engine.attackingTeam }
        trackState = engine.rim.state
        trackingNote = trackState == .reacquiring ? "Re-acquiring hoop… hold steady" : nil
        if let rim = m.rim, ManualRimDetector.shared.rimRects != [rim] {
            ManualRimDetector.shared.rimRects = [rim]
        }
        if let fit = engine.court.fitFt {
            courtStatus = "Court: live (fit \(Int(fit.rounded())) ft)"
        }
        if let h = m.h, m.pts - lastPersistPts > 10 {
            lastPersistPts = m.pts
            persistCalibration(corners: engine.court.quad, courtPoints: engine.court.courtPoints, h: h)
        }
    }

    /// Keep the server's session calibration current (fire-and-forget).
    private func persistCalibration(corners: [CGPoint], courtPoints: [CGPoint], h: Homography) {
        guard let session else { return }
        let calibration = Calibration(
            homography: h.m,
            imagePoints: corners.map { [Double($0.x), Double($0.y)] },
            courtPoints: courtPoints.map { [Double($0.x), Double($0.y)] }
        )
        Task {
            try? await SupabaseService.shared.saveCalibration(sessionId: session.id, calibration)
        }
    }
}
```

Also at the top of `RecordView.swift` add `import CoreMedia` (for `CMSampleBufferGetPresentationTimeStamp`), and change the status line to include the tick cost:

```swift
                    Text("\(model.ballStatus) · \(model.playerStatus) · \(model.courtStatus) · \(model.tickStatus)")
```

The overlay code needs no edits: `model.players` elements still expose `box`, `number`, `action`; `model.trackState == .tracking` now compares `RimTracker.State`. Delete the old `RecordModel` entirely (its `TrackState` enum, the three loops, `handleTrack`, `handleBall`, `beginReacquire`). Update the top-of-file doc comment: replace the sentence "Ball trajectory / shot detection is intentionally ABSENT for now" with "All CV runs in `Engine` (one tick per frame slot); this view only draws Moments."

- [ ] **Step 3: Build + run all tests**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`. Fix any compile error from the removed types (search the file for `TrackState`, `handleTrack`, `startBallTracking`, `startPlayerTracking` — none may remain).

- [ ] **Step 4: Device parity check** (manual, iPhone) — build to the device, start a practice session in the gym or against a hoop poster:
  - rim box appears and holds; tap another hoop → box snaps and stays there;
  - ball trail draws during a throw; player boxes with numbers/action badges appear;
  - status line shows `Court: live (fit N ft)` once the court is found and a `NN ms` tick cost;
  - cover the rim 3 s → no reacquire; 5 s → "Re-acquiring hoop…"; uncover → locks after two ticks;
  - `End Session` returns to the summary and a second session starts a working camera loop (fresh stream).
  If any of these regressed versus the last `dev` build, fix in this task before committing.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/CameraService.swift ios/CourtVision/Views/RecordView.swift
git commit -m "refactor(record): RecordModel is a thin ViewModel over Engine; frames per consumer"
```

---

### Task 7: Tick cost table → choose `tickHz`; document the new cadence model

**Files:**
- Create: `docs/EVAL.md`
- Modify: `ios/CourtVision/Services/Engine/Engine.swift` (`Config.tickHz` default = the chosen value)
- Modify: `docs/MODEL_PIPELINE.md` §1 table + "Cadence discipline" bullet; `docs/INSTRUCTION.md` §1 table + cadence sentence

**Interfaces:** none new. Produces the measured default `Engine.Config.tickHz`.

- [ ] **Step 1: Create `docs/EVAL.md`** with the P0 table (fill the rows as you measure):

```markdown
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
| YYYY-MM-DD | iPhone … | … | 8 | 8 | | | |
| YYYY-MM-DD | iPhone … | … | 10 | 10 | | | |

Chosen default: `Engine.Config.tickHz = …` (highest rate whose ms/tick stays
under 1000/tickHz with headroom and no serious thermal state at 10 min).

## Shot events (P1)

Filled by `tools/eval_events.py --append docs/EVAL.md` (Task 15).

| date | commit | clip | attempts GT | P | R | make/miss acc | loc median ft | loc p90 ft |
|---|---|---|---|---|---|---|---|---|
```

- [ ] **Step 2: Measure** — three device runs, editing `Engine.Config` defaults per row (`tickHz`/`slowEvery` = 5/5, 8/8, 10/10; `numberEvery` = tickHz/2 rounded), rebuild, record 10 min each, fill the rows. Then set `Config` defaults to the chosen row and write the "Chosen default" line.

- [ ] **Step 3: Update the docs' cadence model.** In `docs/MODEL_PIPELINE.md` §1 replace the table + "Cadence discipline" bullet with:

```markdown
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
```

In `docs/INSTRUCTION.md` §1 replace the cadence table and the "Cadence discipline: …" sentence with the same table and the same two bullets verbatim. Add one bullet to §5 (Future shot pipeline): "Consumers read `Moment`s from `Engine`; the plug-in point is `RecordModel.publish`."

- [ ] **Step 4: Run tests** (defaults changed) — Global Constraints command. Expected: `** TEST SUCCEEDED **` (`EngineTests` construct their own `Config`, so they are rate-independent).

- [ ] **Step 5: Commit, merge P0**

```bash
git add docs/EVAL.md docs/MODEL_PIPELINE.md docs/INSTRUCTION.md ios/CourtVision/Services/Engine/Engine.swift
git commit -m "docs(engine): tick cost table, chosen tickHz, cadence model"
git checkout dev && git merge --no-ff engine -m "merge: engine (P0) — single-clock pipeline"
```

P0 gate: tests green; device parity confirmed (Task 6 step 4); cost table filled and `tickHz` chosen.

---

## Phase P1 — Shots (branch `shots`)

### Task 8: `PoseReader` + `FeetHistory` — the shooter's ground-contact point

**Files:**
- Create: `ios/CourtVision/Services/Player/PoseReader.swift`
- Delete: `ios/CourtVision/Services/Player/PoseService.swift` (unreferenced V1 leftover)
- Test: `ios/CourtVisionTests/FeetHistoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PoseReader {
      struct Sample: Equatable { let pts: Double; let ankleMid: CGPoint? }   // image space, top-left origin
      static func read(in: CVPixelBuffer, roi box: CGRect, pts: Double) -> Sample?
      static func toFrame(_ p: CGPoint, roi: CGRect) -> CGPoint            // ROI-relative (Vision) → frame (Vision)
  }
  struct FeetHistory: Equatable {
      var window: Double = 1.0
      mutating func add(_ s: PoseReader.Sample, track: Int, now pts: Double)
      mutating func prune(keeping live: Set<Int>)
      func groundContact(track: Int) -> CGPoint?
  }
  ```

- [ ] **Step 1: Branch, then write the failing tests** — `git checkout -b shots dev`:

```swift
// ios/CourtVisionTests/FeetHistoryTests.swift
import XCTest
@testable import CourtVision

final class FeetHistoryTests: XCTestCase {
    private func sample(_ pts: Double, y: CGFloat?) -> PoseReader.Sample {
        PoseReader.Sample(pts: pts, ankleMid: y.map { CGPoint(x: 0.5, y: $0) })
    }

    func testGroundContactIsLowestAnkleInWindow() {
        var f = FeetHistory()
        f.add(sample(0.0, y: 0.60), track: 3, now: 0.0)     // on the floor
        f.add(sample(0.3, y: 0.55), track: 3, now: 0.3)     // rising
        f.add(sample(0.5, y: 0.45), track: 3, now: 0.5)     // in the air
        XCTAssertEqual(f.groundContact(track: 3), CGPoint(x: 0.5, y: 0.60))
        XCTAssertNil(f.groundContact(track: 9))
    }

    func testWindowAndPrune() {
        var f = FeetHistory()
        f.add(sample(0.0, y: 0.60), track: 3, now: 0.0)
        f.add(sample(1.5, y: 0.50), track: 3, now: 1.5)     // the 0.0 sample ages out (window 1 s)
        XCTAssertEqual(f.groundContact(track: 3), CGPoint(x: 0.5, y: 0.50))
        f.add(sample(1.5, y: nil), track: 3, now: 1.5)      // no ankles seen: ignored for contact
        XCTAssertEqual(f.groundContact(track: 3), CGPoint(x: 0.5, y: 0.50))
        f.prune(keeping: [4])
        XCTAssertNil(f.groundContact(track: 3))
    }

    func testRoiToFrameMapping() {
        let roi = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)              // Vision space
        XCTAssertEqual(PoseReader.toFrame(CGPoint(x: 0.5, y: 0.5), roi: roi), CGPoint(x: 0.45, y: 0.3))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/FeetHistoryTests`. Expected: build FAILS — `cannot find 'FeetHistory' in scope`.

- [ ] **Step 3: Write the implementation** (and `git rm ios/CourtVision/Services/Player/PoseService.swift`)

```swift
// ios/CourtVision/Services/Player/PoseReader.swift
import CoreGraphics
import CoreVideo
import Vision

/// Body-pose evidence for ONE player box per tick (the possession / shooting
/// tracks only — never a full-frame pass). Feeds `FeetHistory` so the shot
/// location comes from the set point on the floor, not from a bbox bottom in
/// mid-air (ref 02's failure).
enum PoseReader {
    struct Sample: Equatable {
        let pts: Double
        /// Ankle midpoint (or the single visible ankle), normalized image
        /// coordinates, TOP-LEFT origin. Nil when no ankle is confident.
        let ankleMid: CGPoint?
    }

    /// Runs Vision body pose on `box` (normalized, top-left origin) only.
    static func read(in pixelBuffer: CVPixelBuffer, roi box: CGRect, pts: Double) -> Sample? {
        let padded = box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.1)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isEmpty else { return nil }
        // Vision ROI is bottom-left origin.
        let roi = CGRect(x: padded.origin.x, y: 1 - padded.origin.y - padded.height,
                         width: padded.width, height: padded.height)
        let request = VNDetectHumanBodyPoseRequest()
        request.regionOfInterest = roi
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        guard let obs = request.results?.first else { return nil }

        // Points come back normalized to the ROI (bottom-left origin); map to
        // the frame, then flip to top-left.
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 else { return nil }
            let f = toFrame(p.location, roi: roi)
            return CGPoint(x: f.x, y: 1 - f.y)
        }
        let l = point(.leftAnkle), r = point(.rightAnkle)
        let mid: CGPoint?
        if let l, let r { mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2) } else { mid = l ?? r }
        return Sample(pts: pts, ankleMid: mid)
    }

    /// ROI-relative normalized point → frame-normalized point (both Vision,
    /// bottom-left origin).
    static func toFrame(_ p: CGPoint, roi: CGRect) -> CGPoint {
        CGPoint(x: roi.origin.x + p.x * roi.width, y: roi.origin.y + p.y * roi.height)
    }
}

/// Per-track ring of pose samples. Answers "where were this player's feet
/// the last time they were on the floor" — the lowest ankle midpoint on
/// screen (max y) inside the window.
struct FeetHistory: Equatable {
    private var samples: [Int: [PoseReader.Sample]] = [:]
    /// Seconds of history kept per track (a jump shot's set point is < 1 s
    /// before the state class fires).
    var window: Double = 1.0

    mutating func add(_ s: PoseReader.Sample, track: Int, now pts: Double) {
        var list = samples[track, default: []]
        list.append(s)
        list.removeAll { pts - $0.pts > window }
        samples[track] = list
    }

    /// Drop history of tracks that no longer exist.
    mutating func prune(keeping live: Set<Int>) {
        samples = samples.filter { live.contains($0.key) }
    }

    func groundContact(track: Int) -> CGPoint? {
        samples[track]?.compactMap(\.ankleMid).max { $0.y < $1.y }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `FeetHistoryTests` 3/3, build clean without `PoseService.swift`.

- [ ] **Step 5: Commit**

```bash
git add -A ios/CourtVision/Services/Player/PoseReader.swift ios/CourtVision/Services/Player/PoseService.swift \
        ios/CourtVisionTests/FeetHistoryTests.swift
git commit -m "feat(player): PoseReader on the shooter ROI + FeetHistory ground contact"
```

---

### Task 9: Engine feeds pose → `Moment.feet` is the ground contact

**Files:**
- Modify: `ios/CourtVision/Services/Engine/Engine.swift` (`Detectors.pose`, feet history, feet in Moment)
- Test: `ios/CourtVisionTests/EngineTests.swift` (one test added; existing `Detectors(...)` literals gain the `pose:` argument)

**Interfaces:**
- Produces: `Engine.Detectors.pose: (CVPixelBuffer, CGRect, Double) -> PoseReader.Sample?` (`live` = `PoseReader.read(in:roi:pts:)`); `Moment.PlayerState.feet` = `FeetHistory.groundContact(track)` when available, else box bottom-center. Pose runs only for tracks whose action is `.possession`, `.jumpShot` or `.layupDunk`.

- [ ] **Step 1: Write the failing test** — add to `EngineTests` (and add `pose: { _, _, _ in nil }` to the two existing `Detectors(...)` literals so they compile once the field exists):

```swift
    func testFeetComeFromPoseGroundContactWhenShooting() {
        // Tick 1: possession on the floor (ankles low). Tick 2: jump shot in the air.
        var tick = 0
        let boxes = [CGRect(x: 0.47, y: 0.28, width: 0.06, height: 0.22),      // bottom 0.50
                     CGRect(x: 0.47, y: 0.20, width: 0.06, height: 0.22)]      // bottom 0.42 (airborne)
        let states = ["player-in-possession", "player-jump-shot"]
        let detectors = Engine.Detectors(
            unified: { _ in [self.det(boxes[tick], "player", 0.9), self.det(boxes[tick], states[tick], 0.8)] },
            hoop: { _ in [] }, courtQuads: { _ in [] }, numbers: { _, _ in [] },
            pose: { _, box, pts in PoseReader.Sample(pts: pts, ankleMid: CGPoint(x: box.midX, y: box.maxY - 0.01)) })
        let e = Engine(config: .init(tickHz: 8, slowEvery: 8, numberEvery: 4), detectors: detectors,
                       calibration: nil, isGame: false, attackingTeam: "A", rimAnchors: [:], initialRim: nil)
        _ = e.process(blank(), pts: 0)
        tick = 1
        let m = e.process(blank(), pts: 0.125)
        XCTAssertEqual(m.players[0].action, .jumpShot)
        XCTAssertEqual(m.players[0].feet.y, 0.49, accuracy: 1e-6)     // the floor sample, not the airborne box
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/EngineTests`. Expected: build FAILS — `extra argument 'pose' in call`.

- [ ] **Step 3: Write the implementation** — in `Engine.swift`:

Add to `Detectors`:
```swift
        var pose: (CVPixelBuffer, CGRect, Double) -> PoseReader.Sample?
```
and to `live`: `pose: { PoseReader.read(in: $0, roi: $1, pts: $2) }`.

Add state: `private var feet = FeetHistory()`.

In `process`, after `let tracks = ActionClassifier.classify(...)` and before `// ---- moment`:
```swift
        // ---- pose: only the ball handler / shooter, ROI only --------------
        for t in tracks where t.action == .possession || t.action == .jumpShot || t.action == .layupDunk {
            if let s = detectors.pose(pixelBuffer, t.box, pts) { feet.add(s, track: t.id, now: pts) }
        }
        feet.prune(keeping: Set(tracks.map(\.id)))
```
and in the players map replace the feet line:
```swift
                let feet = self.feet.groundContact(track: t.id) ?? CGPoint(x: t.box.midX, y: t.box.maxY)
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `EngineTests` 6/6.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Engine/Engine.swift ios/CourtVisionTests/EngineTests.swift
git commit -m "feat(engine): pose on the shooter ROI; Moment.feet = ground contact"
```

---

### Task 10: `ShotEventTracker` — attempts from Moments (ref 02)

**Files:**
- Create: `ios/CourtVision/Services/Shot/ShotEventTracker.swift`
- Modify: `ios/CourtVision/Services/Player/PlayerTracker.swift:6` (`PlayerAction` gains `String, Codable`)
- Test: `ios/CourtVisionTests/ShotEventTrackerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ShotEvent: Equatable, Codable {
      enum Kind: String, Codable { case attempt, made, missed }
      var kind: Kind; let pts: Double; var resolvedPts: Double?; let trackId: Int
      let action: PlayerAction; let feet: CGPoint; let court: CGPoint?; let confidence: Float
  }
  struct ShotEventTracker: Equatable {
      var minStartTicks = 2; var windowSec = 3.0; var cooldownSec = 2.0; var rimReach: CGFloat = 1.5
      mutating func update(_ m: Moment) -> [ShotEvent]
      static func ballInBasket(_ m: Moment, rimReach: CGFloat) -> Bool
  }
  ```
  `enum PlayerAction: String, Codable, Equatable` (raw values = case names).

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/ShotEventTrackerTests.swift
import XCTest
@testable import CourtVision

final class ShotEventTrackerTests: XCTestCase {
    private let rim = CGRect(x: 0.45, y: 0.20, width: 0.10, height: 0.06)

    private func moment(_ pts: Double, action: PlayerAction, ball: String? = nil,
                        ballAtRim: Bool = true, h: Homography? = nil) -> Moment {
        let ballBox = ballAtRim ? CGRect(x: 0.485, y: 0.215, width: 0.03, height: 0.03)
                                : CGRect(x: 0.10, y: 0.80, width: 0.03, height: 0.03)
        let p = Moment.PlayerState(trackId: 7, team: nil,
                                   box: CGRect(x: 0.5, y: 0.4, width: 0.06, height: 0.22),
                                   feet: CGPoint(x: 0.53, y: 0.62), xFt: nil, yFt: nil,
                                   action: action, actionConfidence: 0.8, number: nil)
        return Moment(pts: pts, h: h, rim: rim, players: [p],
                      ball: ball.map { Moment.BallState(box: ballBox, label: $0, xFt: nil, yFt: nil) })
    }

    func testAttemptOpensAfterTwoShootingTicksAndIsMadeByBallInBasketAtRim() {
        var t = ShotEventTracker()
        XCTAssertTrue(t.update(moment(0.000, action: .jumpShot)).isEmpty)          // one tick: not yet
        let opened = t.update(moment(0.125, action: .jumpShot))
        XCTAssertEqual(opened.map(\.kind), [.attempt])
        XCTAssertEqual(opened[0].trackId, 7)
        XCTAssertEqual(opened[0].feet, CGPoint(x: 0.53, y: 0.62))
        XCTAssertNil(opened[0].court)                                              // no H
        XCTAssertTrue(t.update(moment(0.5, action: .none, ball: "ball")).isEmpty)
        let made = t.update(moment(1.0, action: .none, ball: "ball-in-basket"))
        XCTAssertEqual(made.map(\.kind), [.made])
        XCTAssertEqual(made[0].pts, 0.125)
        XCTAssertEqual(made[0].resolvedPts, 1.0)
    }

    func testMissedOnWindowExpiryAndBallInBasketFarFromRimDoesNotCount() {
        var t = ShotEventTracker()
        _ = t.update(moment(0.000, action: .layupDunk))
        _ = t.update(moment(0.125, action: .layupDunk))
        XCTAssertTrue(t.update(moment(1.0, action: .none, ball: "ball-in-basket", ballAtRim: false)).isEmpty)
        XCTAssertTrue(t.update(moment(3.0, action: .none)).isEmpty)                // window is 3.0 s, not yet >
        let missed = t.update(moment(3.2, action: .none))
        XCTAssertEqual(missed.map(\.kind), [.missed])
        XCTAssertEqual(missed[0].action, .layupDunk)
    }

    func testCooldownAndCourtProjection() {
        var t = ShotEventTracker()
        let identity = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        _ = t.update(moment(0.000, action: .jumpShot, h: identity))
        let opened = t.update(moment(0.125, action: .jumpShot, h: identity))
        XCTAssertEqual(opened[0].court, CGPoint(x: 0.53, y: 0.62))               // feet through H
        _ = t.update(moment(0.5, action: .none, ball: "ball-in-basket"))          // made at 0.5
        _ = t.update(moment(1.0, action: .jumpShot))                              // inside 2 s cooldown
        XCTAssertTrue(t.update(moment(1.125, action: .jumpShot)).isEmpty)
        _ = t.update(moment(2.5, action: .jumpShot))
        XCTAssertEqual(t.update(moment(2.625, action: .jumpShot)).map(\.kind), [.attempt])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/ShotEventTrackerTests`. Expected: build FAILS — `cannot find 'ShotEventTracker' in scope`.

- [ ] **Step 3: Write the implementation**

`PlayerTracker.swift` line 6: `enum PlayerAction: String, Codable, Equatable {` (cases unchanged).

```swift
// ios/CourtVision/Services/Shot/ShotEventTracker.swift
import CoreGraphics

/// One shot attempt, derived from Moments. The same value is emitted twice:
/// as `.attempt` when it opens and as `.made` / `.missed` when it resolves.
struct ShotEvent: Equatable, Codable {
    enum Kind: String, Codable { case attempt, made, missed }
    var kind: Kind
    /// Attempt-start pts (same value on the attempt and its resolution).
    let pts: Double
    var resolvedPts: Double?
    let trackId: Int
    /// `.jumpShot` or `.layupDunk`.
    let action: PlayerAction
    /// Ground-contact point at attempt start, image space (normalized, top-left).
    let feet: CGPoint
    /// `feet` through the homography at attempt start, court feet. Nil = no fix yet.
    let court: CGPoint?
    /// Confidence of the shooting-state detection that opened the attempt.
    let confidence: Float
}

/// Ref 02's shot event tracker on our Moments: consecutive shooting-state
/// ticks on one track open an attempt; `ball-in-basket` near the tracked rim
/// inside the window resolves it MADE; window expiry resolves it MISSED; a
/// cooldown separates attempts (a putback is a new attempt).
struct ShotEventTracker: Equatable {
    /// Consecutive shooting-state ticks needed to open (2 ≈ 0.25 s at 8 Hz).
    var minStartTicks = 2
    /// Seconds after the start in which ball-in-basket counts as this attempt.
    var windowSec: Double = 3.0
    /// Seconds after a resolution before a new attempt can open.
    var cooldownSec: Double = 2.0
    /// ball-in-basket counts only within `rimReach` × rim width of the rim center.
    var rimReach: CGFloat = 1.5

    private var streak: [Int: Int] = [:]
    private var open: ShotEvent?
    private var lastResolvedPts: Double = -.infinity

    mutating func update(_ m: Moment) -> [ShotEvent] {
        if var attempt = open {
            if Self.ballInBasket(m, rimReach: rimReach) {
                attempt.kind = .made
            } else if m.pts - attempt.pts > windowSec {
                attempt.kind = .missed
            } else {
                return []
            }
            attempt.resolvedPts = m.pts
            open = nil
            lastResolvedPts = m.pts
            streak = [:]
            return [attempt]
        }
        guard m.pts - lastResolvedPts >= cooldownSec else { return [] }

        var live = Set<Int>()
        for p in m.players where p.action == .jumpShot || p.action == .layupDunk {
            live.insert(p.trackId)
            streak[p.trackId, default: 0] += 1
            if streak[p.trackId]! >= minStartTicks {
                let attempt = ShotEvent(kind: .attempt, pts: m.pts, resolvedPts: nil,
                                        trackId: p.trackId, action: p.action, feet: p.feet,
                                        court: m.h.map { $0.apply(p.feet) },
                                        confidence: p.actionConfidence)
                open = attempt
                streak = [:]
                return [attempt]
            }
        }
        streak = streak.filter { live.contains($0.key) }   // a broken streak starts over
        return []
    }

    static func ballInBasket(_ m: Moment, rimReach: CGFloat) -> Bool {
        guard let ball = m.ball, ball.label == "ball-in-basket", let rim = m.rim else { return false }
        return hypot(ball.box.midX - rim.midX, ball.box.midY - rim.midY) <= rimReach * rim.width
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `ShotEventTrackerTests` 3/3.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Shot/ShotEventTracker.swift ios/CourtVision/Services/Player/PlayerTracker.swift \
        ios/CourtVisionTests/ShotEventTrackerTests.swift
git commit -m "feat(shot): ShotEventTracker — attempts open on shooting ticks, resolve on ball-in-basket"
```

---

### Task 11: `ShotEventMapper` + `RosterMap` — resolutions become contract rows

**Files:**
- Create: `ios/CourtVision/Services/Shot/ShotEventMapper.swift`
- Test: `ios/CourtVisionTests/ShotEventMapperTests.swift`

**Interfaces:**
- Consumes: `ShotEvent`, `EventRow`, `Session`, `Player`, `ZoneMapper`.
- Produces:
  ```swift
  enum RosterMap { static func build(players: [Player], teamId: UUID?) -> [String: UUID] }
  enum ShotEventMapper {
      static func eventRow(_ e: ShotEvent, court: CGPoint, session: Session, sessionStartPts: Double,
                           playerId: UUID?, team: String?) -> EventRow?
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/ShotEventMapperTests.swift
import XCTest
@testable import CourtVision

final class ShotEventMapperTests: XCTestCase {
    private func session(_ mode: SessionMode, teamId: UUID? = nil) -> Session {
        Session(id: UUID(), userId: nil, playerId: UUID(), mode: mode, status: .live,
                startedAt: nil, endedAt: nil, calibration: nil, teamA: nil, teamB: nil, teamId: teamId)
    }
    private func shot(_ kind: ShotEvent.Kind, action: PlayerAction = .jumpShot, pts: Double = 12.0) -> ShotEvent {
        ShotEvent(kind: kind, pts: pts, resolvedPts: pts + 1.5, trackId: 4, action: action,
                  feet: CGPoint(x: 0.5, y: 0.5), court: nil, confidence: 0.8)
    }

    func testThreeFromTopOfArc() {
        let s = session(.practice)
        let row = ShotEventMapper.eventRow(shot(.made), court: CGPoint(x: 25, y: 30), session: s,
                                           sessionStartPts: 2.0, playerId: s.playerId, team: nil)!
        XCTAssertEqual(row.sessionId, s.id)
        XCTAssertEqual(row.playerId, s.playerId)
        XCTAssertEqual(row.ts, 10_000)                       // (12.0 − 2.0) s → ms
        XCTAssertTrue(row.made)
        XCTAssertEqual(row.category, .three)
        XCTAssertEqual(row.zone, .top_arc_3)
        XCTAssertEqual(row.courtX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(row.courtY, 30.0 / 47.0, accuracy: 1e-9)
        XCTAssertEqual(row.confidence, 0.8, accuracy: 1e-6)
        XCTAssertNil(row.team)
        XCTAssertEqual(row.type, "shot")
    }

    func testLayupNeverClaimsDunkAndFreeThrowModeWins() {
        let layup = ShotEventMapper.eventRow(shot(.missed, action: .layupDunk), court: CGPoint(x: 25, y: 7),
                                             session: session(.game), sessionStartPts: 0, playerId: nil, team: "B")!
        XCTAssertEqual(layup.category, .layup)                // ponytail: model can't split layup from dunk
        XCTAssertEqual(layup.zone, .paint)
        XCTAssertFalse(layup.made)
        XCTAssertEqual(layup.team, "B")
        let ft = ShotEventMapper.eventRow(shot(.made), court: CGPoint(x: 25, y: 19),
                                          session: session(.freethrow), sessionStartPts: 0, playerId: nil, team: nil)!
        XCTAssertEqual(ft.category, .free_throw)
        XCTAssertEqual(ft.zone, .ft_line)
    }

    func testAttemptKindProducesNoRow() {
        XCTAssertNil(ShotEventMapper.eventRow(shot(.attempt), court: CGPoint(x: 25, y: 20),
                                              session: session(.practice), sessionStartPts: 0, playerId: nil, team: nil))
    }

    func testRosterMapIsTeamScopedByJerseyNumber() {
        let team = UUID(), other = UUID()
        let p = { (n: Int?, t: UUID?) in Player(id: UUID(), userId: nil, name: "p", jerseyNumber: n, position: nil, teamId: t, createdAt: nil) }
        let a = p(23, team), b = p(23, other), c = p(nil, team)
        let map = RosterMap.build(players: [a, b, c], teamId: team)
        XCTAssertEqual(map, ["23": a.id])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/ShotEventMapperTests`. Expected: build FAILS — `cannot find 'ShotEventMapper' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// ios/CourtVision/Services/Shot/ShotEventMapper.swift
import CoreGraphics
import Foundation

/// Roster lookup for game sessions: jersey number → `players.id`, restricted
/// to the session's team. Non-game sessions attribute every shot to the
/// session player (see `RecordModel.emit`).
enum RosterMap {
    static func build(players: [Player], teamId: UUID?) -> [String: UUID] {
        var map: [String: UUID] = [:]
        for p in players where p.teamId == teamId {
            if let n = p.jerseyNumber { map[String(n)] = p.id }
        }
        return map
    }
}

/// A resolved shot with a court location → one row of the existing event
/// contract. Category / zone math is `ZoneMapper` (shared with the web and
/// simulate_session.py); nothing is reimplemented here.
enum ShotEventMapper {
    /// `sessionStartPts` is the first engine tick's pts; `ts` is ms since then.
    static func eventRow(_ e: ShotEvent, court: CGPoint, session: Session, sessionStartPts: Double,
                         playerId: UUID?, team: String?) -> EventRow? {
        guard e.kind != .attempt else { return nil }
        let x = Double(court.x), y = Double(court.y)
        let freeThrow = session.mode == .freethrow
        let n = ZoneMapper.normalized(xFt: x, yFt: y)
        return EventRow(
            id: UUID(),
            sessionId: session.id,
            userId: nil,
            ts: max(0, Int(((e.pts - sessionStartPts) * 1000).rounded())),
            wallClock: nil,
            playerId: playerId,
            confidence: Double(e.confidence),
            made: e.kind == .made,
            // ponytail: the model's one class covers layup AND dunk — never claim dunk.
            category: ZoneMapper.category(xFt: x, yFt: y, freeThrowMode: freeThrow, releaseAtRim: false),
            zone: ZoneMapper.zone(xFt: x, yFt: y, freeThrow: freeThrow),
            courtX: n.x,
            courtY: n.y,
            releaseAngleDeg: nil,
            releaseTimeMs: nil,
            team: team)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `ShotEventMapperTests` 4/4.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Shot/ShotEventMapper.swift ios/CourtVisionTests/ShotEventMapperTests.swift
git commit -m "feat(shot): ShotEventMapper + RosterMap — resolutions become contract rows"
```

---

### Task 12: Events flow again — RecordModel runs the tracker, resolves location, enqueues

**Files:**
- Modify: `ios/CourtVision/Views/RecordView.swift` (`RecordModel`: tracker in the loop, pending-location rule, `emit`, toast; status line)

**Interfaces:**
- Consumes: `ShotEventTracker`, `ShotEventMapper`, `RosterMap`, `OfflineQueue.shared.enqueue`, `SupabaseService.shared.players()`, `Engine.rim.lastReacquirePts`.
- Produces: published `shotCount: Int`, `shotToast: String?`; `RecordModel.publish(_:events:tickMs:)`.

- [ ] **Step 1: Wire it** — in `RecordModel`:

Add published state and private state:
```swift
    @Published var shotCount = 0
    @Published var shotToast: String?

    private var sessionStartPts: Double?
    private var roster: [String: UUID] = [:]
    /// Resolved shots still waiting for a court fix (≤ 20 s, then dropped —
    /// never an invented location).
    private var pendingLocation: [ShotEvent] = []
```

In `start(...)`, after `self.engine = engine`, load the roster once (game mode only):
```swift
        if session.mode == .game {
            Task { [weak self] in
                let players = (try? await SupabaseService.shared.players()) ?? []
                self?.roster = RosterMap.build(players: players, teamId: session.teamId)
            }
        }
```

In the detached loop, own the tracker on the loop task and pass events through:
```swift
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            var shots = ShotEventTracker()
            for await sample in frames {
                if Task.isCancelled { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard engine.shouldTick(at: pts),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let t0 = CFAbsoluteTimeGetCurrent()
                let moment = engine.process(pixelBuffer, pts: pts)
                let events = shots.update(moment)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                await self?.publish(moment, events: events, tickMs: ms)
            }
        }
```

Change `publish` signature to `private func publish(_ m: Moment, events: [ShotEvent], tickMs: Double)` and add at its end:
```swift
        if sessionStartPts == nil { sessionStartPts = m.pts }
        for e in events {
            switch e.kind {
            case .attempt: shotToast = "Shot…"
            case .made, .missed: resolve(e, latest: m)
            }
        }
        flushPending(m)
```

Add the resolution rules and `emit`:
```swift
    /// A resolution carries the attempt-time court point when there was a
    /// fix. Without one, the *current* fix still applies as long as the rim
    /// never re-acquired since the attempt (camera didn't swing); otherwise
    /// the shot waits ≤ 20 s for a fix.
    private func resolve(_ e: ShotEvent, latest m: Moment) {
        if let court = e.court {
            emit(e, court: court)
        } else if let h = m.h, fixStillApplies(since: e.pts) {
            emit(e, court: h.apply(e.feet))
        } else {
            pendingLocation.append(e)
        }
    }

    private func flushPending(_ m: Moment) {
        pendingLocation.removeAll { m.pts - $0.pts > 20 }          // dropped, never invented
        guard let h = m.h else { return }
        let ready = pendingLocation.filter { fixStillApplies(since: $0.pts) }
        for e in ready { emit(e, court: h.apply(e.feet)) }
        pendingLocation.removeAll { r in ready.contains(r) }
    }

    private func fixStillApplies(since pts: Double) -> Bool {
        (engine?.rim.lastReacquirePts ?? -.infinity) < pts
    }

    private func emit(_ e: ShotEvent, court: CGPoint) {
        guard let session, let start = sessionStartPts else { return }
        let number = players.first { $0.trackId == e.trackId }?.number
        let playerId = session.mode == .game ? number.flatMap { roster[$0] } : session.playerId
        guard let row = ShotEventMapper.eventRow(e, court: court, session: session, sessionStartPts: start,
                                                 playerId: playerId,
                                                 team: session.mode == .game ? attackingTeam : nil)
        else { return }
        OfflineQueue.shared.enqueue(row)
        shotCount += 1
        shotToast = (row.made ? "✓ " : "✗ ") + row.category.rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
    }
```

Status line in the view — prepend the shot count and toast:
```swift
                    Text("Shots: \(model.shotCount) \(model.shotToast ?? "") · \(model.ballStatus) · \(model.playerStatus) · \(model.courtStatus) · \(model.tickStatus)")
```

- [ ] **Step 2: Build + tests**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Device check** — practice session, shoot 5 free throws-ish shots in front of the phone: the status shows `Shot…` then `✓ …` / `✗ …`, `Shots:` increments, and the rows appear on the web dashboard within 10 s (Realtime) with plausible zone/category. In game mode with a roster, a numbered jersey attributes to the right player in `session_player_box_scores`. Kill wifi mid-session → shots still count and appear when wifi returns (OfflineQueue).

- [ ] **Step 4: Commit**

```bash
git add ios/CourtVision/Views/RecordView.swift
git commit -m "feat(record): shot events flow — tracker per tick, location rule, OfflineQueue"
```

---

### Task 13: `EngineReplay` + fixture clip + `EngineReplayTests` (off-device regression, events export)

**Files:**
- Create: `ios/CourtVision/Services/Engine/EngineReplay.swift`
- Create: `ios/CourtVisionTests/Fixtures/README.md`, `ios/CourtVisionTests/Fixtures/freethrow.mp4`, `ios/CourtVisionTests/Fixtures/freethrow.gt.csv`
- Modify: `ios/project.yml` (test target resources)
- Test: `ios/CourtVisionTests/EngineReplayTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum EngineReplay {
      struct Result { var moments: [Moment]; var events: [ShotEvent] }
      static func run(url: URL, config: Engine.Config = Engine.Config(), isGame: Bool = false) async throws -> Result
  }
  ```
  Events JSON written by the test: `[ShotEvent]` encoded with `JSONEncoder` (CGPoint encodes as `[x, y]`), file `<clip>.events.json` next to the clip (env clip) or in `NSTemporaryDirectory()` (bundled clip; path printed).

- [ ] **Step 1: Fixture** — put a ≤ 15 s, ≤ 8 MB, 1080p landscape clip of one shooter taking 2–4 shots at a hoop at `ios/CourtVisionTests/Fixtures/freethrow.mp4` (film it with the phone held like a session — landscape-right; or the CC-licensed Wikimedia free-throw clip from the 2026-08-13 field test). Frames must decode upright (no rotation transform: `AVAssetTrack.preferredTransform` identity — record in landscape and check with `ffprobe`/QuickTime "rotation 0"). Hand-label `freethrow.gt.csv`:

```csv
attempt_s,made,x_ft,y_ft
2.4,1,25,19
7.1,0,25,19
```
(`attempt_s` from clip start; `x_ft,y_ft` estimated from court markings on the standard half court, rim at (25, 5.25); FT line is y = 19.) `Fixtures/README.md`: source, license, how it was labeled, this schema.

`ios/project.yml` — add resources to the test target:
```yaml
  CourtVisionTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: CourtVisionTests
        excludes: ["Fixtures/**"]
      - path: CourtVisionTests/Fixtures
        buildPhase: resources     # files land at the test bundle root
```

- [ ] **Step 2: Write the failing test**

```swift
// ios/CourtVisionTests/EngineReplayTests.swift
import XCTest
@testable import CourtVision

/// The whole pipeline over a real clip with the real models — the off-device
/// regression test. Also the ground-truth flow: set
/// TEST_RUNNER_COURTVISION_REPLAY_CLIP=/abs/path.mp4 to replay any clip and
/// get `<clip>.events.json` next to it for tools/eval_events.py.
final class EngineReplayTests: XCTestCase {
    private func write(_ events: [ShotEvent], to url: URL) throws {
        let data = try JSONEncoder().encode(events)
        try data.write(to: url)
        print("EVENTS_JSON=\(url.path)")
    }

    func testBundledClipProducesResolvedAttempts() async throws {
        let bundle = Bundle(for: EngineReplayTests.self)
        let clip = try XCTUnwrap(bundle.url(forResource: "freethrow", withExtension: "mp4"),
                                 "Fixtures/freethrow.mp4 missing from the test bundle")
        let result = try await EngineReplay.run(url: clip)
        XCTAssertGreaterThan(result.moments.count, 10)
        let resolved = result.events.filter { $0.kind != .attempt }
        XCTAssertGreaterThanOrEqual(resolved.count, 1, "no attempt resolved on the fixture clip")
        XCTAssertTrue(resolved.allSatisfy { $0.resolvedPts != nil })
        try write(result.events, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("freethrow.events.json"))
    }

    func testReplayClipFromEnvironment() async throws {
        guard let path = ProcessInfo.processInfo.environment["COURTVISION_REPLAY_CLIP"] else {
            throw XCTSkip("set TEST_RUNNER_COURTVISION_REPLAY_CLIP to replay a clip")
        }
        let clip = URL(fileURLWithPath: path)
        let result = try await EngineReplay.run(url: clip)
        try write(result.events, to: clip.deletingPathExtension().appendingPathExtension("events.json"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run with `-only-testing:CourtVisionTests/EngineReplayTests`. Expected: build FAILS — `cannot find 'EngineReplay' in scope`.

- [ ] **Step 4: Write the implementation**

```swift
// ios/CourtVision/Services/Engine/EngineReplay.swift
import AVFoundation
import CoreVideo

/// Runs the engine over a video file exactly as the live loop would (same
/// tick throttle, thermal ignored), collecting Moments and shot events. Used
/// by EngineReplayTests and the ground-truth eval flow (docs/EVAL.md).
enum EngineReplay {
    struct Result {
        var moments: [Moment] = []
        var events: [ShotEvent] = []
    }

    static func run(url: URL, config: Engine.Config = Engine.Config(),
                    isGame: Bool = false) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let engine = Engine(config: config, calibration: nil, isGame: isGame,
                            attackingTeam: "A", rimAnchors: [:], initialRim: nil)
        var shots = ShotEventTracker()
        var result = Result()
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard engine.shouldTick(at: pts, thermal: .nominal),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let moment = engine.process(pixelBuffer, pts: pts)
            result.moments.append(moment)
            result.events.append(contentsOf: shots.update(moment))
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return result
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run the Global Constraints test command (CoreML runs on the simulator CPU — the replay test may take a minute). Expected: `** TEST SUCCEEDED **`; `testReplayClipFromEnvironment` reports *skipped*. If `testBundledClipProducesResolvedAttempts` fails on `resolved.count`, the clip is unusable for the pipeline (rim not found / no shooting state fired): pick a clearer clip — do not weaken the assertion.

- [ ] **Step 6: Commit**

```bash
git add ios/CourtVision/Services/Engine/EngineReplay.swift ios/CourtVisionTests/EngineReplayTests.swift \
        ios/CourtVisionTests/Fixtures ios/project.yml
git commit -m "test(engine): EngineReplay over a fixture clip; events export for eval"
```

---

### Task 14: `tools/eval_events.py` — attempt P/R, make/miss accuracy, location error

**Files:**
- Create: `tools/eval_events.py`
- Modify: `tools/README.md`, `docs/EVAL.md` (P1 section text)
- Test: `tools/test_eval_events.py` (stdlib `unittest`, run with `python3 -m unittest tools/test_eval_events.py`)

**Interfaces:**
- Produces CLI: `python3 tools/eval_events.py GT.csv EVENTS.json [--tolerance 1.5] [--append docs/EVAL.md --clip NAME --commit SHA]` and `python3 tools/eval_events.py GT.csv --session SESSION_ID --email … --password …` (Supabase; `SUPABASE_URL`/`SUPABASE_ANON_KEY` env as in `simulate_session.py`). Library functions: `load_gt(path) -> list[dict]`, `load_replay_events(path) -> list[dict]`, `match(gt, events, tol) -> dict`.

- [ ] **Step 1: Write the failing test**

```python
# tools/test_eval_events.py
import unittest

from eval_events import match


class MatchTests(unittest.TestCase):
    def test_precision_recall_accuracy_and_location(self):
        gt = [{"t": 2.4, "made": True, "x": 25.0, "y": 19.0},
              {"t": 7.1, "made": False, "x": 25.0, "y": 19.0},
              {"t": 20.0, "made": True, "x": 5.0, "y": 8.0}]          # missed by the app
        ev = [{"t": 2.9, "made": True, "x": 26.0, "y": 19.0},         # TP, 1 ft off
              {"t": 7.0, "made": True, "x": 25.0, "y": 22.0},         # TP, wrong outcome, 3 ft off
              {"t": 12.0, "made": False, "x": None, "y": None}]       # FP
        r = match(gt, ev, tolerance=1.5)
        self.assertEqual((r["tp"], r["fp"], r["fn"]), (2, 1, 1))
        self.assertAlmostEqual(r["precision"], 2 / 3)
        self.assertAlmostEqual(r["recall"], 2 / 3)
        self.assertAlmostEqual(r["outcome_acc"], 0.5)
        self.assertAlmostEqual(r["loc_median_ft"], 2.0)               # median of [1, 3]
        self.assertAlmostEqual(r["loc_p90_ft"], 3.0)

    def test_each_gt_matches_at_most_one_event(self):
        gt = [{"t": 5.0, "made": True, "x": 25.0, "y": 19.0}]
        ev = [{"t": 5.2, "made": True, "x": 25.0, "y": 19.0},
              {"t": 5.9, "made": True, "x": 25.0, "y": 19.0}]
        r = match(gt, ev, tolerance=1.5)
        self.assertEqual((r["tp"], r["fp"], r["fn"]), (1, 1, 0))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd tools && python3 -m unittest test_eval_events.py -v`. Expected: `ModuleNotFoundError: No module named 'eval_events'`.

- [ ] **Step 3: Write the implementation**

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools && python3 -m unittest test_eval_events.py -v`. Expected: `OK` (2 tests). Then a smoke run against the fixture export from Task 13 (the `EVENTS_JSON=<path>` line printed in that test's log):
`python3 tools/eval_events.py ios/CourtVisionTests/Fixtures/freethrow.gt.csv <path>`. Expected: three summary lines, no traceback.

- [ ] **Step 5: Docs** — append to `tools/README.md`:

```markdown
`eval_events.py GT.csv EVENTS.json` / `eval_events.py GT.csv --session ID …` —
attempt precision/recall (±1.5 s), make/miss accuracy, location error (ft)
against a hand-labeled CSV. Events come from `EngineReplayTests`
(`TEST_RUNNER_COURTVISION_REPLAY_CLIP=/abs/clip.mp4 xcodebuild … test
-only-testing:CourtVisionTests/EngineReplayTests/testReplayClipFromEnvironment`
writes `clip.events.json`) or from Supabase. `--append docs/EVAL.md` records
the row. Stdlib only. Tests: `python3 -m unittest tools/test_eval_events.py`.
```

- [ ] **Step 6: Commit**

```bash
git add tools/eval_events.py tools/test_eval_events.py tools/README.md
git commit -m "feat(tools): eval_events.py — attempt P/R, make/miss accuracy, location error"
```

---

### Task 15: Ground-truth clips, numbers in `docs/EVAL.md`, merge P1

**Files:**
- Create: `ios/CourtVisionTests/Fixtures/<clip>.gt.csv` for each field clip (clips themselves stay OUT of git unless ≤ 8 MB — keep them in `~/courtvision-clips/`, listed by name + source in `Fixtures/README.md`)
- Modify: `docs/EVAL.md` (P1 rows), `docs/INSTRUCTION.md` §7 checklist

- [ ] **Step 1: Film 5–10 clips** (≤ 60 s each, landscape-right, from the sideline/baseline the way a session is filmed; a mix of jump shots and layups; at least one clip with two players in frame). Hand-label each `<clip>.gt.csv` (schema from Task 13) by scrubbing the video: attempt time = the release, x/y from court markings.

- [ ] **Step 2: Replay + eval each clip**

```bash
cd ios && xcodegen generate
SIM=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed -E 's/ *\(.*//' | xargs)
for c in ~/courtvision-clips/*.mp4; do
  TEST_RUNNER_COURTVISION_REPLAY_CLIP="$c" xcodebuild -project CourtVision.xcodeproj -scheme CourtVision \
    -destination "platform=iOS Simulator,name=$SIM" \
    -only-testing:CourtVisionTests/EngineReplayTests/testReplayClipFromEnvironment test | grep -E "EVENTS_JSON|TEST"
  python3 ../tools/eval_events.py "${c%.mp4}.gt.csv" "${c%.mp4}.events.json" \
    --append ../docs/EVAL.md --clip "$(basename "${c%.mp4}")" --commit "$(git rev-parse --short HEAD)"
done
```

- [ ] **Step 3: One live session too** — record one real practice session on the device while a second person logs each shot (time on a stopwatch started at the first tick, made/missed, spot); label it as `live-<date>.gt.csv`; run `eval_events.py … --session <id> --email … --password …` and append. This checks the live loop against the replay path (thermal, dropped frames).

- [ ] **Step 4: Write the P1 baseline paragraph** under the P1 table in `docs/EVAL.md`: aggregate P/R, make/miss accuracy, median location error across clips, and the two worst failure modes seen (e.g. "attempts opened on shot fakes", "location 6 ft off when the shooter's feet were occluded"). These numbers are the P2 baseline (`docs/superpowers/specs/2026-08-17-tracking-engine-design.md` P2 gate).

- [ ] **Step 5: Checklist** — in `docs/INSTRUCTION.md` §7 add: `- [ ] tools/eval_events.py rows appended to docs/EVAL.md for the fixture clip (any change under Services/Shot or Services/Engine)`.

- [ ] **Step 6: Commit, merge P1**

```bash
git add ios/CourtVisionTests/Fixtures docs/EVAL.md docs/INSTRUCTION.md
git commit -m "docs(eval): P1 shot-event baseline on ground-truth clips"
git checkout dev && git merge --no-ff shots -m "merge: shots (P1) — shot events from Moments, measured"
```

P1 gate: attempt P/R, make/miss accuracy and median location error recorded on ≥ 5 clips in `docs/EVAL.md`.

---

## Appendix — P2–P5 outline (each becomes its own plan at its gate)

Not executable steps; scope + files + gate only, from the spec.

**P2 — `court` (start labeling on day 1 of P0; the long pole)**
- Data: 33-point schema (ref 02: corners, baselines, center, paint, arcs, under-basket), Roboflow project, 300–500 own courtside frames, model-assisted labeling; fixed val split from separate gyms/games.
- Train: YOLO-pose n/s (`ultralytics`, repo `.venv`), CoreML export; per-keypoint PCK + reprojection ft in new `tools/eval_court.py`.
- Code: `Services/Court/CourtKeypoints.swift` (CoreML pose model wrapper → `[(index, point, conf)]`), `CourtModel.swift` replacing `CourtEstimator` internals: conf ≥ 0.5, ≥ 4 pts → `Homography` with Hartley normalization + RANSAC (>4) → 5-tick H averaging → rim-reprojection gate (reuse `scoreCourtAssignments` math); rectangles fallback. `Engine.Detectors.courtKeypoints`.
- Gate: median shot-location error on the P1 clips drops vs the P1 baseline; reprojection ≤ tolerance derived from that baseline; per-class table on the fixed val set.

**P3 — `tracking`**
- `TeamAssigner` (`VNGenerateImageFeaturePrintRequest` on player crops @1 Hz → 2-means → per-track vote; referee excluded), `PlayerTracker` center-distance gate, `MomentBuffer`, `PostProcessor` (re-ID merge on team+number+gap ≤ 4 s; MAD speed outliers → interpolate → moving-average 5; H smoothing; per-track distance/avg/max speed; event location update by id), possession events (min-distance ball ↔ player with hysteresis), closest defender at attempt.
- DB: `supabase/migrations/0004_tracking.sql` — `moments`, `tracks`, `events` columns `attempt_ts`, `shooter_track_id`, `defender_dist_ft`, `type in ('shot','possession')`, views `session_shot_cells`, `player_spread_range`; RLS; not in realtime. Mirrors in `Contract.swift`, `contract.ts`, `simulate_session.py`.
- Upload at session end through `OfflineQueue` (generalize `PendingEvent` payload to a table + JSON).
- Gate: post-processed ID churn < live churn on the P1 clips; 94-ft sprint distance within tolerance.

**P4 — `dashboard`**
- `HalfCourtShotChart` → cell graduated symbols (size ∝ FGA, diverging color at 1.0 PPA) from `session_shot_cells`; Spread/Range tiles from `player_spread_range`; tracking replay (top-down + scrubber over `moments`); tracks table. ≤ 6 colors.
- Gate: renders from a real session; 10 s event contract holds.

**P5 — flywheel (ongoing)**
- Engine emits hard-frame markers (track break, 0.2–0.5 confidence band) → mine → label → retrain; build the fixed 100+ image own-domain val set; per-class table on every retrain (`tools/eval_model.py`).
