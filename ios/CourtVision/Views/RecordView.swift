import SwiftUI

/// Live recording: camera preview + trajectory overlay + rim box + local
/// PTS / FGM-FGA counters. Counters here are the on-device tally of REAL
/// detected events for instant feedback; the summary screen shows the
/// authoritative server-derived numbers.
struct RecordView: View {
    let session: Session
    let calibration: Calibration
    @EnvironmentObject private var flow: FlowModel
    @StateObject private var model = RecordModel()
    @ObservedObject private var rimDetector = ManualRimDetector.shared
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    CameraPreviewView(camera: flow.camera)

                    Canvas { context, size in
                        // Ball trajectory (latest observation)
                        for p in model.trajectoryPoints {
                            let rect = CGRect(x: p.x * size.width - 3,
                                              y: p.y * size.height - 3,
                                              width: 6, height: 6)
                            context.fill(Path(ellipseIn: rect), with: .color(.yellow))
                        }
                        // Rim box
                        if let rim = rimDetector.rimRect {
                            let rect = CGRect(x: rim.origin.x * size.width,
                                              y: rim.origin.y * size.height,
                                              width: rim.width * size.width,
                                              height: rim.height * size.height)
                            context.stroke(Path(rect), with: .color(.orange), lineWidth: 3)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }

            VStack(spacing: 6) {
                HStack(spacing: 24) {
                    stat("PTS", "\(model.pts)")
                    stat("FG", "\(model.fgm)-\(model.fga)")
                    stat("Shots", "\(model.events.count)")
                }
                if let last = model.lastShotLabel {
                    Text(last).font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                Button(busy ? "Ending…" : "End Session") { endSession() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(busy)
            }
            .padding()
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task {
            do {
                try await flow.camera.configureIfNeeded()
                flow.camera.start()
                model.start(session: session, calibration: calibration, camera: flow.camera)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear { model.stop() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
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
@MainActor
final class RecordModel: ObservableObject {
    @Published var events: [EventRow] = []
    @Published var trajectoryPoints: [CGPoint] = []
    @Published var lastShotLabel: String?

    private let ballTracker = BallTracker()
    private let poseService = PoseService()
    private let shotDetector = ShotDetector()
    private var homography: Homography?
    private var session: Session?
    private var startedAt = Date()
    private var frameTask: Task<Void, Never>?

    var fga: Int { events.filter { $0.category != .free_throw }.count }
    var fgm: Int { events.filter { $0.category != .free_throw && $0.made }.count }
    /// Scoring keys off category, matching the SQL aggregate: three = 3,
    /// free throw = 1, everything else = 2.
    var pts: Int {
        events.filter(\.made).reduce(0) { total, e in
            total + (e.category == .three ? 3 : e.category == .free_throw ? 1 : 2)
        }
    }

    func start(session: Session, calibration: Calibration, camera: CameraService) {
        guard frameTask == nil else { return }
        self.session = session
        self.homography = Homography(matrix: calibration.homography)
        self.startedAt = session.startedAt ?? Date()

        shotDetector.rimRect = ManualRimDetector.shared.rimRect
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
    }

    func stop() {
        frameTask?.cancel()
        frameTask = nil
    }

    private func record(_ shot: DetectedShot) {
        guard let session, let homography else { return }

        // Shooter's floor position: ankle midpoint at release; if the pose was
        // not visible, fall back to the ball's release point (documented).
        let pose = poseService.sample(nearest: shot.timestamp)
        let imagePoint = pose?.ankleMidpoint ?? shot.releasePoint
        let court = homography.apply(imagePoint)   // feet
        let xFt = min(max(Double(court.x), 0), ZoneMapper.courtWidthFt)
        let yFt = min(max(Double(court.y), 0), ZoneMapper.courtDepthFt)

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
            releaseTimeMs: shot.releaseTimeMs
        )
        events.append(event)
        lastShotLabel = "\(shot.made ? "MAKE" : "MISS") · \(zone.rawValue) · \(category.rawValue)"
        OfflineQueue.shared.enqueue(event)
    }
}
