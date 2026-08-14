import CodexCastCore
import Foundation
import GRDB

/// Regions the machine must leave alone (§6.4): created when the listener
/// says "this is not an ad". Episode-scoped from a rejection; podcast-scoped
/// from "never skip this show's intro". Scans consult these before storing
/// anything that overlaps.
public struct NeverSkipRule: Hashable, Sendable {
    public var podcastID: Podcast.ID?
    public var episodeID: Episode.ID?
    public var startMs: Int
    public var endMs: Int
    public var reason: String?
}

public struct NeverSkipRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func addEpisodeRule(
        episodeID: Episode.ID, startMs: Int, endMs: Int, reason: String?
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO never_skip_rules (id, episodeId, startMs, endMs, reason, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, episodeID, startMs, endMs, reason, Date()]
            )
        }
    }

    public func addShowRule(
        podcastID: Podcast.ID, startMs: Int, endMs: Int, reason: String?
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO never_skip_rules (id, podcastId, startMs, endMs, reason, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, podcastID, startMs, endMs, reason, Date()]
            )
        }
    }

    /// Every rule that applies to this episode: its own plus its show's.
    public func rules(episodeID: Episode.ID, podcastID: Podcast.ID) async throws -> [NeverSkipRule] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM never_skip_rules
                WHERE episodeId = ? OR podcastId = ?
                """,
                arguments: [episodeID, podcastID]
            )
            return rows.map { row in
                NeverSkipRule(
                    podcastID: (row["podcastId"] as String?)
                        .flatMap(UUID.init(uuidString:)).map(Podcast.ID.init),
                    episodeID: (row["episodeId"] as String?)
                        .flatMap(UUID.init(uuidString:)).map(Episode.ID.init),
                    startMs: row["startMs"],
                    endMs: row["endMs"],
                    reason: row["reason"]
                )
            }
        }
    }
}
