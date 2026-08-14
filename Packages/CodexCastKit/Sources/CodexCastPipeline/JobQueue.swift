import CodexCastCore
import CodexCastPersistence
import Foundation
import GRDB

/// A unit of pipeline work (§9.7).
public struct Job: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "jobs"

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case download
        case transcribe
        case chapters
        case scan
        case sweep
    }

    public enum State: String, Codable, Sendable {
        case pending
        case running
        case completed
        case failed
    }

    public var id: String
    public var kind: Kind
    public var episodeId: String?
    public var podcastId: String?
    public var state: State
    public var priority: Int
    public var attemptCount: Int
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        episodeId: String? = nil,
        podcastId: String? = nil,
        state: State = .pending,
        priority: Int = 0,
        attemptCount: Int = 0,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.episodeId = episodeId
        self.podcastId = podcastId
        self.state = state
        self.priority = priority
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Durable, SQLite-backed job queue (§9.7).
///
/// Survives termination: jobs found `running` at launch were orphaned by a
/// kill mid-work and reset to `pending`. Exactly one transcription and one
/// classification run at a time — SpeechAnalyzer is memory-hungry enough that
/// two concurrent long episodes get the app jetsammed, and §5.3.6 forbids
/// parallel model inference outright.
public struct JobQueue: Sendable {
    /// Kinds that must never run concurrently with themselves.
    static let exclusiveKinds: Set<Job.Kind> = [.transcribe, .scan]
    /// Attempts after which a job stops retrying (§9.8's "two failures" rule
    /// applies to transcription; other kinds get one more).
    static let maxAttempts = 3

    private let database: AppDatabase

    public init(database: AppDatabase) throws {
        self.database = database
        try Self.createTableIfNeeded(database)
    }

    static func createTableIfNeeded(_ database: AppDatabase) throws {
        try database.writer.write { db in
            try db.create(table: "jobs", options: .ifNotExists) { table in
                table.primaryKey("id", .text)
                table.column("kind", .text).notNull()
                table.column("episodeId", .text)
                table.column("podcastId", .text)
                table.column("state", .text).notNull()
                table.column("priority", .integer).notNull().defaults(to: 0)
                table.column("attemptCount", .integer).notNull().defaults(to: 0)
                table.column("lastError", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                indexOn: "jobs", columns: ["state", "priority"], options: .ifNotExists
            )
        }
    }

    // MARK: - Lifecycle

    /// Call once at launch: jobs stuck `running` mean the app was killed
    /// mid-job; they go back to `pending` and will be picked up again.
    public func recoverOrphans() async throws -> Int {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE jobs SET state = 'pending', updatedAt = ?
                WHERE state = 'running'
                """,
                arguments: [Date()]
            )
            return db.changesCount
        }
    }

    /// Enqueues a job unless an identical pending/running one already exists —
    /// refreshing a feed twice must not download an episode twice.
    @discardableResult
    public func enqueue(
        kind: Job.Kind,
        episodeId: String? = nil,
        podcastId: String? = nil,
        priority: Int = 0
    ) async throws -> Job? {
        try await database.write { db in
            let duplicate = try Job
                .filter(Column("kind") == kind.rawValue)
                .filter(Column("episodeId") == episodeId)
                .filter(["pending", "running"].contains(Column("state")))
                .fetchOne(db)
            guard duplicate == nil else { return nil }

            var job = Job(kind: kind, episodeId: episodeId, podcastId: podcastId, priority: priority)
            try job.insert(db)
            return job
        }
    }

    /// Claims the next runnable job, atomically marking it running.
    ///
    /// Exclusive kinds are skipped while another job of the same kind runs.
    /// Priority first, then age — with the just-in-time path (§9.3) enqueueing
    /// at high priority so a play-now episode jumps the overnight backlog.
    public func claimNext() async throws -> Job? {
        try await database.write { db in
            let runningExclusive = try Job
                .filter(Column("state") == "running")
                .fetchAll(db)
                .filter { Self.exclusiveKinds.contains($0.kind) }
                .map(\.kind)

            let candidates = try Job
                .filter(Column("state") == "pending")
                .order(Column("priority").desc, Column("createdAt"))
                .fetchAll(db)

            guard var job = candidates.first(where: { candidate in
                !(Self.exclusiveKinds.contains(candidate.kind)
                    && runningExclusive.contains(candidate.kind))
            }) else { return nil }

            job.state = .running
            job.attemptCount += 1
            job.updatedAt = Date()
            try job.update(db)
            return job
        }
    }

    public func complete(_ job: Job) async throws {
        try await setState(job.id, state: .completed, error: nil)
    }

    /// Records a failure. Under the attempt limit the job returns to pending
    /// for a later retry; at the limit it fails permanently with the error
    /// preserved for the diagnostics screen.
    public func fail(_ job: Job, error: String) async throws {
        let terminal = job.attemptCount >= Self.maxAttempts
        try await setState(job.id, state: terminal ? .failed : .pending, error: error)
    }

    /// Requeue without consuming an attempt — thermal pressure and Low Power
    /// Mode pauses are not failures (§5.3.7).
    public func requeue(_ job: Job) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE jobs SET state = 'pending', attemptCount = attemptCount - 1, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [Date(), job.id]
            )
        }
    }

    private func setState(_ id: String, state: Job.State, error: String?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE jobs SET state = ?, lastError = ?, updatedAt = ? WHERE id = ?",
                arguments: [state.rawValue, error, Date(), id]
            )
        }
    }

    // MARK: - Introspection

    public func jobs(inState state: Job.State) async throws -> [Job] {
        try await database.read { db in
            try Job.filter(Column("state") == state.rawValue)
                .order(Column("priority").desc, Column("createdAt"))
                .fetchAll(db)
        }
    }
}
