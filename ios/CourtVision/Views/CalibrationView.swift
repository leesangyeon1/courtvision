import SwiftUI

/// One-time per-setup calibration (tripod assumed stationary):
/// 1. Tap the 4 numbered landmarks in order — left/right baseline corners,
///    then left/right free-throw-line corners of the key (16 ft lane).
/// 2. Drag the orange box onto the rim.
/// 3. Save → DLT homography (view coords → court feet) stored as jsonb on the
///    session; the rim box persists on-device.
struct CalibrationView: View {
    let session: Session
    @EnvironmentObject private var flow: FlowModel
    @ObservedObject private var rimDetector = ManualRimDetector.shared

    @State private var points: [CGPoint] = []   // normalized view coords, top-left origin
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var cameraReady = false

    private static let landmarkLabels = [
        "1 · Left baseline corner",
        "2 · Right baseline corner",
        "3 · Left FT-line corner (key)",
        "4 · Right FT-line corner (key)",
    ]

    /// Court-space targets in feet: baseline corners + the free-throw-line
    /// corners of the 16 ft key (x = 17 / 33, y = 19).
    private static let courtPoints: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 50, y: 0),
        CGPoint(x: 17, y: 19),
        CGPoint(x: 33, y: 19),
    ]

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    if cameraReady {
                        CameraPreviewView(camera: flow.camera)
                    } else {
                        Rectangle().fill(.black)
                        Text(errorMessage ?? "Starting camera…")
                            .foregroundStyle(.white)
                            .padding()
                    }

                    ForEach(points.indices, id: \.self) { i in
                        marker(index: i)
                            .position(x: points[i].x * geo.size.width,
                                      y: points[i].y * geo.size.height)
                    }

                    rimBox(in: geo.size)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard points.count < 4, geo.size.width > 0, geo.size.height > 0 else { return }
                    points.append(CGPoint(x: location.x / geo.size.width,
                                          y: location.y / geo.size.height))
                }
            }

            VStack(spacing: 8) {
                Text(points.count < 4
                     ? "Tap: \(Self.landmarkLabels[points.count])"
                     : "Drag the orange box onto the rim, then save.")
                    .font(.callout)
                if let errorMessage, cameraReady {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                HStack {
                    Button("Reset Points") { points.removeAll() }
                        .disabled(points.isEmpty)
                    Spacer()
                    Button(busy ? "Saving…" : "Save & Record") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || points.count < 4 || rimDetector.rimRect == nil)
                }
            }
            .padding()
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                try await flow.camera.configureIfNeeded()
                flow.camera.start()
                cameraReady = true
            } catch {
                errorMessage = error.localizedDescription
            }
            if rimDetector.rimRect == nil {
                rimDetector.rimRect = CGRect(x: 0.45, y: 0.2, width: 0.12, height: 0.07)
            }
        }
    }

    private func marker(index: Int) -> some View {
        ZStack {
            Circle().fill(.blue).frame(width: 24, height: 24)
            Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func rimBox(in size: CGSize) -> some View {
        if let rim = rimDetector.rimRect {
            Rectangle()
                .stroke(.orange, lineWidth: 3)
                .frame(width: rim.width * size.width, height: rim.height * size.height)
                .overlay(alignment: .top) {
                    Text("RIM").font(.caption2.bold()).foregroundStyle(.orange).offset(y: -16)
                }
                .position(x: rim.midX * size.width, y: rim.midY * size.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard size.width > 0, size.height > 0 else { return }
                            var r = rim
                            r.origin.x = min(max(value.location.x / size.width - r.width / 2, 0), 1 - r.width)
                            r.origin.y = min(max(value.location.y / size.height - r.height / 2, 0), 1 - r.height)
                            rimDetector.rimRect = r
                        }
                )
        }
    }

    private func save() {
        guard let homography = Homography(from: points, to: Self.courtPoints) else {
            errorMessage = "Those points are degenerate (collinear). Reset and tap the 4 corners again."
            return
        }
        let calibration = Calibration(
            homography: homography.m,
            imagePoints: points.map { [Double($0.x), Double($0.y)] },
            courtPoints: Self.courtPoints.map { [Double($0.x), Double($0.y)] }
        )
        busy = true
        errorMessage = nil
        Task {
            do {
                try await SupabaseService.shared.saveCalibration(sessionId: session.id, calibration)
                flow.path.append(.record(session, calibration))
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
