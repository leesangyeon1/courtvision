import SwiftUI
import UniformTypeIdentifiers

/// Debug / verification screen (iPhone, iPad, Mac): import a clip, watch the
/// engine's view frame by frame, tap to lock rims, export what it saw.
/// Same engine, same overlay as the live Record screen — nothing is mocked.
struct ReplayView: View {
    @StateObject private var model = ReplayModel()
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let image = model.image {
                        let fit = Self.fitRect(image: CGSize(width: image.width, height: image.height), in: geo.size)
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                            .position(x: fit.midX, y: fit.midY)
                        MomentOverlay(
                            players: model.moment?.players ?? [],
                            referees: model.moment?.referees ?? [],
                            rims: model.moment?.rims ?? [:],
                            ballTrail: model.ballTrail,
                            rect: { r in CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                                                width: r.width * fit.width, height: r.height * fit.height) },
                            point: { p in CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height) })
                            .frame(width: fit.width, height: fit.height)
                            .position(x: fit.midX, y: fit.midY)
                            .contentShape(Rectangle())
                    } else {
                        Text(model.status).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard let image = model.image else { return }
                    let fit = Self.fitRect(image: CGSize(width: image.width, height: image.height), in: geo.size)
                    guard fit.contains(location) else { return }
                    model.designateRim(at: CGPoint(x: (location.x - fit.minX) / fit.width,
                                                   y: (location.y - fit.minY) / fit.height))
                }
            }

            VStack(spacing: 8) {
                Text(model.status).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 12) {
                    Button("Open…") { importing = true }
                    Button(model.running ? "Pause" : "Play") { model.togglePlay() }
                        .disabled(model.url == nil)
                    Toggle("1×", isOn: $model.paced).toggleStyle(.button)
                    Button("Teams ⇄") { model.swapTeams() }.disabled(model.url == nil)
                    Spacer()
                    Button("Export JSON") { model.export() }.disabled(model.moments.isEmpty)
                }
                .font(.footnote)
                if !model.events.isEmpty {
                    ScrollView(.horizontal) {
                        HStack { ForEach(Array(model.events.enumerated()), id: \.offset) { _, e in
                            Text("\(e.kind.rawValue) \(String(format: "%.1fs", e.pts)) \(e.end ?? "")")
                                .font(.caption2).padding(4).background(.thinMaterial, in: Capsule())
                        } }
                    }
                }
            }
            .padding(10)
        }
        .navigationTitle("Replay")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { model.open(url) }
        }
        .onDisappear { model.stop() }
    }

    /// Aspect-fit rect of an image inside `size`.
    static func fitRect(image: CGSize, in size: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / image.width, size.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

@MainActor
final class ReplayModel: ObservableObject {
    @Published var url: URL?
    @Published var image: CGImage?
    @Published var moment: Moment?
    @Published var ballTrail: [BallTrack.Sample] = []
    @Published var events: [ShotEvent] = []
    @Published var moments: [Moment] = []
    @Published var status = "Open a clip (.mov / .mp4) to replay it through the engine."
    @Published var running = false
    @Published var paced = true

    private var session: ReplaySession?
    private var task: Task<Void, Never>?
    private var securityScoped = false

    func open(_ url: URL) {
        stop()
        securityScoped = url.startAccessingSecurityScopedResource()
        self.url = url
        session = ReplaySession(url: url)
        image = nil; moment = nil; events = []; moments = []; ballTrail = []
        status = "\(url.lastPathComponent) — Play to start."
        togglePlay()
    }

    func togglePlay() {
        if running { stop(keepSession: true); return }
        guard let session else { return }
        running = true
        task = Task { [weak self] in
            do {
                for try await frame in session.frames(paced: self?.paced ?? true) {
                    guard let self, !Task.isCancelled else { return }
                    self.image = frame.image
                    self.moment = frame.moment
                    self.ballTrail = session.engine.ballTrail
                    self.moments.append(frame.moment)
                    self.events.append(contentsOf: frame.events.filter { $0.kind != .attempt })
                    self.status = String(format: "%.1f s · players %d · rims %@ · shots %d",
                                         frame.pts, frame.moment.players.count,
                                         frame.moment.rims.keys.sorted().joined(separator: "+"), self.events.count)
                }
                self?.status += " · done"
            } catch {
                self?.status = "Replay failed: \(error.localizedDescription)"
            }
            self?.running = false
        }
    }

    func stop(keepSession: Bool = false) {
        task?.cancel(); task = nil
        session?.cancelled = !keepSession
        running = false
        if !keepSession {
            session = nil
            if securityScoped { url?.stopAccessingSecurityScopedResource(); securityScoped = false }
        }
    }

    func designateRim(at point: CGPoint) {
        guard let session else { return }
        session.seedRim = false
        let end = session.engine.designateRim(at: point)
        status = "Rim \(end) locked at tap."
    }

    func swapTeams() { session?.engine.teamsSwapped.toggle() }

    /// Writes <clip>.moments.json + <clip>.events.json next to the clip when
    /// writable, else into Documents.
    func export() {
        guard let url else { return }
        let enc = JSONEncoder()
        let base = url.deletingPathExtension()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for (name, data) in [("moments", try? enc.encode(moments)), ("events", try? enc.encode(events))] {
            guard let data else { continue }
            let target = base.appendingPathExtension("\(name).json")
            if (try? data.write(to: target)) == nil {
                try? data.write(to: docs.appendingPathComponent(base.lastPathComponent + ".\(name).json"))
            }
        }
        status = "Exported moments/events JSON next to the clip (or Documents)."
    }
}
