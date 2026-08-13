# Layered Detection Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure detection into three layers — detect core physical objects, track them across frames, classify player action state on top — with persistent jersey numbers and per-class model eval tooling.

**Architecture:** Labels and confidence survive the `ObjectDetector` boundary via a new `Detection` struct. A greedy-IoU `PlayerTracker` gives players stable IDs; `ActionClassifier` annotates tracks with state-class detections instead of treating them as separate objects; jersey numbers accumulate per track (majority vote). Models are unchanged; rim union (HoopDetector ∪ unified) is unchanged.

**Tech Stack:** Swift 5 / iOS 17, Apple Vision + CoreML, XCTest, xcodegen; Python 3 + ultralytics (repo `.venv`) for eval tooling.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-12-layered-detection-design.md`
- Branch: `refactor/layered-detection` (off `dev`). Commit per task.
- All boxes normalized, TOP-LEFT origin (Vision's bottom-left flipped at the `ObjectDetector` boundary — existing convention).
- No new Swift dependencies. No model retraining. No folder restructure.
- Existing confidence floors unchanged: rim 0.30, ball 0.25, player 0.30, number 0.30.
- Test command (from `ios/`):
  ```bash
  xcodegen generate
  SIM=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed -E 's/ *\(.*//' | xargs)
  xcodebuild -project CourtVision.xcodeproj -scheme CourtVision \
    -destination "platform=iOS Simulator,name=$SIM" test
  ```
  Expected on success: `** TEST SUCCEEDED **`. (If no simulator exists, `xcrun simctl list runtimes` and create one; do not skip tests.)

---

### Task 1: `Detection` struct — labels survive the detector boundary

**Files:**
- Create: `ios/CourtVision/Services/Detection.swift`
- Modify: `ios/CourtVision/Services/ObjectDetector.swift`
- Modify: `ios/CourtVision/Services/Rim/RimFinder.swift:39-49` (map to `.box`)
- Modify: `ios/CourtVision/Services/Player/NumberReader.swift:14-15` (map to `.box`)
- Test: `ios/CourtVisionTests/DetectionTests.swift`

**Interfaces:**
- Produces: `struct Detection: Equatable { var box: CGRect; var label: String; var confidence: Float }`, `Detection.fromVision(label:confidence:visionBox:) -> Detection`, and `ObjectDetector.detect(labels:in:maxCount:minConfidence:) -> [Detection]` (was `[CGRect]`). Every later task consumes these.

- [ ] **Step 1: Write the failing test**

```swift
// ios/CourtVisionTests/DetectionTests.swift
import XCTest
@testable import CourtVision

final class DetectionTests: XCTestCase {
    func testFromVisionFlipsYAndKeepsLabelConfidence() {
        // Vision box: bottom-left origin. y=0.1, h=0.2 → top-left y = 1-0.1-0.2 = 0.7
        let d = Detection.fromVision(label: "rim", confidence: 0.83,
                                     visionBox: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.2))
        XCTAssertEqual(d.label, "rim")
        XCTAssertEqual(d.confidence, 0.83)
        XCTAssertEqual(d.box, CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.2))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the Global Constraints test command. Expected: build FAILS — `cannot find 'Detection' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// ios/CourtVision/Services/Detection.swift
import CoreGraphics

/// One labeled detection (Layer 1 output). Box is normalized, TOP-LEFT
/// origin. Label and confidence survive the detector boundary so the
/// tracking and state-classification layers can tell classes apart.
struct Detection: Equatable {
    var box: CGRect
    var label: String
    var confidence: Float

    /// Vision boxes are bottom-left origin; flip to top-left here, once.
    static func fromVision(label: String, confidence: Float, visionBox b: CGRect) -> Detection {
        Detection(box: CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height,
                              width: b.width, height: b.height),
                  label: label, confidence: confidence)
    }
}
```

In `ObjectDetector.swift`, change `detect` to return `[Detection]` (docs comment: replace "Boxes matching" with "Labeled detections matching"):

```swift
    func detect(labels: Set<String>, in pixelBuffer: CVPixelBuffer,
                maxCount: Int, minConfidence: Float) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        return (request.results as? [VNRecognizedObjectObservation] ?? [])
            .filter { obs in
                guard let id = obs.labels.first?.identifier else { return false }
                return labels.contains(id) && obs.confidence >= minConfidence
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxCount)
            .map { obs in
                Detection.fromVision(label: obs.labels.first?.identifier ?? "",
                                     confidence: obs.confidence,
                                     visionBox: obs.boundingBox)
            }
    }
```

Keep rim + number call sites compiling by mapping to boxes (labels not needed there):

```swift
// RimFinder.detectRims — replace the two detect calls:
        var candidates = ObjectDetector.hoop?.detect(labels: ["rim", "Basketball Hoop"],
                                                     in: pixelBuffer,
                                                     maxCount: maxCount, minConfidence: 0.30)
            .map(\.box) ?? []
        if let extra = ObjectDetector.unified?.detect(labels: ["rim"], in: pixelBuffer,
                                                      maxCount: maxCount, minConfidence: 0.30)
            .map(\.box) {
```

```swift
// NumberReader.read — replace the detect call:
        let regions = ObjectDetector.unified?.detect(labels: ["number"], in: pixelBuffer,
                                                     maxCount: maxCount, minConfidence: 0.3)
            .map(\.box) ?? []
```

NOTE: `PlayerFinder.detectPlayers` and `BallFinder.detectBalls` will not compile yet — Tasks 2 and 3 rework them. To keep this task's commit green, apply the same `.map(\.box)` to those two call sites temporarily (Tasks 2/3 replace them).

- [ ] **Step 4: Run tests to verify they pass**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, `DetectionTests` included.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Detection.swift ios/CourtVision/Services/ObjectDetector.swift \
        ios/CourtVision/Services/Rim/RimFinder.swift ios/CourtVision/Services/Player/NumberReader.swift \
        ios/CourtVision/Services/Ball/BallFinder.swift ios/CourtVision/Services/Player/PlayerFinder.swift \
        ios/CourtVisionTests/DetectionTests.swift
git commit -m "feat(detect): Detection struct — labels survive the boundary"
```

---

### Task 2: PlayerFinder — core players vs state classes

**Files:**
- Modify: `ios/CourtVision/Services/Player/PlayerFinder.swift` (full rewrite below; keep `DetectedPlayer` and `assign` untouched for now — Task 6 removes them)
- Test: `ios/CourtVisionTests/PlayerFinderTests.swift`

**Interfaces:**
- Consumes: `Detection`, `ObjectDetector.detect -> [Detection]` (Task 1).
- Produces: `PlayerFinder.baseLabels/stateLabels: Set<String>`, `detectAll(in:) -> [Detection]`, `corePlayers(_:maxCount:) -> [Detection]`, `states(_:) -> [Detection]`, `shapeFiltered(_: [Detection]) -> [Detection]`, `dedupe(_: [Detection], iouThreshold:) -> [Detection]`, `iou(_:_:) -> CGFloat` (unchanged signature).

- [ ] **Step 1: Update the tests (failing first)**

Replace the two box-based tests in `PlayerFinderTests.swift` (keep `testNumberAssignment` as-is until Task 6):

```swift
    func testShapeFilterKillsNonPersonBoxes() {
        let person = Detection(box: CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.22),
                               label: "player", confidence: 0.8)
        let scoreboard = Detection(box: CGRect(x: 0.3, y: 0.02, width: 0.4, height: 0.10),
                                   label: "player", confidence: 0.7)  // wide, top of frame
        let speck = Detection(box: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.03),
                              label: "player", confidence: 0.6)
        XCTAssertEqual(PlayerFinder.shapeFiltered([person, scoreboard, speck]), [person])
    }

    func testCorePlayersKeepBaseBoxOverStateBox() {
        // Same player seen as base "player" (lower conf) and "player-jump-shot"
        // (higher conf): the BASE box must survive the dedupe — state classes
        // are Layer-3 evidence, not extra players.
        let base = Detection(box: CGRect(x: 0.40, y: 0.40, width: 0.06, height: 0.22),
                             label: "player", confidence: 0.55)
        let state = Detection(box: CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22),
                              label: "player-jump-shot", confidence: 0.90)
        let other = Detection(box: CGRect(x: 0.70, y: 0.45, width: 0.06, height: 0.20),
                              label: "player", confidence: 0.8)
        XCTAssertEqual(PlayerFinder.corePlayers([state, base, other]), [base, other])
    }

    func testStatesFilterKeepsOnlyStateClasses() {
        let base = Detection(box: CGRect(x: 0.4, y: 0.4, width: 0.06, height: 0.22),
                             label: "player", confidence: 0.8)
        let shot = Detection(box: CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22),
                             label: "player-jump-shot", confidence: 0.9)
        XCTAssertEqual(PlayerFinder.states([base, shot]), [shot])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run the test command. Expected: build FAILS — `shapeFiltered` type mismatch, `corePlayers`/`states` not found.

- [ ] **Step 3: Implement**

Replace everything in `PlayerFinder.swift` between the header comment and `assign` (keep `DetectedPlayer`, `assign`, `iou` — `iou` is used verbatim):

```swift
enum PlayerFinder {
    static let baseLabels: Set<String> = ["Player", "player"]
    /// Player STATES — still players, never separate objects. They feed the
    /// action layer (ActionClassifier), and their boxes count as player
    /// evidence in detection.
    static let stateLabels: Set<String> = [
        "player-in-possession", "player-jump-shot",
        "player-layup-dunk", "player-shot-block",
    ]
    static let playerLabels = baseLabels.union(stateLabels)

    /// Raw labeled player-family detections, one call per tick.
    static func detectAll(in pixelBuffer: CVPixelBuffer) -> [Detection] {
        ObjectDetector.player?.detect(labels: playerLabels, in: pixelBuffer,
                                      maxCount: 24, minConfidence: 0.30) ?? []
    }

    /// Layer-1 output: one detection per physical player. Shape filter, then
    /// greedy dedupe with BASE `player` boxes ranked first, so an overlapping
    /// (player, player-jump-shot) pair survives as the base box.
    static func corePlayers(_ raw: [Detection], maxCount: Int = 14) -> [Detection] {
        let ranked = shapeFiltered(raw).sorted {
            let a = baseLabels.contains($0.label), b = baseLabels.contains($1.label)
            return a == b ? $0.confidence > $1.confidence : a
        }
        return Array(dedupe(ranked).prefix(maxCount))
    }

    /// Layer-3 input: this tick's state-class detections, unfiltered.
    static func states(_ raw: [Detection]) -> [Detection] {
        raw.filter { stateLabels.contains($0.label) }
    }

    /// Person plausibility: upright-ish (crouching allowed), not a speck,
    /// not the whole frame, feet not floating in the scoreboard zone.
    static func shapeFiltered(_ detections: [Detection]) -> [Detection] {
        detections.filter { d in
            d.box.height > d.box.width * 0.9
                && d.box.height > 0.05 && d.box.height < 0.9
                && d.box.width > 0.015
                && d.box.maxY > 0.2
        }
    }

    /// Cross-class NMS. Input arrives ranked (base first, then confidence),
    /// so the preferred detection of an overlapping pair survives.
    static func dedupe(_ detections: [Detection], iouThreshold: CGFloat = 0.45) -> [Detection] {
        var kept: [Detection] = []
        for d in detections where !kept.contains(where: { iou($0.box, d.box) > iouThreshold }) {
            kept.append(d)
        }
        return kept
    }
```

Remove the temporary `.map(\.box)` from Task 1 on the old `detectPlayers`; delete `detectPlayers` entirely (RecordModel still calls it — leave RecordModel broken? NO: keep a one-line shim until Task 6 so every commit builds):

```swift
    /// Transitional shim — RecordModel migrates to the layered calls in the
    /// wiring task; remove with DetectedPlayer.
    static func detectPlayers(in pixelBuffer: CVPixelBuffer, maxCount: Int = 14) -> [CGRect] {
        corePlayers(detectAll(in: pixelBuffer), maxCount: maxCount).map(\.box)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Player/PlayerFinder.swift ios/CourtVisionTests/PlayerFinderTests.swift
git commit -m "feat(player): split core players from state classes"
```

---

### Task 3: BallFinder + BallTrack carry labels

**Files:**
- Modify: `ios/CourtVision/Services/Ball/BallFinder.swift`
- Modify: `ios/CourtVision/Views/RecordView.swift:301-315` (`handleBall`)
- Test: `ios/CourtVisionTests/BallFinderTests.swift`

**Interfaces:**
- Consumes: `Detection` (Task 1).
- Produces: `BallFinder.detectBalls(in:maxCount:) -> [Detection]`, `BallFinder.pickBall(candidates: [Detection], near: CGPoint?, within: CGFloat?) -> Detection?`, `BallTrack.Sample` gains `let label: String`, `BallTrack.update(with detection: Detection?, at:)`.

- [ ] **Step 1: Update the tests (failing first)**

Replace `BallFinderTests.swift` contents:

```swift
import XCTest
@testable import CourtVision

final class BallFinderTests: XCTestCase {
    private func ball(_ x: CGFloat, _ y: CGFloat, label: String = "ball",
                      conf: Float = 0.5) -> Detection {
        Detection(box: CGRect(x: x, y: y, width: 0.03, height: 0.03),
                  label: label, confidence: conf)
    }

    func testPickBallContinuityGate() {
        let far = ball(0.05, 0.1)    // other ball / head
        let near = ball(0.52, 0.42)  // the game ball
        let anchor = CGPoint(x: 0.5, y: 0.4)
        XCTAssertEqual(BallFinder.pickBall(candidates: [far, near], near: anchor, within: 0.2), near)
        // Only a distant candidate → must not steal the track.
        XCTAssertNil(BallFinder.pickBall(candidates: [far], near: anchor, within: 0.2))
        // No anchor yet → most confident (first).
        XCTAssertEqual(BallFinder.pickBall(candidates: [far, near], near: nil), far)
    }

    func testBallTrackTrailGapResetAndLabel() {
        var track = BallTrack()
        let t0 = Date()
        let det = { (x: CGFloat, label: String) in
            Detection(box: CGRect(x: x, y: 0.4, width: 0.03, height: 0.03),
                      label: label, confidence: 0.5)
        }
        track.update(with: det(0.10, "ball"), at: t0)
        track.update(with: det(0.15, "ball"), at: t0.addingTimeInterval(0.125))
        track.update(with: det(0.20, "ball-in-basket"), at: t0.addingTimeInterval(0.250))
        XCTAssertEqual(track.samples.count, 3)
        // The state label rides the sample — make/miss logic reads the track.
        XCTAssertEqual(track.last?.label, "ball-in-basket")
        // Gap since last sample (0.25s→1.7s = 1.45s) exceeds maxGap 1.0:
        // the track resets and the new sample starts a fresh flight.
        track.update(with: det(0.90, "ball"), at: t0.addingTimeInterval(1.7))
        XCTAssertEqual(track.samples.count, 1)
        XCTAssertEqual(track.last?.point.x ?? 0, 0.915, accuracy: 1e-9)
        // A nil update past maxGap clears everything.
        track.update(with: nil, at: t0.addingTimeInterval(3.0))
        XCTAssertTrue(track.samples.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: build FAILS — `pickBall` argument type, `Sample` has no `label`.

- [ ] **Step 3: Implement**

In `BallFinder.swift`:

```swift
    /// Labeled ball detections in one frame, best-confidence first. Lower
    /// confidence floor than the rim: the ball is small, fast, and often
    /// motion-blurred; the continuity gate does the filtering.
    /// `ball-in-basket` is a STATE of the ball — the label rides along so
    /// make/miss logic can read it from the track.
    static func detectBalls(in pixelBuffer: CVPixelBuffer, maxCount: Int) -> [Detection] {
        ObjectDetector.ball?.detect(labels: ["ball", "ball-in-basket", "Basketball", "basketball", "sports ball"],
                                      in: pixelBuffer,
                                      maxCount: maxCount, minConfidence: 0.25) ?? []
    }

    /// Which detected ball is THE ball: nearest to `anchor` (the last tracked
    /// position). No anchor → most confident (first). `within` caps the
    /// accepted distance so a second ball or a bald head across the frame
    /// can't steal the track. (Same rule as RimFinder.pickRim — duplicated
    /// on purpose: modules stay independently testable.)
    static func pickBall(candidates: [Detection], near anchor: CGPoint?,
                         within maxDistance: CGFloat? = nil) -> Detection? {
        guard let anchor else { return candidates.first }
        let nearest = candidates.min {
            hypot($0.box.midX - anchor.x, $0.box.midY - anchor.y)
                < hypot($1.box.midX - anchor.x, $1.box.midY - anchor.y)
        }
        if let maxDistance, let nearest,
           hypot(nearest.box.midX - anchor.x, nearest.box.midY - anchor.y) > maxDistance {
            return nil
        }
        return nearest
    }
```

`BallTrack`:

```swift
struct BallTrack {
    struct Sample: Equatable {
        let point: CGPoint      // box center, normalized top-left
        let box: CGRect
        let label: String       // "ball" or "ball-in-basket" (state)
        let at: Date
    }
    // … maxGap/maxAge/last unchanged …

    /// Feed one detection (or nil when nothing was found this tick).
    mutating func update(with detection: Detection?, at now: Date = Date()) {
        if let lastAt = samples.last?.at, now.timeIntervalSince(lastAt) > maxGap {
            samples.removeAll()
        }
        if let detection {
            samples.append(Sample(point: CGPoint(x: detection.box.midX, y: detection.box.midY),
                                  box: detection.box, label: detection.label, at: now))
        }
        samples.removeAll { now.timeIntervalSince($0.at) > maxAge }
    }
}
```

`RecordModel.handleBall` — only the parameter/variable types change:

```swift
    private func handleBall(candidates: [Detection]) {
        // Gate scales with the gap since the last sighting: a ball in flight
        // covers real distance between ticks.
        let anchor = ballTrack.last?.point
        let gap = ballTrack.last.map { Date().timeIntervalSince($0.at) } ?? .infinity
        let reach: CGFloat? = anchor == nil ? nil : min(0.15 + 0.35 * gap, 0.5)
        let chosen = BallFinder.pickBall(candidates: candidates, near: anchor, within: reach)
        ballTrack.update(with: chosen)
        // … rest unchanged …
```

(The Task-1 temporary `.map(\.box)` inside `detectBalls` disappears with this rewrite — the ball loop in `startBallTracking` already passes candidates straight to `handleBall`, so no other call site changes.)

- [ ] **Step 4: Run tests to verify they pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Ball/BallFinder.swift ios/CourtVision/Views/RecordView.swift \
        ios/CourtVisionTests/BallFinderTests.swift
git commit -m "feat(ball): labels ride the ball track"
```

---

### Task 4: PlayerTracker — stable IDs + persistent numbers

**Files:**
- Create: `ios/CourtVision/Services/Player/PlayerTracker.swift`
- Test: `ios/CourtVisionTests/PlayerTrackerTests.swift`

**Interfaces:**
- Consumes: `Detection` (Task 1), `PlayerFinder.iou` (Task 2), `PlayerAction` (defined in Task 5 — for THIS task give `TrackedPlayer` the field with a placeholder-free forward declaration: define `PlayerAction` here as `enum PlayerAction: Equatable { case none, possession, jumpShot, layupDunk, shotBlock }`; Task 5 adds its `init(label:)` in ActionClassifier.swift as an extension).
- Produces: `struct TrackedPlayer: Identifiable, Equatable { let id: Int; var box: CGRect; var action: PlayerAction; var missedTicks: Int; var numberTally: [String: Int]; var number: String? }`, `struct PlayerTracker { var maxMissedTicks: Int; var minIoU: CGFloat; private(set) var tracks: [TrackedPlayer]; mutating func update(with: [Detection]) -> [TrackedPlayer]; mutating func assign(numbers: [(point: CGPoint, digits: String)]) }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/PlayerTrackerTests.swift
import XCTest
@testable import CourtVision

final class PlayerTrackerTests: XCTestCase {
    private func det(_ x: CGFloat, _ y: CGFloat = 0.4) -> Detection {
        Detection(box: CGRect(x: x, y: y, width: 0.06, height: 0.22),
                  label: "player", confidence: 0.8)
    }

    func testStableIDsAcrossTicks() {
        var tracker = PlayerTracker()
        let first = tracker.update(with: [det(0.40), det(0.70)])
        XCTAssertEqual(first.map(\.id), [1, 2])
        // Both players drift slightly — IDs must not swap or churn.
        let second = tracker.update(with: [det(0.71), det(0.41)])
        XCTAssertEqual(Set(second.map(\.id)), [1, 2])
        XCTAssertEqual(second.first { $0.id == 1 }?.box.minX ?? 0, 0.41, accuracy: 1e-9)
    }

    func testTrackDiesAfterMaxMissedTicks() {
        var tracker = PlayerTracker()
        _ = tracker.update(with: [det(0.40)])
        for _ in 0..<4 { _ = tracker.update(with: []) }   // maxMissedTicks = 4
        XCTAssertTrue(tracker.tracks.isEmpty)
        // A returning player is a NEW identity.
        XCTAssertEqual(tracker.update(with: [det(0.40)]).map(\.id), [2])
    }

    func testNumberMajorityVotePersists() {
        var tracker = PlayerTracker()
        _ = tracker.update(with: [det(0.40)])
        let read = { (d: String) in [(point: CGPoint(x: 0.43, y: 0.5), digits: d)] }
        tracker.assign(numbers: read("23"))
        tracker.assign(numbers: read("28"))   // one misread
        tracker.assign(numbers: read("23"))
        XCTAssertEqual(tracker.tracks[0].number, "23")
        // Jersey turns away — no reads — the number persists with the track.
        _ = tracker.update(with: [det(0.41)])
        XCTAssertEqual(tracker.tracks[0].number, "23")
        // A read landing on no track is dropped (scoreboard digit).
        tracker.assign(numbers: [(point: CGPoint(x: 0.95, y: 0.05), digits: "7")])
        XCTAssertEqual(tracker.tracks[0].number, "23")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: build FAILS — `PlayerTracker` not found.

- [ ] **Step 3: Implement**

```swift
// ios/CourtVision/Services/Player/PlayerTracker.swift
import CoreGraphics
import Foundation

/// What a tracked player is DOING this tick (Layer 3 annotates it; `none`
/// between annotations). Cases mirror the model's state classes.
enum PlayerAction: Equatable {
    case none, possession, jumpShot, layupDunk, shotBlock
}

/// A player with cross-frame identity (Layer 2 output).
struct TrackedPlayer: Identifiable, Equatable {
    let id: Int
    var box: CGRect
    var action: PlayerAction = .none
    var missedTicks = 0
    /// Every jersey-number OCR read that landed on this track.
    var numberTally: [String: Int] = [:]
    /// Majority-vote jersey number; ties break to the smaller string so the
    /// result is deterministic. Persists while the track lives — a jersey
    /// facing away no longer blanks the number.
    var number: String? {
        numberTally.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first?.key
    }
}

/// Cross-frame player identity: greedy best-IoU association between the
/// previous tick's tracks and this tick's detections.
/// ponytail: greedy IoU at 2 Hz loses very fast movers — a center-distance
/// gate or Kalman prediction is the upgrade if ID churn shows in the field.
struct PlayerTracker {
    private(set) var tracks: [TrackedPlayer] = []
    private var nextID = 1
    /// Ticks a track survives unmatched (4 ≈ 2 s at the 2 Hz player cadence).
    var maxMissedTicks = 4
    /// Association floor: below this overlap a detection is a new player.
    var minIoU: CGFloat = 0.15

    @discardableResult
    mutating func update(with detections: [Detection]) -> [TrackedPlayer] {
        let boxes = detections.map(\.box)
        // All (track, box) pairs above the floor, best overlap first.
        var pairs: [(t: Int, b: Int, iou: CGFloat)] = []
        for (t, track) in tracks.enumerated() {
            for (b, box) in boxes.enumerated() {
                let s = PlayerFinder.iou(track.box, box)
                if s >= minIoU { pairs.append((t, b, s)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        var matchedTracks = Set<Int>(), matchedBoxes = Set<Int>()
        for p in pairs where !matchedTracks.contains(p.t) && !matchedBoxes.contains(p.b) {
            matchedTracks.insert(p.t)
            matchedBoxes.insert(p.b)
            tracks[p.t].box = boxes[p.b]
            tracks[p.t].missedTicks = 0
        }
        for t in tracks.indices where !matchedTracks.contains(t) {
            tracks[t].missedTicks += 1
        }
        tracks.removeAll { $0.missedTicks >= maxMissedTicks }
        for (b, box) in boxes.enumerated() where !matchedBoxes.contains(b) {
            tracks.append(TrackedPlayer(id: nextID, box: box))
            nextID += 1
        }
        // Action is per-tick: reset here, Layer 3 re-annotates.
        for i in tracks.indices { tracks[i].action = .none }
        return tracks
    }

    /// A jersey read lands on the track whose box contains the read's center
    /// (nearest center on overlap) and bumps that digit string's tally.
    /// A read landing on no track is dropped — scoreboard digits are not
    /// jersey numbers.
    mutating func assign(numbers: [(point: CGPoint, digits: String)]) {
        for number in numbers {
            var bestIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (i, track) in tracks.enumerated() where track.box.contains(number.point) {
                let d = hypot(track.box.midX - number.point.x,
                              track.box.midY - number.point.y)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            if let i = bestIndex { tracks[i].numberTally[number.digits, default: 0] += 1 }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Player/PlayerTracker.swift ios/CourtVisionTests/PlayerTrackerTests.swift
git commit -m "feat(player): PlayerTracker — stable IDs, persistent numbers"
```

---

### Task 5: ActionClassifier — state boxes annotate tracks

**Files:**
- Create: `ios/CourtVision/Services/Player/ActionClassifier.swift`
- Test: `ios/CourtVisionTests/ActionClassifierTests.swift`

**Interfaces:**
- Consumes: `Detection` (Task 1), `PlayerFinder.iou` (Task 2), `TrackedPlayer`, `PlayerAction` (Task 4).
- Produces: `PlayerAction.init(label: String)`, `PlayerAction.short: String`, `ActionClassifier.classify(states: [Detection], tracks: [TrackedPlayer], iouThreshold: CGFloat = 0.45) -> [TrackedPlayer]`.

- [ ] **Step 1: Write the failing tests**

```swift
// ios/CourtVisionTests/ActionClassifierTests.swift
import XCTest
@testable import CourtVision

final class ActionClassifierTests: XCTestCase {
    private let shooter = TrackedPlayer(id: 1, box: CGRect(x: 0.40, y: 0.40, width: 0.06, height: 0.22))
    private let defender = TrackedPlayer(id: 2, box: CGRect(x: 0.70, y: 0.42, width: 0.06, height: 0.20))

    func testStateAnnotatesBestIoUTrack() {
        let state = Detection(box: CGRect(x: 0.41, y: 0.41, width: 0.06, height: 0.22),
                              label: "player-jump-shot", confidence: 0.9)
        let out = ActionClassifier.classify(states: [state], tracks: [shooter, defender])
        XCTAssertEqual(out[0].action, .jumpShot)
        XCTAssertEqual(out[1].action, .none)
    }

    func testOrphanStateBoxIsDropped() {
        // A state box overlapping no track is a detector mistake by
        // construction — states cannot exist without a player.
        let orphan = Detection(box: CGRect(x: 0.05, y: 0.05, width: 0.06, height: 0.22),
                               label: "player-layup-dunk", confidence: 0.9)
        let out = ActionClassifier.classify(states: [orphan], tracks: [shooter])
        XCTAssertEqual(out[0].action, .none)
    }

    func testLabelMapping() {
        XCTAssertEqual(PlayerAction(label: "player-in-possession"), .possession)
        XCTAssertEqual(PlayerAction(label: "player-jump-shot"), .jumpShot)
        XCTAssertEqual(PlayerAction(label: "player-layup-dunk"), .layupDunk)
        XCTAssertEqual(PlayerAction(label: "player-shot-block"), .shotBlock)
        XCTAssertEqual(PlayerAction(label: "referee"), .none)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: build FAILS — `ActionClassifier` not found, `PlayerAction` has no `init(label:)`.

- [ ] **Step 3: Implement**

```swift
// ios/CourtVision/Services/Player/ActionClassifier.swift
import CoreGraphics

extension PlayerAction {
    /// Model state-class label → action. Unknown labels are `none`.
    init(label: String) {
        switch label {
        case "player-in-possession": self = .possession
        case "player-jump-shot":     self = .jumpShot
        case "player-layup-dunk":    self = .layupDunk
        case "player-shot-block":    self = .shotBlock
        default:                     self = .none
        }
    }

    /// Overlay badge text.
    var short: String {
        switch self {
        case .none: ""
        case .possession: "POS"
        case .jumpShot: "SHOT"
        case .layupDunk: "LAYUP"
        case .shotBlock: "BLOCK"
        }
    }
}

/// Layer 3: state-class detections ANNOTATE tracked players — they never
/// create objects of their own.
enum ActionClassifier {
    /// Each state box lands on the best-IoU track at or above `iouThreshold`
    /// (state boxes cover the same player the base box covers, so the dedupe
    /// constant 0.45 is the right floor). An orphan state box matches no
    /// track and is dropped.
    static func classify(states: [Detection], tracks: [TrackedPlayer],
                         iouThreshold: CGFloat = 0.45) -> [TrackedPlayer] {
        var out = tracks
        for state in states {
            var bestIndex: Int?
            var bestIoU = iouThreshold
            for (i, track) in out.enumerated() {
                let s = PlayerFinder.iou(track.box, state.box)
                if s > bestIoU { bestIoU = s; bestIndex = i }
            }
            if let i = bestIndex { out[i].action = PlayerAction(label: state.label) }
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Services/Player/ActionClassifier.swift ios/CourtVisionTests/ActionClassifierTests.swift
git commit -m "feat(player): ActionClassifier — states annotate tracks"
```

---

### Task 6: Wire the layers into RecordModel + overlay

**Files:**
- Modify: `ios/CourtVision/Views/RecordView.swift` (player loop `startPlayerTracking`, published `players`, overlay Canvas block)
- Modify: `ios/CourtVision/Services/Player/PlayerFinder.swift` (delete `DetectedPlayer`, `assign`, and the transitional `detectPlayers` shim)
- Modify: `ios/CourtVisionTests/PlayerFinderTests.swift` (delete `testNumberAssignment` — superseded by `testNumberMajorityVotePersists`)

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: `RecordModel.players: [TrackedPlayer]` (was `[DetectedPlayer]`) — the only published surface the overlay reads.

- [ ] **Step 1: Rewire the player loop**

In `RecordModel`:

```swift
    @Published var players: [TrackedPlayer] = []
    private var playerTracker = PlayerTracker()
```

Replace the body of `startPlayerTracking`'s detached work + handoff:

```swift
    /// 2 Hz player loop — detect (Layer 1) → track (Layer 2) → classify
    /// state + numbers (Layer 3). People move slower than the ball.
    private func startPlayerTracking() {
        guard playerTask == nil, let camera, ObjectDetector.player != nil else { return }
        playerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let pixelBuffer = camera.latestPixelBuffer else { continue }
                let (core, states, numbers) = await Task.detached(priority: .utility) {
                    () -> ([Detection], [Detection], [(point: CGPoint, digits: String)]) in
                    let raw = PlayerFinder.detectAll(in: pixelBuffer)
                    return (PlayerFinder.corePlayers(raw),
                            PlayerFinder.states(raw),
                            NumberReader.read(in: pixelBuffer))
                }.value
                if Task.isCancelled { return }
                self.playerTracker.update(with: core)
                self.playerTracker.assign(numbers: numbers)
                self.players = ActionClassifier.classify(states: states,
                                                         tracks: self.playerTracker.tracks)
                self.playerStatus = "Players: \(self.players.count)"
            }
        }
    }
```

- [ ] **Step 2: Update the overlay**

In the Canvas block, the player section becomes (action badge under the box when not `none`):

```swift
                        // Player boxes (cyan): jersey number top-right,
                        // action badge (SHOT/LAYUP/…) bottom-left.
                        for player in model.players {
                            let rect = layer.layerRectConverted(fromMetadataOutputRect: player.box)
                            context.stroke(Path(rect), with: .color(.cyan), lineWidth: 2)
                            if let number = player.number {
                                context.draw(
                                    Text("#\(number)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.cyan),
                                    at: CGPoint(x: rect.maxX - 2, y: rect.minY - 8),
                                    anchor: .bottomTrailing
                                )
                            }
                            if player.action != .none {
                                context.draw(
                                    Text(player.action.short)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.orange),
                                    at: CGPoint(x: rect.minX + 2, y: rect.maxY + 2),
                                    anchor: .topLeading
                                )
                            }
                        }
```

- [ ] **Step 3: Delete the superseded pieces**

In `PlayerFinder.swift` remove `DetectedPlayer`, `assign(numbers:to:)`, and the `detectPlayers` shim. In `PlayerFinderTests.swift` remove `testNumberAssignment`. Grep to confirm nothing else references them:

```bash
grep -rn "DetectedPlayer\|assign(numbers: \[\|detectPlayers" ios/ | grep -v PlayerTracker
```

Expected: no hits.

- [ ] **Step 4: Run all tests**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/CourtVision/Views/RecordView.swift ios/CourtVision/Services/Player/PlayerFinder.swift \
        ios/CourtVisionTests/PlayerFinderTests.swift
git commit -m "feat(record): wire detect->track->classify player pipeline"
```

---

### Task 7: Per-class eval tool + docs

**Files:**
- Create: `tools/eval_model.py`
- Modify: `docs/MODEL_PIPELINE.md` (§2 gains the layer description; §6 checklist gains the eval-tool line; §4 gains the guardrail)
- Modify: `tools/README.md` (usage line)

**Interfaces:**
- Consumes: repo `.venv` with ultralytics (already installed).
- Produces: `python tools/eval_model.py MODEL DATA [--imgsz N]` printing a per-class P/R/AP table.

- [ ] **Step 1: Write the tool**

```python
#!/usr/bin/env python3
"""Per-class eval for a YOLO checkpoint — the fixed-val-set gate.

ultralytics computes everything (per-class P/R/AP + confusion matrix);
this wrapper just prints the per-class table the mAP mean hides.

Usage:
    .venv/bin/python tools/eval_model.py runs/detect/runs/eagleeye/weights/best.pt DS/data.yaml
"""
import argparse

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", help="path to .pt checkpoint")
    parser.add_argument("data", help="path to data.yaml (fixed val set)")
    parser.add_argument("--imgsz", type=int, default=640)
    args = parser.parse_args()

    results = YOLO(args.model).val(data=args.data, imgsz=args.imgsz)
    box = results.box
    print(f"\n{'class':<24}{'P':>8}{'R':>8}{'AP50':>8}{'AP':>8}")
    for i, class_index in enumerate(box.ap_class_index):
        name = results.names[int(class_index)]
        print(f"{name:<24}{box.p[i]:>8.3f}{box.r[i]:>8.3f}"
              f"{box.ap50[i]:>8.3f}{box.ap[i]:>8.3f}")
    print(f"\nmAP50 {box.map50:.3f}  mAP50-95 {box.map:.3f}")
    print(f"confusion matrix + plots: {results.save_dir}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Smoke-test the tool**

```bash
.venv/bin/python tools/eval_model.py --help
```

Expected: usage text, exit 0. (Full eval needs a dataset on disk — that is a
training-time activity, not a repo test.)

- [ ] **Step 3: Update the docs**

`docs/MODEL_PIPELINE.md`:
- In §2 ("Tracking algorithms"), add at the top:

```markdown
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
```

- In §2 "Jersey numbers", replace the last sentence ("Persistent per-player
  identity requires cross-frame tracking (future work).") with:
  `Numbers persist per track via majority vote (PlayerTracker.assign).`
- In §4, after the "Why mAP plateaus" list, add:

```markdown
**Guardrail (adopted from expert review): no model split or retrain without
per-class failure evidence from the fixed val set** — run
`tools/eval_model.py` and read the per-class rows, not the mAP mean. The
14-image val set and the zero-rim-instance val split are the cautionary
examples.
```

- In §6, add a checklist line:
  `- [ ] tools/eval_model.py per-class table reviewed for the swapped model`

`tools/README.md`: add under usage:

```markdown
- `eval_model.py MODEL DATA [--imgsz N]` — per-class P/R/AP table +
  confusion matrix for a checkpoint against the fixed val set (the gate
  before any model swap; see docs/MODEL_PIPELINE.md §4).
```

- [ ] **Step 4: Final full verify**

Run the Global Constraints test command once more. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add tools/eval_model.py tools/README.md docs/MODEL_PIPELINE.md
git commit -m "feat(tools): per-class eval gate + layered-pipeline docs"
```
