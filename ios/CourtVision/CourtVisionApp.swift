import SwiftUI

@main
struct CourtVisionApp: App {
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
}

/// Shared per-flow state: the navigation path and the single camera session
/// reused by the calibration and record screens.
@MainActor
final class FlowModel: ObservableObject {
    @Published var path: [Route] = []
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
