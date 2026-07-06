import Foundation
import Network
import SwiftData

/// Persist-first outbox row: the raw JSON payload of one EventRow.
@Model
final class PendingEvent {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var createdAt: Date

    init(id: UUID, payload: Data, createdAt: Date = Date()) {
        self.id = id
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// Offline queue: every detected shot is written to SwiftData BEFORE any
/// network attempt and deleted only on server ack, so killing wifi mid-session
/// loses nothing. Replays are idempotent because the event id is the primary
/// key (upsert with ignore-duplicates). NWPathMonitor triggers an ordered
/// flush whenever connectivity returns.
@MainActor
final class OfflineQueue {
    static let shared = OfflineQueue()

    private let container: ModelContainer?
    private let monitor = NWPathMonitor()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var flushing = false

    private init() {
        container = try? ModelContainer(for: PendingEvent.self)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "courtvision.netpath"))
    }

    /// Persist first, then try to send.
    func enqueue(_ event: EventRow) {
        if let context = container?.mainContext,
           let payload = try? encoder.encode(event) {
            context.insert(PendingEvent(id: event.id, payload: payload))
            try? context.save()
        }
        Task { await flush() }
    }

    /// Sends pending events oldest-first; stops at the first failure so order
    /// is preserved and the remainder is retried on the next connectivity
    /// change (or the next enqueue).
    func flush() async {
        guard !flushing, let context = container?.mainContext else { return }
        flushing = true
        defer { flushing = false }

        let descriptor = FetchDescriptor<PendingEvent>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let pending = try? context.fetch(descriptor) else { return }

        for row in pending {
            guard let event = try? decoder.decode(EventRow.self, from: row.payload) else {
                context.delete(row)   // unreadable payload can never send
                try? context.save()
                continue
            }
            do {
                try await SupabaseService.shared.insertEvent(event)
                context.delete(row)
                try? context.save()
            } catch {
                break   // offline or server error — keep the row, retry later
            }
        }
    }
}
