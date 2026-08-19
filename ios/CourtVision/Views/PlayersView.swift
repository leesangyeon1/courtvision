import SwiftUI

struct PlayersView: View {
    @EnvironmentObject private var flow: FlowModel
    @State private var players: [Player] = []
    @State private var errorMessage: String?
    @State private var showCreate = false
    @State private var loading = true

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(players) { player in
                NavigationLink(value: Route.newSession(player)) {
                    HStack {
                        Text(player.name)
                        Spacer()
                        if let n = player.jerseyNumber {
                            Text("#\(n)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !loading && players.isEmpty && errorMessage == nil {
                Text("No players yet — add one to start a session.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Players")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Debug / verification: the engine over an imported clip.
                Button { flow.path.append(.replay) } label: { Image(systemName: "film") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Sign Out") {
                    Task { await SupabaseService.shared.signOut() }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreatePlayerView { players.append($0) }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            players = try await SupabaseService.shared.players()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

struct CreatePlayerView: View {
    let onCreate: (Player) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var jersey = ""
    @State private var position = ""
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Jersey number (optional)", text: $jersey)
                    .keyboardType(.numberPad)
                TextField("Position (optional)", text: $position)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Player")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        busy = true
        errorMessage = nil
        Task {
            do {
                let player = try await SupabaseService.shared.createPlayer(
                    name: name.trimmingCharacters(in: .whitespaces),
                    jerseyNumber: Int(jersey),
                    position: position.isEmpty ? nil : position
                )
                onCreate(player)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
