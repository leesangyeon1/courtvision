import SwiftUI

/// Live recording: camera preview + live rim tracking + continuous court
/// estimation. Ball trajectory / shot detection is intentionally ABSENT for
/// now — the previous approach produced junk data and was removed for a
/// clean restart (Ball module). Rim + court acquisition stay: they are the
/// foundation the next shot pipeline plugs into (`onCourtFix` region).
///
/// Game sessions: the camera films one hoop at a time and pans on possession
/// change. Every second the rim + court are re-detected; a big court jump
/// flips the attacking team automatically.
struct RecordView: View {
    let session: Session
    let calibration: Calibration
    @EnvironmentObject private var flow: FlowModel
    @StateObject private var model = RecordModel()
    @ObservedObject private var rimDetector = ManualRimDetector.shared
    @StateObject private var previewHolder = PreviewLayerHolder()
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            CameraPreviewView(camera: flow.camera, holder: previewHolder)
                .overlay {
                    // Rim rect is buffer-space (capture-device normalized,
                    // top-left origin); convert through the preview layer.
                    Canvas { context, _ in
                        guard let layer = previewHolder.layer else { return }
                        for rim in rimDetector.rimRects {
                            let rect = layer.layerRectConverted(fromMetadataOutputRect: rim)
                            context.stroke(Path(rect), with: .color(
                                model.trackState == .tracking ? .orange : .yellow), lineWidth: 3)
                        }
                        // Ball trail: fading dots ending in a circle on the
                        // current position (same visual language as the rim).
                        let samples = model.ballTrail
                        for (i, sample) in samples.enumerated() {
                            let vp = layer.layerPointConverted(fromCaptureDevicePoint: sample.point)
                            let alpha = 0.25 + 0.75 * Double(i + 1) / Double(samples.count)
                            let dot = CGRect(x: vp.x - 3, y: vp.y - 3, width: 6, height: 6)
                            context.fill(Path(ellipseIn: dot), with: .color(.yellow.opacity(alpha)))
                        }
                        if let current = samples.last {
                            let rect = layer.layerRectConverted(fromMetadataOutputRect: current.box)
                            context.stroke(Path(ellipseIn: rect), with: .color(.yellow), lineWidth: 2)
                        }
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
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard let layer = previewHolder.layer else { return }
                    model.designateRim(at: layer.captureDevicePointConverted(fromLayerPoint: location))
                }
                .ignoresSafeArea()

            VStack {
                // Tracking state pill, top-centre.
                if let note = model.trackingNote {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(note).font(.footnote.bold())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 2)
                }

                Spacer()

                VStack(spacing: 6) {
                    Text("\(model.ballStatus) · \(model.playerStatus) · \(model.courtStatus)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    HStack(spacing: 16) {
                        if session.mode == .game {
                            // Manual override for the automatic end detection.
                            Button("Attacking: \(name(model.attackingTeam)) ⇄") {
                                model.toggleTeam()
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                        }
                        Button(busy ? "Ending…" : "End Session") { endSession() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(busy)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            do {
                try await flow.camera.configureIfNeeded()
                flow.camera.start()
                model.start(session: session, calibration: calibration,
                            camera: flow.camera, attackingTeam: flow.attackingTeam,
                            rimAnchors: flow.rimAnchors)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: model.attackingTeam) { _, team in
            flow.attackingTeam = team
        }
        .onDisappear { model.stop() }
    }

    private func name(_ team: String) -> String {
        team == "A" ? (session.teamA ?? "Team A") : (session.teamB ?? "Team B")
    }

    private func endSession() {
        busy = true
        errorMessage = nil
        Task {
            model.stop()
            flow.camera.stop()
            do {
                try await SupabaseService.shared.endSession(id: session.id)
                flow.path.append(.summary(session))
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Rim + court tracking only (ball/shot pipeline removed for a clean
/// restart): a 1 Hz loop re-detects the rim (anchor-gated, so side hoops
/// can't steal the box) and continuously refreshes the court homography —
/// the camera pans all game, nothing hard-locks. A far court jump means the
/// camera swung to the other hoop → attacking team flips.
@MainActor
final class RecordModel: ObservableObject {
    enum TrackState { case tracking, reacquiring }

    @Published var attackingTeam = "A"
    @Published var trackState: TrackState = .tracking
    @Published var trackingNote: String?
    @Published var courtStatus = "Court: waiting for first fix…"
    @Published var ballStatus = "Ball: searching…"
    /// Recent ball positions for the overlay trail (newest last).
    @Published var ballTrail: [BallTrack.Sample] = []
    @Published var playerStatus = "Players: —"
    @Published var players: [TrackedPlayer] = []

    private var homography: Homography?
    private var session: Session?
    private var camera: CameraService?
    private var trackTask: Task<Void, Never>?
    /// Rim currently locked on (normalized buffer coords, top-left origin).
    private var trackedRim: CGRect?
    private var lockedQuad: [CGPoint] = []
    private var lastRimSeen = Date()
    private var lastFlipAt = Date.distantPast
    private var lastPersist = Date.distantPast
    private var stableRimTicks = 0
    /// Tap-designated rim spot per end (keyed by attacking team) — gyms hang
    /// side hoops; the anchor says which one is the game hoop.
    private var rimAnchors: [String: CGPoint] = [:]
    private var lastRimCandidates: [CGRect] = []
    private var ballTask: Task<Void, Never>?
    private var ballTrack = BallTrack()
    private var playerTask: Task<Void, Never>?
    private var playerTracker = PlayerTracker()

    func toggleTeam() {
        attackingTeam = attackingTeam == "A" ? "B" : "A"
    }

    /// Tap = "track THIS hoop". Snaps to the nearest detected candidate
    /// (within 12% of the frame) or places a default box, remembers the spot
    /// as this end's anchor, and resumes tracking on it immediately.
    func designateRim(at point: CGPoint) {
        let snapped = RimFinder.pickRim(candidates: lastRimCandidates, near: point, within: 0.12)
        let rim = snapped.map { $0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.15) }
            ?? CGRect(x: point.x - 0.05, y: point.y - 0.03, width: 0.10, height: 0.06)
        rimAnchors[attackingTeam] = point
        ManualRimDetector.shared.rimRects = [rim]
        trackedRim = rim
        lastRimSeen = Date()
        if trackState == .reacquiring {
            trackState = .tracking
            trackingNote = nil
        }
    }

    func start(session: Session, calibration: Calibration,
               camera: CameraService, attackingTeam: String = "A",
               rimAnchors: [String: CGPoint] = [:]) {
        guard trackTask == nil else { return }
        self.session = session
        self.camera = camera
        self.homography = Homography(matrix: calibration.homography)
        self.attackingTeam = attackingTeam
        self.rimAnchors = rimAnchors
        self.lockedQuad = calibration.imagePoints.compactMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        }
        self.trackedRim = ManualRimDetector.shared.rimRects.first
        self.lastRimSeen = Date()
        if homography != nil { courtStatus = "Court: fixed from calibration" }
        startTracking()
        startBallTracking()
        startPlayerTracking()
    }

    func stop() {
        trackTask?.cancel()
        trackTask = nil
        ballTask?.cancel()
        ballTask = nil
        playerTask?.cancel()
        playerTask = nil
    }

    // -------------------------------------------------------- live tracking

    /// 1 Hz rim + court re-detection for the whole recording.
    private func startTracking() {
        guard trackTask == nil, let camera else { return }
        trackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let pixelBuffer = camera.latestPixelBuffer else { continue }
                let (rims, quadCandidates) = await Task.detached(priority: .utility) {
                    (RimFinder.detectRims(in: pixelBuffer, maxCount: 4),
                     CourtFinder.detectCourtQuadCandidates(in: pixelBuffer))
                }.value
                if Task.isCancelled { return }
                self.handleTrack(rims: rims, quadCandidates: quadCandidates)
            }
        }
    }

    /// 8 Hz ball loop — same mechanism as the rim, faster cadence because
    /// the ball moves: detect candidates, keep the one nearest the current
    /// track (continuity gate), feed the trail.
    private func startBallTracking() {
        guard ballTask == nil, let camera else { return }
        ballTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 125_000_000)
                guard let self, let pixelBuffer = camera.latestPixelBuffer else { continue }
                let balls = await Task.detached(priority: .userInitiated) {
                    BallFinder.detectBalls(in: pixelBuffer, maxCount: 4)
                }.value
                if Task.isCancelled { return }
                self.handleBall(candidates: balls)
            }
        }
    }

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

    private func handleBall(candidates: [Detection]) {
        // Gate scales with the gap since the last sighting: a ball in flight
        // covers real distance between ticks.
        let anchor = ballTrack.last?.point
        let gap = ballTrack.last.map { Date().timeIntervalSince($0.at) } ?? .infinity
        let reach: CGFloat? = anchor == nil ? nil : min(0.15 + 0.35 * gap, 0.5)
        let chosen = BallFinder.pickBall(candidates: candidates, near: anchor, within: reach)
        ballTrack.update(with: chosen)
        ballTrail = ballTrack.samples
        if let last = ballTrack.last, Date().timeIntervalSince(last.at) < 0.5 {
            ballStatus = "Ball: ✓"
        } else {
            ballStatus = "Ball: searching…"
        }
    }

    private func handleTrack(rims: [CGRect], quadCandidates: [[CGPoint]]) {
        lastRimCandidates = rims

        // ---- rim ----------------------------------------------------------
        switch trackState {
        case .tracking:
            let anchor = trackedRim.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? rimAnchors[attackingTeam]
            // Only follow detections near the rim we're locked on — a side
            // hoop elsewhere in frame must not steal the box.
            if let r = RimFinder.pickRim(candidates: rims, near: anchor,
                                         within: anchor != nil ? 0.2 : nil) {
                let padded = r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
                if let current = trackedRim,
                   hypot(padded.midX - current.midX, padded.midY - current.midY) > 0.15 {
                    beginReacquire()   // rim jumped — camera moving
                } else {
                    lastRimSeen = Date()
                    trackedRim = padded
                    ManualRimDetector.shared.rimRects = [padded]
                }
            } else if Date().timeIntervalSince(lastRimSeen) > 4.0 {
                // 4 s: players occlude the rim mid-play constantly — don't
                // drop into reacquire for a normal contested possession.
                beginReacquire()       // rim gone — camera swinging to other end
            }

        case .reacquiring:
            // Prefer the other end's tap anchor (if set) — that's the hoop
            // we're swinging toward.
            let otherTeam = attackingTeam == "A" ? "B" : "A"
            let target = rimAnchors[otherTeam] ?? rimAnchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: rims, near: target,
                                         within: target != nil ? 0.25 : nil) {
                lastRimSeen = Date()
                let padded = r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
                trackedRim = padded
                ManualRimDetector.shared.rimRects = [padded]
                stableRimTicks += 1
                if stableRimTicks >= 2 {   // rim steady two ticks → locked again
                    trackState = .tracking
                    trackingNote = nil
                }
            } else {
                stableRimTicks = 0
            }
        }

        // ---- court: continuous best-effort estimate — NEVER a hard lock ---
        guard let rim = trackedRim,
              let best = CourtFinder.bestQuad(candidates: quadCandidates,
                                              rims: [rim], fullCourt: false),
              best.score <= 15,
              let pick = CourtFinder.scoreCourtAssignments(quad: best.quad, rims: [rim],
                                                           fullCourt: false),
              let h = Homography(from: best.quad, to: pick.courtPoints) else { return }

        // Court jumped far from the previous estimate → the camera swung to
        // the other hoop → possession switched (cooldown stops re-flips
        // while the pan settles).
        let meanDelta = zip(best.quad, lockedQuad)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .reduce(0, +) / CGFloat(max(lockedQuad.count, 1))
        if session?.mode == .game, !lockedQuad.isEmpty, meanDelta > 0.2,
           Date().timeIntervalSince(lastFlipAt) > 5 {
            toggleTeam()
            lastFlipAt = Date()
        }

        homography = h
        lockedQuad = best.quad
        courtStatus = "Court: live (fit \(String(format: "%.0f", best.score)) ft)"
        if Date().timeIntervalSince(lastPersist) > 10 {
            lastPersist = Date()
            persistCalibration(corners: best.quad, courtPoints: pick.courtPoints, h: h)
        }
        // onCourtFix: the future shot pipeline consumes `homography` here.
    }

    private func beginReacquire() {
        trackState = .reacquiring
        stableRimTicks = 0
        trackingNote = "Re-acquiring hoop… hold steady"
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
