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
/// flush whenever connectivity returns; a failed flush also schedules one
/// ~10 s retry (the path monitor only fires on changes, not on failures).
@MainActor
final class OfflineQueue {
    static let shared = OfflineQueue()

    private let container: ModelContainer?
    private let monitor = NWPathMonitor()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var flushing = false
    private var flushRequested = false
    private var retryScheduled = false
    /// Fallback when the SwiftData store is unavailable: events held in memory
    /// (lost on app kill, but never silently dropped while running).
    private var memoryPending: [EventRow] = []

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

    /// Persist first, then try to send. If the SwiftData store is unavailable
    /// (container init failed) the event is kept in memory instead of being
    /// dropped, and the flush below sends it directly via SupabaseService.
    func enqueue(_ event: EventRow) {
        if let context = container?.mainContext,
           let payload = try? encoder.encode(event) {
            context.insert(PendingEvent(id: event.id, payload: payload))
            try? context.save()
        } else {
            memoryPending.append(event)
        }
        Task { await flush() }
    }

    /// Sends pending events oldest-first; stops at the first failure so order
    /// is preserved. Loops until nothing is pending, so events enqueued while
    /// a flush is in flight are not stranded; a failed pass schedules a single
    /// ~10 s retry (on top of the connectivity-change / enqueue triggers).
    func flush() async {
        if flushing {
            flushRequested = true
            return
        }
        flushing = true
        defer { flushing = false }

        repeat {
            flushRequested = false
            if !(await flushOnce()) {
                scheduleRetry()
                return
            }
        } while flushRequested
    }

    /// One pass over the in-memory fallback + the SwiftData outbox.
    /// Returns false when a send failed and something is still pending.
    private func flushOnce() async -> Bool {
        while let event = memoryPending.first {
            do {
                try await SupabaseService.shared.insertEvent(event)
                memoryPending.removeFirst()
            } catch {
                return false   // offline or server error — keep it, retry later
            }
        }

        guard let context = container?.mainContext else { return true }
        let descriptor = FetchDescriptor<PendingEvent>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        guard let pending = try? context.fetch(descriptor) else { return true }

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
                return false   // offline or server error — keep the row, retry later
            }
        }
        return true
    }

    /// At most one pending retry ~10 s out, for failures that happen while the
    /// network path stays satisfied (NWPathMonitor never refires then).
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            retryScheduled = false
            await flush()
        }
    }
}
