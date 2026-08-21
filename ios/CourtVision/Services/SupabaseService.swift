import Foundation
import Supabase

/// Thin wrapper over supabase-swift: silent auth, players/sessions CRUD,
/// idempotent event upsert, and the server-derived aggregate views. Supabase
/// IS the backend — there is no app server.
@MainActor
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    let client: SupabaseClient?
    @Published private(set) var userId: UUID?

    private init() {
        if Config.isConfigured, let url = URL(string: Config.SUPABASE_URL) {
            client = SupabaseClient(supabaseURL: url, supabaseKey: Config.SUPABASE_ANON_KEY)
        } else {
            client = nil
        }
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case emailConfirmationRequired

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Supabase is not configured — fill in Config.swift."
            case .emailConfirmationRequired:
                return "Device account created but the project requires email confirmation — confirm it once (or disable Confirm email in Supabase Auth)."
            }
        }
    }

    private var db: SupabaseClient {
        get throws {
            guard let client else { throw ServiceError.notConfigured }
            return client
        }
    }

    // MARK: - Auth (silent — no login screen)

    @Published private(set) var authError: String?

    /// Signs in without any UI: restores a persisted session, else the
    /// configured device account (created on first use), else an anonymous
    /// user. Sets `authError` when none of that works (e.g. anonymous
    /// sign-ins disabled in the project) — the app then shows a notice, never
    /// fake data.
    func restoreSession() async {
        guard let client else { return }
        if let id = try? await client.auth.session.user.id { userId = id; return }
        do {
            if !Config.SUPABASE_EMAIL.isEmpty, !Config.SUPABASE_PASSWORD.isEmpty {
                do {
                    let session = try await client.auth.signIn(email: Config.SUPABASE_EMAIL,
                                                               password: Config.SUPABASE_PASSWORD)
                    userId = session.user.id
                } catch {
                    // First run of a new device account: create it, then sign in.
                    let response = try await client.auth.signUp(email: Config.SUPABASE_EMAIL,
                                                                password: Config.SUPABASE_PASSWORD)
                    guard let session = response.session else {
                        throw ServiceError.emailConfirmationRequired
                    }
                    userId = session.user.id
                }
            } else {
                let session = try await client.auth.signInAnonymously()
                userId = session.user.id
            }
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Players

    func players() async throws -> [Player] {
        try await db.from("players").select().order("created_at").execute().value
    }

    private struct NewPlayer: Encodable {
        let name: String
        let jerseyNumber: Int?
        let position: String?
        enum CodingKeys: String, CodingKey {
            case name
            case jerseyNumber = "jersey_number"
            case position
        }
    }

    func createPlayer(name: String, jerseyNumber: Int?, position: String?) async throws -> Player {
        try await db.from("players")
            .insert(NewPlayer(name: name, jerseyNumber: jerseyNumber, position: position))
            .select()
            .single()
            .execute()
            .value
    }

    // MARK: - Sessions

    private struct NewSession: Encodable {
        let playerId: UUID
        let mode: SessionMode
        let teamA: String?
        let teamB: String?
        let teamId: UUID?
        enum CodingKeys: String, CodingKey {
            case playerId = "player_id"
            case mode
            case teamA = "team_a"
            case teamB = "team_b"
            case teamId = "team_id"
        }
    }

    func startSession(playerId: UUID, mode: SessionMode,
                      teamA: String? = nil, teamB: String? = nil,
                      teamId: UUID? = nil) async throws -> Session {
        try await db.from("sessions")
            .insert(NewSession(playerId: playerId, mode: mode, teamA: teamA, teamB: teamB,
                               teamId: teamId))
            .select()
            .single()
            .execute()
            .value
    }

    private struct EndSessionPatch: Encodable {
        let status = SessionStatus.ended
        let endedAt = Date()
        enum CodingKeys: String, CodingKey {
            case status
            case endedAt = "ended_at"
        }
    }

    func endSession(id: UUID) async throws {
        try await db.from("sessions")
            .update(EndSessionPatch())
            .eq("id", value: id.uuidString)
            .execute()
    }

    private struct CalibrationPatch: Encodable {
        let calibration: Calibration
    }

    /// Persists the homography + landmark points as jsonb on the session row.
    func saveCalibration(sessionId: UUID, _ calibration: Calibration) async throws {
        try await db.from("sessions")
            .update(CalibrationPatch(calibration: calibration))
            .eq("id", value: sessionId.uuidString)
            .execute()
    }

    // MARK: - Events

    /// Idempotent insert: the id is client-generated, so offline-queue replays
    /// are no-ops (upsert on id, ignore duplicates).
    func insertEvent(_ event: EventRow) async throws {
        try await db.from("events")
            .upsert(event, onConflict: "id", ignoreDuplicates: true)
            .execute()
    }

    // MARK: - Server-derived aggregates (the dashboard math lives in SQL)

    func boxScore(sessionId: UUID) async throws -> BoxScoreRow? {
        let rows: [BoxScoreRow] = try await db.from("session_box_scores")
            .select()
            .eq("session_id", value: sessionId.uuidString)
            .execute()
            .value
        return rows.first
    }

    func zoneSplits(sessionId: UUID) async throws -> [ZoneSplitRow] {
        try await db.from("session_zone_splits")
            .select()
            .eq("session_id", value: sessionId.uuidString)
            .order("zone")
            .execute()
            .value
    }
}
