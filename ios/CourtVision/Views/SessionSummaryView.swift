import SwiftUI

/// Post-session summary. Everything shown here is SERVER-DERIVED: it fetches
/// rows from the session_box_scores and session_zone_splits SQL views — no
/// client-side reimplementation of the metric math.
struct SessionSummaryView: View {
    let session: Session
    @EnvironmentObject private var flow: FlowModel
    @State private var box: BoxScoreRow?
    @State private var splits: [ZoneSplitRow] = []
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            }
            if let box {
                Section("Box score") {
                    row("PTS", "\(box.pts)")
                    row("FG", "\(box.fgm)-\(box.fga)")
                    row("3PT", "\(box.threePm)-\(box.threePa)")
                    row("FT", "\(box.ftm)-\(box.fta)")
                    row("FG%", pct(box.fgPct))
                    row("3P%", pct(box.threePct))
                    row("FT%", pct(box.ftPct))
                    row("eFG%", pct(box.efgPct))
                    row("TS%", pct(box.tsPct))
                }
            }
            if !splits.isEmpty {
                Section("Zone splits") {
                    ForEach(splits, id: \.zone) { split in
                        HStack {
                            Text(split.zone.rawValue)
                            Spacer()
                            Text("\(split.made)/\(split.attempted) · \(pct(split.pct))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Summary")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { flow.path = [] }
            }
        }
        .task { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func pct(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            box = try await SupabaseService.shared.boxScore(sessionId: session.id)
            splits = try await SupabaseService.shared.zoneSplits(sessionId: session.id)
            if box == nil {
                errorMessage = "No box score row yet — check your connection and retry."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
