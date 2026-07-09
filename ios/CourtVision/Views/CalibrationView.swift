import SwiftUI

/// Fully automatic calibration (HomeCourt-style — no manual tapping):
/// 1. The app scans live frames for the court quad (rectangle detection) and
///    the rim(s) (trained YOLO CNN, orange-blob fallback).
/// 2. Detections must stay stable across frames before locking in
///    (CourtFinder.stableQuad).
/// 3. Court orientation is resolved by NEX-patent-style candidate scoring:
///    the assignment that projects the detected rims nearest the real hoop
///    positions wins (CourtFinder.scoreCourtAssignments).
/// 4. The user can drag the corner markers and rim boxes to refine, then
///    saves → DLT homography (buffer coords → court feet) stored on the
///    session; rim boxes persist on-device.
struct CalibrationView: View {
    let session: Session
    @EnvironmentObject private var flow: FlowModel
    @ObservedObject private var rimDetector = ManualRimDetector.shared
    @StateObject private var previewHolder = PreviewLayerHolder()

    /// Detected court corners — buffer space (capture-device) normalized,
    /// top-left origin — in landmark order [near-left, far-left, near-right,
    /// far-right]. Empty until a stable detection locks in.
    @State private var corners: [CGPoint] = []
    /// Court-feet targets parallel to `corners`, chosen by rim scoring.
    @State private var courtTargets: [CGPoint] = []
    @State private var status = "Starting camera…"
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var cameraReady = false
    @State private var scanning = false
    @State private var scanTask: Task<Void, Never>?
    /// All rim candidates from the latest scan tick (side hoops included) —
    /// a tap snaps the rim box to the nearest one.
    @State private var rimCandidates: [CGRect] = []
    /// Rim confirmed by detection or by a tap — the only hard requirement.
    @State private var rimConfirmed = false

    private var isGame: Bool { session.mode == .game }
    /// One hoop at a time — the camera swings to the other end on possession
    /// change and recalibrates there (Switch End in the record screen).
    private var rimCount: Int { 1 }
    /// Recording needs only the rim: the camera pans all game, so the court
    /// is a live, continuously refreshed estimate during recording — never a
    /// physical lock. A court fix found here just seeds the first homography.
    private var locked: Bool { rimConfirmed }

    /// Team attacking the hoop currently in frame.
    private var attackingName: String {
        flow.attackingTeam == "A" ? (session.teamA ?? "Team A") : (session.teamB ?? "Team B")
    }

    var body: some View {
        ZStack {
            if cameraReady {
                CameraPreviewView(camera: flow.camera, holder: previewHolder)
                    .overlay {
                        ForEach(corners.indices, id: \.self) { i in
                            cornerMarker(index: i)
                        }
                        ForEach(rimDetector.rimRects.indices, id: \.self) { i in
                            rimBox(index: i)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let layer = previewHolder.layer else { return }
                        designateRim(at: layer.captureDevicePointConverted(fromLayerPoint: location))
                    }
                    .ignoresSafeArea()
            } else {
                Rectangle().fill(.black).ignoresSafeArea()
                Text(errorMessage ?? "Starting camera…")
                    .foregroundStyle(.white)
                    .padding()
            }

            VStack {
                // Compact status pill, top-centre — never covers the court.
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if scanning { ProgressView().controlSize(.mini) }
                        Text(status).font(.footnote.bold())
                    }
                    if isGame {
                        Text("Attacking this hoop: \(attackingName)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let errorMessage, cameraReady {
                        Text(errorMessage).font(.caption2).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 2)

                Spacer()

                // Slim button strip at the very bottom edge.
                HStack(spacing: 14) {
                    Button("Re-scan") { startScan() }
                        .disabled(scanning || !cameraReady)
                    if isGame {
                        Button("Swap Team") { flow.attackingTeam = flow.attackingTeam == "A" ? "B" : "A" }
                    }
                    Spacer()
                    Button(busy ? "Saving…" : "Save & Record") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(busy || !locked)
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.bottom, 2)
            }
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { rimDetector.ensureCount(rimCount) }
        .onDisappear { scanTask?.cancel() }
        .task {
            do {
                try await flow.camera.configureIfNeeded()
                flow.camera.start()
                cameraReady = true
                startScan()
            } catch {
                errorMessage = error.localizedDescription
                status = "Camera unavailable"
            }
        }
    }

    // ------------------------------------------------------------- scanning

    /// Continuous scan: detect court quad + rims every 0.4 s, lock in once
    /// the quad is stable across frames AND rim scoring accepts an
    /// orientation. Gives up with guidance after ~12 s.
    private func startScan() {
        scanTask?.cancel()
        corners = []
        courtTargets = []
        errorMessage = nil
        scanning = true
        status = "Scanning for court and rim\(rimCount == 2 ? "s" : "")… hold the phone steady"
        scanTask = Task {
            var quadHistory: [[CGPoint]] = []
            var attempts = 0
            var quadsEverSeen = false
            var quadsEverScored = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let pixelBuffer = flow.camera.latestPixelBuffer else { continue }
                attempts += 1

                let (quadCandidates, foundRims) = await Task.detached(priority: .userInitiated) {
                    (CourtFinder.detectCourtQuadCandidates(in: pixelBuffer),
                     RimFinder.detectRims(in: pixelBuffer, maxCount: 4))
                }.value
                if Task.isCancelled { return }

                // Live rim feedback: many gyms hang side hoops — prefer the
                // candidate nearest the user's tap (or this end's anchor).
                rimCandidates = foundRims
                let anchor = flow.rimAnchors[flow.attackingTeam]
                let chosenRim = RimFinder.pickRim(candidates: foundRims, near: anchor)
                if let r = chosenRim {
                    rimDetector.rimRects = [r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15)]
                    rimConfirmed = true
                }

                if !quadCandidates.isEmpty { quadsEverSeen = true }
                let scoringRims = rimDetector.rimRects
                if let best = CourtFinder.bestQuad(candidates: quadCandidates,
                                                      rims: scoringRims, fullCourt: false) {
                    quadsEverScored = true
                    quadHistory.append(best.quad)
                }
                if quadHistory.count > 8 { quadHistory.removeFirst() }

                if let stable = CourtFinder.stableQuad(quadHistory),
                   !scoringRims.isEmpty,
                   let pick = CourtFinder.scoreCourtAssignments(
                       quad: stable, rims: scoringRims, fullCourt: false) {
                    corners = stable
                    courtTargets = pick.courtPoints
                    scanning = false
                    status = "Rim ✓ · court seeded (fit \(String(format: "%.0f", pick.score)) ft) — Save & Record"
                    return
                }

                // Honest per-component progress: the rim being found must
                // never be reported as missing just because the court isn't
                // locking (and vice versa).
                let rimOK = !scoringRims.isEmpty
                let courtNote = !quadsEverSeen ? "not visible"
                    : !quadsEverScored ? "outline unclear"
                    : "locking…"
                status = "Rim \(rimOK ? "✓" : "searching…") · Court \(courtNote)"

                if attempts >= 30 {
                    scanning = false
                    status = rimOK
                        ? "Rim ✓ — Save & Record now; the court is tracked live while recording"
                        : "Hoop not found — tap the rim on screen to set it"
                    return
                }
            }
        }
    }

    /// Tap = "THIS is the hoop we play at". Snaps to the nearest detected
    /// candidate (within 12% of the frame) or places a default-size box at
    /// the tap, and remembers the spot as this end's anchor.
    private func designateRim(at point: CGPoint) {
        let snapped = RimFinder.pickRim(candidates: rimCandidates, near: point)
            .flatMap { hypot($0.midX - point.x, $0.midY - point.y) < 0.12 ? $0 : nil }
        let rim = snapped.map { $0.insetBy(dx: -$0.width * 0.15, dy: -$0.height * 0.15) }
            ?? CGRect(x: point.x - 0.05, y: point.y - 0.03, width: 0.10, height: 0.06)
        rimDetector.rimRects = [rim]
        rimConfirmed = true
        flow.rimAnchors[flow.attackingTeam] = point
        status = snapped != nil ? "Rim set from tap — auto-tracking will follow it"
                                : "Rim box placed at tap — drag to fit, auto-tracking will follow"
    }

    // ------------------------------------------------------------- overlays

    /// Draggable detected corner (buffer space → view via the preview layer).
    @ViewBuilder
    private func cornerMarker(index: Int) -> some View {
        if let layer = previewHolder.layer, index < corners.count {
            ZStack {
                Circle().fill(.blue).frame(width: 26, height: 26)
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
            }
            .position(layer.layerPointConverted(fromCaptureDevicePoint: corners[index]))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let p = layer.captureDevicePointConverted(fromLayerPoint: value.location)
                        corners[index] = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
                    }
            )
        }
    }

    /// Rim rects are stored in buffer space (capture-device normalized,
    /// top-left origin); converted to view coords only for display.
    @ViewBuilder
    private func rimBox(index: Int) -> some View {
        if index < rimDetector.rimRects.count, let layer = previewHolder.layer {
            let rect = layer.layerRectConverted(fromMetadataOutputRect: rimDetector.rimRects[index])
            Rectangle()
                .stroke(.orange, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .top) {
                    Text(isGame ? "RIM · \(attackingName)" : "RIM")
                        .font(.caption2.bold()).foregroundStyle(.orange).offset(y: -16)
                }
                .position(x: rect.midX, y: rect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Recentre the on-screen box at the drag point, then
                            // rebuild the buffer-space rect from two converted
                            // corners (the view→buffer transform may rotate).
                            let centered = CGRect(x: value.location.x - rect.width / 2,
                                                  y: value.location.y - rect.height / 2,
                                                  width: rect.width,
                                                  height: rect.height)
                            let c1 = layer.captureDevicePointConverted(
                                fromLayerPoint: CGPoint(x: centered.minX, y: centered.minY))
                            let c2 = layer.captureDevicePointConverted(
                                fromLayerPoint: CGPoint(x: centered.maxX, y: centered.maxY))
                            var r = CGRect(x: min(c1.x, c2.x), y: min(c1.y, c2.y),
                                           width: abs(c2.x - c1.x), height: abs(c2.y - c1.y))
                            r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
                            r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
                            guard index < rimDetector.rimRects.count else { return }
                            rimDetector.rimRects[index] = r
                        }
                )
        }
    }

    // ------------------------------------------------------------- save

    private func save() {
        // Court fix is optional here — recording estimates it continuously.
        let calibration: Calibration
        if corners.count == 4, courtTargets.count == 4,
           let homography = Homography(from: corners, to: courtTargets) {
            calibration = Calibration(
                homography: homography.m,
                imagePoints: corners.map { [Double($0.x), Double($0.y)] },
                courtPoints: courtTargets.map { [Double($0.x), Double($0.y)] }
            )
        } else {
            calibration = Calibration(homography: [], imagePoints: [], courtPoints: [])
        }
        busy = true
        errorMessage = nil
        Task {
            do {
                if !calibration.homography.isEmpty {
                    try await SupabaseService.shared.saveCalibration(sessionId: session.id, calibration)
                }
                flow.path.append(.record(session, calibration))
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
