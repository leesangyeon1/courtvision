import SwiftUI
import UIKit

/// Portrait everywhere except the camera screens (calibration/record), which
/// lock to landscape-right so the whole court fits and the preview↔buffer
/// transform stays fixed for the duration of a session.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ newMask: UIInterfaceOrientationMask) {
        guard mask != newMask else { return }
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask))
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

@main
struct CourtVisionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Navigation routes for the auth-gated flow:
/// Login → Players → NewSession → Calibration → Record → Summary.
enum Route: Hashable {
    case newSession(Player)
    case calibration(Session)
    case record(Session, Calibration)
    case summary(Session)

    /// Camera screens are landscape; everything else is portrait.
    var wantsLandscape: Bool {
        switch self {
        case .calibration, .record: return true
        case .newSession, .summary: return false
        }
    }
}

/// Shared per-flow state: the navigation path and the single camera session
/// reused by the calibration and record screens.
@MainActor
final class FlowModel: ObservableObject {
    @Published var path: [Route] = []
    /// Game sessions: the camera films one hoop at a time and swings on
    /// possession change. This is the team attacking the hoop currently in
    /// frame ("A"/"B"); Switch End flips it and forces recalibration.
    @Published var attackingTeam = "A"
    /// User-designated rim positions per end (keyed by the attacking team at
    /// that end) — a tap that says "THIS hoop, not the side baskets".
    @Published var rimAnchors: [String: CGPoint] = [:]
    let camera = CameraService()
}

struct RootView: View {
    @ObservedObject private var supabase = SupabaseService.shared
    @StateObject private var flow = FlowModel()

    var body: some View {
        Group {
            if !Config.isConfigured {
                SetupNoticeView()
            } else if supabase.userId == nil {
                LoginView()
            } else {
                NavigationStack(path: $flow.path) {
                    PlayersView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .newSession(let player):
                                NewSessionView(player: player)
                            case .calibration(let session):
                                CalibrationView(session: session)
                            case .record(let session, let calibration):
                                RecordView(session: session, calibration: calibration)
                            case .summary(let session):
                                SessionSummaryView(session: session)
                            }
                        }
                }
                .environmentObject(flow)
                // Orientation follows the COMMITTED navigation path, not view
                // appearance: an interactive back-swipe fires the previous
                // screen's onAppear even when the swipe is cancelled, which
                // used to flip a live camera session back to portrait.
                .onChange(of: flow.path) { _, path in
                    OrientationLock.set(path.last?.wantsLandscape == true ? .landscapeRight : .portrait)
                }
            }
        }
        .task { await supabase.restoreSession() }
    }
}

/// Shown instead of the app while Config.swift still holds TODO placeholders.
/// The app never runs against fake or hardcoded data.
struct SetupNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Setup required").font(.title.bold())
                Text("CourtVision needs a Supabase project before it can run.")
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Create a project at supabase.com.")
                    Text("2. Apply supabase/migrations/0001_init.sql (SQL editor or `supabase db push`).")
                    Text("3. Copy the Project URL and anon key from Settings → API.")
                    Text("4. Paste both into ios/CourtVision/Config.swift (the TODO constants).")
                    Text("5. Rebuild and run.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
