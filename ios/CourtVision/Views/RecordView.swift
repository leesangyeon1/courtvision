import SwiftUI

/// Live recording: camera preview + trajectory overlay + rim box + local
/// PTS / FGM-FGA counters. Counters here are the on-device tally of REAL
/// detected events for instant feedback; the summary screen shows the
/// authoritative server-derived numbers.
///
/// Game sessions track continuously: every second the rim + court are
/// re-detected, so when the camera swings to the other hoop on a possession
/// change the app re-acquires the new end automatically and flips the
/// attacking team — no manual switching.
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
                    // Trajectory points and rim rects are buffer-space
                    // (capture-device normalized, top-left origin); convert
                    // through the preview layer for drawing.
                    Canvas { context, _ in
                        guard let layer = previewHolder.layer else { return }
                        // Ball trajectory (latest observation)
                        for p in model.trajectoryPoints {
                            let vp = layer.layerPointConverted(fromCaptureDevicePoint: p)
                            let rect = CGRect(x: vp.x - 3, y: vp.y - 3, width: 6, height: 6)
                            context.fill(Path(ellipseIn: rect), with: .color(.yellow))
                        }
                        // Live-tracked rim box
                        for rim in rimDetector.rimRects {
                            let rect = layer.layerRectConverted(fromMetadataOutputRect: rim)
                            context.stroke(Path(rect), with: .color(
                                model.trackState == .tracking ? .orange : .yellow), lineWidth: 3)
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
                    if session.mode == .game {
                        HStack(spacing: 24) {
                            teamStat(team: "A")
                            Text("·").foregroundStyle(.secondary)
                            teamStat(team: "B")
                        }
                    } else {
                        HStack(spacing: 24) {
                            stat("PTS", "\(model.pts)")
                            stat("FG", "\(model.fgm)-\(model.fga)")
                            stat("Shots", "\(model.events.count)")
                        }
                    }
                    if let last = model.lastShotLabel {
                        Text(last).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    HStack(spacing: 16) {
                        if session.mode == .game {
                            // Manual override for the automatic end detection
                            // — flips attribution only, no recalibration.
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

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func teamStat(team: String) -> some View {
        let (pts, fgm, fga) = model.teamLine(team)
        let attacking = model.attackingTeam == team
        return VStack {
            Text("\(pts)").font(.title2.monospacedDigit().bold())
            Text("\(attacking ? "▶ " : "")\(name(team)) · FG \(fgm)-\(fga)")
                .font(.caption)
                .foregroundStyle(attacking ? .primary : .secondary)
        }
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

/// Owns the detection pipeline: camera frames → ball trajectories + pose →
/// shot state machine → homography → zone/category → offline queue → Supabase.
///
/// Plus the 1 Hz tracking loop: rim + court re-detected live so the camera
/// can pan between hoops mid-session. Rim drift is followed; a big rim jump
/// or a lost rim suspends shot decisions and re-acquires the court; a locked
/// re-acquisition whose court quad moved far from the previous lock means
/// the camera swung to the OTHER hoop → attacking team flips automatically.
@MainActor
final class RecordModel: ObservableObject {
    enum TrackState { case tracking, reacquiring }

    @Published var events: [EventRow] = []
    @Published var trajectoryPoints: [CGPoint] = []
    @Published var lastShotLabel: String?
    @Published var attackingTeam = "A"
    @Published var trackState: TrackState = .tracking
    @Published var trackingNote: String?

    private let ballTracker = BallTracker()
    private let poseService = PoseService()
    private let shotDetector = ShotDetector()
    private var homography: Homography?
    private var session: Session?
    private var camera: CameraService?
    private var startedAt = Date()
    private var frameTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var lockedQuad: [CGPoint] = []
    private var lastRimSeen = Date()
    /// Tap-designated rim spot per end (keyed by attacking team) — gyms hang
    /// side hoops; the anchor says which one is the game hoop.
    private var rimAnchors: [String: CGPoint] = [:]
    private var lastRimCandidates: [CGRect] = []
    private var lastFlipAt = Date.distantPast
    private var lastPersist = Date.distantPast
    private var stableRimTicks = 0
    /// Shots seen before any court fix — resolved when the next homography
    /// lands (camera is steady during a shot, so a fix seconds later is
    /// still the same pose). Expire rather than fake a location.
    private var pendingShots: [(shot: DetectedShot, at: Date)] = []

    var fga: Int { events.filter { $0.category != .free_throw }.count }
    var fgm: Int { events.filter { $0.category != .free_throw && $0.made }.count }
    /// Scoring keys off category, matching the SQL aggregate: three = 3,
    /// free throw = 1, everything else = 2.
    var pts: Int {
        events.filter(\.made).reduce(0) { total, e in
            total + (e.category == .three ? 3 : e.category == .free_throw ? 1 : 2)
        }
    }

    /// (pts, fgm, fga) for one team's events — the live game HUD line.
    func teamLine(_ team: String) -> (pts: Int, fgm: Int, fga: Int) {
        let te = events.filter { $0.team == team }
        let pts = te.filter(\.made).reduce(0) { total, e in
            total + (e.category == .three ? 3 : e.category == .free_throw ? 1 : 2)
        }
        return (pts,
                te.filter { $0.category != .free_throw && $0.made }.count,
                te.filter { $0.category != .free_throw }.count)
    }

    func toggleTeam() {
        attackingTeam = attackingTeam == "A" ? "B" : "A"
    }

    /// Tap = "track THIS hoop". Snaps to the nearest detected candidate
    /// (within 12% of the frame) or places a default box, remembers the spot
    /// as this end's anchor, and resumes tracking on it immediately.
    func designateRim(at point: CGPoint) {
        let snapped = RimFinder.pickRim(candidates: lastRimCandidates, near: point)
            .flatMap { hypot($0.midX - point.x, $0.midY - point.y) < 0.12 ? $0 : nil }
        let rim = snapped.map { $0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.15) }
            ?? CGRect(x: point.x - 0.05, y: point.y - 0.03, width: 0.10, height: 0.06)
        rimAnchors[attackingTeam] = point
        ManualRimDetector.shared.rimRects = [rim]
        shotDetector.rimRects = [rim]
        lastRimSeen = Date()
        if trackState == .reacquiring {
            trackState = .tracking
            trackingNote = nil
        }
    }

    func start(session: Session, calibration: Calibration,
               camera: CameraService, attackingTeam: String = "A",
               rimAnchors: [String: CGPoint] = [:]) {
        guard frameTask == nil else { return }
        self.session = session
        self.camera = camera
        self.homography = Homography(matrix: calibration.homography)
        self.startedAt = session.startedAt ?? Date()
        self.attackingTeam = attackingTeam
        self.rimAnchors = rimAnchors
        self.lockedQuad = calibration.imagePoints.compactMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        }
        self.lastRimSeen = Date()

        shotDetector.rimRects = ManualRimDetector.shared.rimRects
        ballTracker.onUpdate = { [weak self] update in
            guard let self else { return }
            self.shotDetector.ingest(update)
            Task { @MainActor in self.trajectoryPoints = update.points }
        }
        shotDetector.onShot = { [weak self] shot in
            Task { @MainActor in self?.record(shot) }
        }

        let tracker = ballTracker
        let pose = poseService
        frameTask = Task.detached(priority: .userInitiated) {
            for await buffer in camera.frames {
                if Task.isCancelled { break }
                tracker.process(buffer)
                pose.process(buffer)
            }
        }

        startTracking()
    }

    func stop() {
        frameTask?.cancel()
        frameTask = nil
        trackTask?.cancel()
        trackTask = nil
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

    private func handleTrack(rims: [CGRect], quadCandidates: [[CGPoint]]) {
        lastRimCandidates = rims
        // ---- rim: gates shot decisions only -------------------------------
        switch trackState {
        case .tracking:
            // Side hoops: track the candidate nearest where the rim already
            // is (or this end's tap anchor), not the most confident one.
            let anchor = shotDetector.rimRects.first.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? rimAnchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: rims, near: anchor) {
                let padded = r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)
                if let current = shotDetector.rimRects.first,
                   hypot(padded.midX - current.midX, padded.midY - current.midY) > 0.15 {
                    // Nearest rim still jumped across the frame — camera moving.
                    beginReacquire()
                } else {
                    lastRimSeen = Date()
                    // Follow small drift so the rim box stays glued on.
                    shotDetector.rimRects = [padded]
                    ManualRimDetector.shared.rimRects = [padded]
                }
            } else if Date().timeIntervalSince(lastRimSeen) > 2.5 {
                // No rim for a while — camera is swinging to the other end.
                beginReacquire()
            }

        case .reacquiring:
            // Prefer the other end's tap anchor (if set) — that's the hoop
            // we're swinging toward.
            let otherTeam = attackingTeam == "A" ? "B" : "A"
            let target = rimAnchors[otherTeam] ?? rimAnchors[attackingTeam]
            if let r = RimFinder.pickRim(candidates: rims, near: target) {
                lastRimSeen = Date()
                ManualRimDetector.shared.rimRects =
                    [r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)]
                stableRimTicks += 1
                if stableRimTicks >= 2 {   // rim steady two ticks → shots back on
                    shotDetector.rimRects = ManualRimDetector.shared.rimRects
                    trackState = .tracking
                    trackingNote = nil
                }
            } else {
                stableRimTicks = 0
            }
        }

        // ---- court: continuous best-effort estimate — NEVER a hard lock ---
        // The camera pans all game; every tick the best rim-consistent quad
        // (if any) refreshes the homography. No stability gate.
        guard let rim = ManualRimDetector.shared.rimRects.first,
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
        drainPendingShots()
        if Date().timeIntervalSince(lastPersist) > 10 {
            lastPersist = Date()
            persistCalibration(corners: best.quad, courtPoints: pick.courtPoints, h: h)
        }
    }

    /// Resolve shots that arrived before a court fix (≤ 20 s old — the same
    /// camera pose); older ones are dropped, never given a fake location.
    private func drainPendingShots() {
        guard homography != nil, !pendingShots.isEmpty else { return }
        let queued = pendingShots
        pendingShots = []
        for entry in queued where Date().timeIntervalSince(entry.at) <= 20 {
            record(entry.shot)
        }
    }

    private func beginReacquire() {
        trackState = .reacquiring
        stableRimTicks = 0
        // Suspend shot decisions while the view is unstable — a panning
        // camera feeds the trajectory detector phantom parabolas.
        shotDetector.rimRects = []
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

    // -------------------------------------------------------- shot recording

    private func record(_ shot: DetectedShot) {
        guard let session else { return }
        guard let homography else {
            pendingShots.append((shot, Date()))
            lastShotLabel = "\(shot.made ? "MAKE" : "MISS") · waiting for court fix…"
            return
        }
        let isGame = session.mode == .game

        // Shooter's floor position: ankle midpoint at release; if the pose was
        // not visible, fall back to the ball's release point (documented).
        // Both are buffer-space points (capture-device normalized, top-left
        // origin) — the same space as the calibration points behind the
        // homography.
        let pose = poseService.sample(nearest: shot.timestamp)
        let imagePoint = pose?.ankleMidpoint ?? shot.releasePoint
        let court = homography.apply(imagePoint)   // half-court feet
        let xFt = min(max(Double(court.x), 0), ZoneMapper.courtWidthFt)
        let yFt = min(max(Double(court.y), 0), ZoneMapper.courtDepthFt)

        // One hoop in frame — every shot belongs to the team attacking it.
        let team: String? = isGame ? attackingTeam : nil

        let freeThrowMode = session.mode == .freethrow
        let zone = ZoneMapper.zone(xFt: xFt, yFt: yFt, freeThrow: freeThrowMode)
        let category = ZoneMapper.category(xFt: xFt, yFt: yFt,
                                           freeThrowMode: freeThrowMode,
                                           releaseAtRim: shot.releaseAtRim)
        let (courtX, courtY) = ZoneMapper.normalized(xFt: xFt, yFt: yFt)

        let event = EventRow(
            id: UUID(),
            sessionId: session.id,
            userId: nil,
            ts: max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
            wallClock: nil,
            playerId: session.playerId,
            confidence: min(max(shot.confidence, 0), 1),
            made: shot.made,
            category: category,
            zone: zone,
            courtX: courtX,
            courtY: courtY,
            releaseAngleDeg: shot.releaseAngleDeg,
            releaseTimeMs: shot.releaseTimeMs,
            team: team
        )
        events.append(event)
        lastShotLabel = "\(shot.made ? "MAKE" : "MISS") · \(zone.rawValue) · \(category.rawValue)"
        OfflineQueue.shared.enqueue(event)
    }
}
