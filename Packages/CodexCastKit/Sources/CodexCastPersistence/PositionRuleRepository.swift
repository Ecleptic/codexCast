import CodexCastCore
import Foundation
import GRDB

/// Stores per-show position rules (§6.3). The anchor is JSON in one column —
/// it is an enum with parameters, and nothing queries inside it.
public struct PositionRuleRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func rules(podcastID: Podcast.ID, includeDisabled: Bool = false) async throws -> [PositionRule] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: includeDisabled
                    ? "SELECT * FROM position_rules WHERE podcastId = ? ORDER BY createdAt"
                    : "SELECT * FROM position_rules WHERE podcastId = ? AND enabled = 1 ORDER BY createdAt",
                arguments: [podcastID]
            )
            return rows.compactMap { Self.rule(from: $0, podcastID: podcastID) }
        }
    }

    public func save(_ rule: PositionRule) async throws {
        let anchor = String(
            data: (try? JSONEncoder().encode(rule.anchor)) ?? Data("{}".utf8),
            encoding: .utf8
        )
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO position_rules
                (id, podcastId, anchor, meanDurationMs, m2, sampleCount,
                 hitCount, missCount, enabled, userCreated, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    anchor = excluded.anchor,
                    meanDurationMs = excluded.meanDurationMs,
                    m2 = excluded.m2,
                    sampleCount = excluded.sampleCount,
                    hitCount = excluded.hitCount,
                    missCount = excluded.missCount,
                    enabled = excluded.enabled,
                    userCreated = excluded.userCreated
                """,
                arguments: [
                    rule.id, rule.podcastID, anchor,
                    rule.meanDurationMs, rule.m2, rule.sampleCount,
                    rule.hitCount, rule.missCount,
                    rule.enabled, rule.userCreated, rule.createdAt,
                ]
            )
        }
    }

    public func delete(_ id: PositionRule.ID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM position_rules WHERE id = ?", arguments: [id])
        }
    }

    private static func rule(from row: Row, podcastID: Podcast.ID) -> PositionRule? {
        guard let idString: String = row["id"],
              let uuid = UUID(uuidString: idString),
              let anchorJSON: String = row["anchor"],
              let anchor = try? JSONDecoder().decode(
                  PositionRule.Anchor.self, from: Data(anchorJSON.utf8)
              )
        else { return nil }
        return PositionRule(
            id: PositionRule.ID(uuid),
            podcastID: podcastID,
            anchor: anchor,
            meanDurationMs: row["meanDurationMs"],
            m2: row["m2"],
            sampleCount: row["sampleCount"],
            hitCount: row["hitCount"],
            missCount: row["missCount"],
            enabled: row["enabled"],
            userCreated: row["userCreated"],
            createdAt: row["createdAt"] ?? Date()
        )
    }
}
