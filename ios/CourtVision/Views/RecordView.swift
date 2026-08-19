import CoreMedia
import SwiftUI

/// Live recording: camera preview + overlay. All CV runs in `Engine` (one
/// tick per frame slot); this view only draws Moments.
///
/// Game sessions: the camera films one hoop at a time and pans on possession
/// change. Every second the rim + court are re-detected; a big court jump
/// flips the attacking team automatically.
struct RecordView: View {
    let session: Session
    let calibration: Calibration
    @EnvironmentObject private var flow: FlowModel
    @StateObject private var model = RecordModel()
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
                        // Locked rims, one per end, with the end letter.
                        for (end, rim) in model.rims.sorted(by: { $0.key < $1.key }) {
                            let rect = layer.layerRectConverted(fromMetadataOutputRect: rim)
                            context.stroke(Path(rect), with: .color(.orange), lineWidth: 3)
                            context.draw(Text(end).font(.caption.bold()).foregroundStyle(.orange),
                                         at: CGPoint(x: rect.minX + 2, y: rect.minY - 8), anchor: .bottomLeading)
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
                        // Referees: black, no id.
                        for ref in model.referees {
                            context.stroke(Path(layer.layerRectConverted(fromMetadataOutputRect: ref)),
                                           with: .color(.black), lineWidth: 2)
                        }
                        // Player boxes — team A blue, team B red, unassigned
                        // cyan: jersey number top-right, action badge
                        // (SHOT/LAYUP/…) bottom-left.
                        for player in model.players {
                            let color: Color = player.team == "A" ? .blue : player.team == "B" ? .red : .cyan
                            let rect = layer.layerRectConverted(fromMetadataOutputRect: player.box)
                            context.stroke(Path(rect), with: .color(color), lineWidth: 2)
                            if let number = player.number {
                                context.draw(
                                    Text("#\(number)")
                                        .font(.caption.bold())
                                        .foregroundStyle(color),
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
                    Text("Shots: \(model.shotCount) \(model.shotToast ?? "") · \(model.ballStatus) · \(model.playerStatus) · \(model.courtStatus) · \(model.tickStatus)")
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
                            // Jersey clusters: which color is team A.
                            Button("Teams ⇄") { model.swapTeams() }
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

/// Thin view-model over the `Engine`: pumps camera frames through it on the
/// engine clock, publishes each `Moment` for the overlay, keeps the server's
/// calibration current. Turning Moments into shot events is the shot module.
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
    @Published var referees: [CGRect] = []
    /// Locked rims by end — the overlay draws these (orange, lettered).
    @Published var rims: [String: CGRect] = [:]
    /// Engine cost per tick — the P0 cost table and the thermal watch.
    @Published var tickStatus = ""
    @Published var shotCount = 0
    @Published var shotToast: String?

    private var engine: Engine?
    private var session: Session?
    private var loopTask: Task<Void, Never>?
    private var lastPersistPts: Double = -.infinity
    private var sessionStartPts: Double?
    private var roster: [String: UUID] = [:]
    /// Resolved shots still waiting for a court fix (≤ 20 s, then dropped —
    /// never an invented location).
    private var pendingLocation: [ShotEvent] = []

    func toggleTeam() {
        attackingTeam = attackingTeam == "A" ? "B" : "A"
        engine?.attackingTeam = attackingTeam
    }

    /// Tap = "track THIS hoop" — first tap end A, second tap end B, a tap
    /// near an existing end moves that end.
    func designateRim(at point: CGPoint) {
        guard let engine else { return }
        engine.designateRim(at: point)
        rims = engine.rim.rims
        ManualRimDetector.shared.rimRects = RimTracker.endIds.compactMap { rims[$0] }
        trackState = .tracking
        trackingNote = nil
    }

    func swapTeams() {
        engine?.teamsSwapped.toggle()
    }

    func start(session: Session, calibration: Calibration,
               camera: CameraService, attackingTeam: String = "A",
               rimAnchors: [String: CGPoint] = [:]) {
        guard loopTask == nil else { return }
        self.session = session
        self.attackingTeam = attackingTeam
        // Rims persisted by the calibration screen seed the ends in order (A, B).
        var seeded: [String: CGRect] = [:]
        for (end, rim) in zip(RimTracker.endIds, ManualRimDetector.shared.rimRects) { seeded[end] = rim }
        let engine = Engine(calibration: calibration, isGame: session.mode == .game,
                            attackingTeam: attackingTeam, rimAnchors: rimAnchors,
                            initialRims: seeded)
        self.engine = engine
        if engine.court.h != nil { courtStatus = "Court: fixed from calibration" }
        if session.mode == .game {
            Task { [weak self] in
                let players = (try? await SupabaseService.shared.players()) ?? []
                self?.roster = RosterMap.build(players: players, teamId: session.teamId)
            }
        }

        let frames = camera.makeFrames()
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
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func publish(_ m: Moment, events: [ShotEvent], tickMs: Double) {
        guard let engine else { return }
        players = m.players
        ballTrail = engine.ballTrail
        let ballFresh = ballTrail.last.map { m.pts - $0.at.timeIntervalSinceReferenceDate < 0.5 } ?? false
        ballStatus = ballFresh ? "Ball: ✓" : "Ball: searching…"
        playerStatus = "Players: \(m.players.count)"
        tickStatus = String(format: "%.0f ms", tickMs)
        if engine.attackingTeam != attackingTeam { attackingTeam = engine.attackingTeam }
        referees = m.referees
        rims = m.rims
        let reacquiring = RimTracker.endIds.filter { engine.rim.state(of: $0) == .reacquiring }
        trackState = reacquiring.isEmpty ? .tracking : .reacquiring
        trackingNote = reacquiring.isEmpty ? nil : "Re-acquiring hoop \(reacquiring.joined(separator: "+"))… hold steady"
        let persisted = RimTracker.endIds.compactMap { m.rims[$0] }
        if !persisted.isEmpty, ManualRimDetector.shared.rimRects != persisted {
            ManualRimDetector.shared.rimRects = persisted
        }
        if let fit = engine.court.fitFt {
            courtStatus = "Court: live (fit \(Int(fit.rounded())) ft)"
        }
        if let h = m.h, m.pts - lastPersistPts > 10 {
            lastPersistPts = m.pts
            persistCalibration(corners: engine.court.quad, courtPoints: engine.court.courtPoints, h: h)
        }
        if sessionStartPts == nil { sessionStartPts = m.pts }
        for e in events {
            switch e.kind {
            case .attempt: shotToast = "Shot…"
            case .made, .missed: resolve(e, latest: m)
            }
        }
        flushPending(m)
    }

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
        guard let session, let start = sessionStartPts, let engine else { return }
        let number = players.first { $0.trackId == e.trackId }?.number
        let playerId = session.mode == .game ? number.flatMap { roster[$0] } : session.playerId
        // Team = the end the shot went at (falls back to the end in play).
        let end = e.end ?? attackingTeam
        let mirror = engine.lastMoment?.farEnds.contains(end) ?? false
        guard let row = ShotEventMapper.eventRow(e, court: court, session: session, sessionStartPts: start,
                                                 playerId: playerId,
                                                 team: session.mode == .game ? end : nil,
                                                 mirror: mirror)
        else { return }
        OfflineQueue.shared.enqueue(row)
        shotCount += 1
        shotToast = (row.made ? "✓ " : "✗ ") + row.category.rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
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
