import SwiftUI

struct NewSessionView: View {
    let player: Player
    @EnvironmentObject private var flow: FlowModel
    @State private var mode: SessionMode = .practice
    @State private var teamA = ""
    @State private var teamB = ""
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Mode", selection: $mode) {
                    ForEach(SessionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if mode == .game {
                Section("Teams") {
                    TextField("Team A (e.g. Home)", text: $teamA)
                    TextField("Team B (e.g. Away)", text: $teamB)
                }
            }
            Section {
                Button(busy ? "Starting…" : "Start Session") { start() }
                    .disabled(busy)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(player.name)
    }

    private func start() {
        busy = true
        errorMessage = nil
        Task {
            do {
                let a = teamA.trimmingCharacters(in: .whitespaces)
                let b = teamB.trimmingCharacters(in: .whitespaces)
                let session = try await SupabaseService.shared.startSession(
                    playerId: player.id, mode: mode,
                    teamA: mode == .game ? (a.isEmpty ? "Team A" : a) : nil,
                    teamB: mode == .game ? (b.isEmpty ? "Team B" : b) : nil,
                    teamId: player.teamId
                )
                flow.path.append(.calibration(session))
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
