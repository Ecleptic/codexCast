import CodexCastCore
import Foundation
import GRDB

/// Stored audio fingerprints of confirmed ads (schema v7).
public struct FingerprintRepository: Sendable {
    public struct Record: Sendable, Identifiable {
        public var id: String
        public var podcastID: Podcast.ID?
        public var sponsorID: UUID?
        public var label: String?
        public var signature: Data
        public var durationMs: Int
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(
        signature: Data,
        durationMs: Int,
        podcastID: Podcast.ID?,
        sponsorID: UUID?,
        label: String?
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO ad_fingerprints
                (id, podcastId, sponsorId, label, signature, durationMs, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString, podcastID, sponsorID?.uuidString,
                    label, signature, durationMs, Date(),
                ]
            )
        }
    }

    /// Every stored fingerprint — ads repeat ACROSS shows, so matching is
    /// never scoped to one podcast.
    public func all() async throws -> [Record] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM ad_fingerprints")
            return rows.compactMap { row in
                guard let id: String = row["id"],
                      let signature: Data = row["signature"] else { return nil }
                return Record(
                    id: id,
                    podcastID: (row["podcastId"] as String?)
                        .flatMap(UUID.init(uuidString:)).map(Podcast.ID.init),
                    sponsorID: (row["sponsorId"] as String?).flatMap(UUID.init(uuidString:)),
                    label: row["label"],
                    signature: signature,
                    durationMs: row["durationMs"]
                )
            }
        }
    }

    public func count() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ad_fingerprints") ?? 0
        }
    }
}
