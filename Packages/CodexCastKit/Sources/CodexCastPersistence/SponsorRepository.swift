import CodexCastCore
import Foundation
import GRDB

/// A sponsor the system has actually seen in confirmed or detected ad reads —
/// an entity, not a string (§6.2). This is what makes "the same sponsor
/// showed up on a different show" catchable, and it makes the learning
/// legible: a browsable list of who advertises where.
public struct SponsorRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var canonicalName: String
    public var aliases: [String]
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var occurrenceCount: Int

    public init(
        id: UUID = UUID(),
        canonicalName: String,
        aliases: [String] = [],
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        occurrenceCount: Int = 0
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.occurrenceCount = occurrenceCount
    }
}

public struct SponsorRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Finds the sponsor this name refers to, or creates it. Deduplicates by
    /// normalized name against canonical names AND aliases; a new surface
    /// form of a known sponsor becomes an alias, not a duplicate.
    @discardableResult
    public func findOrCreate(name: String) async throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalize(trimmed)
        guard !normalized.isEmpty else { throw DatabaseError(message: "empty sponsor name") }

        return try await database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, canonicalName, aliases FROM sponsors")
            for row in rows {
                guard let idString: String = row["id"], let id = UUID(uuidString: idString),
                      let canonical: String = row["canonicalName"] else { continue }
                var aliases: [String] = (row["aliases"] as String?)
                    .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
                let known = ([canonical] + aliases).map(Self.normalize)
                guard known.contains(normalized) else { continue }

                if !([canonical] + aliases).contains(trimmed), trimmed != canonical {
                    aliases.append(trimmed)
                }
                let aliasJSON = String(
                    data: (try? JSONEncoder().encode(aliases)) ?? Data("[]".utf8),
                    encoding: .utf8
                )
                try db.execute(
                    sql: "UPDATE sponsors SET lastSeenAt = ?, aliases = ? WHERE id = ?",
                    arguments: [Date(), aliasJSON, idString]
                )
                return id
            }

            let id = UUID()
            try db.execute(
                sql: """
                INSERT INTO sponsors
                (id, canonicalName, aliases, firstSeenAt, lastSeenAt, occurrenceCount)
                VALUES (?, ?, '[]', ?, ?, 0)
                """,
                arguments: [id.uuidString, trimmed, Date(), Date()]
            )
            return id
        }
    }

    /// A confirmed ad read for this sponsor — the count the registry surfaces.
    public func recordConfirmation(_ id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE sponsors SET occurrenceCount = occurrenceCount + 1,
                    lastSeenAt = ? WHERE id = ?
                """,
                arguments: [Date(), id.uuidString]
            )
        }
    }

    public func all() async throws -> [SponsorRecord] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM sponsors ORDER BY occurrenceCount DESC, lastSeenAt DESC"
            )
            return rows.compactMap { row in
                guard let idString: String = row["id"], let id = UUID(uuidString: idString),
                      let name: String = row["canonicalName"] else { return nil }
                return SponsorRecord(
                    id: id,
                    canonicalName: name,
                    aliases: (row["aliases"] as String?)
                        .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
                    firstSeenAt: row["firstSeenAt"] ?? Date(),
                    lastSeenAt: row["lastSeenAt"] ?? Date(),
                    occurrenceCount: row["occurrenceCount"]
                )
            }
        }
    }

    /// Which shows each sponsor has appeared on, via linked segments.
    public func showTitles() async throws -> [UUID: Set<String>] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT detected_segments.sponsorId, podcasts.title
                FROM detected_segments
                JOIN episodes ON episodes.id = detected_segments.episodeId
                JOIN podcasts ON podcasts.id = episodes.podcastId
                WHERE detected_segments.sponsorId IS NOT NULL
                """
            )
            var result: [UUID: Set<String>] = [:]
            for row in rows {
                guard let idString: String = row["sponsorId"],
                      let id = UUID(uuidString: idString),
                      let title: String = row["title"] else { continue }
                result[id, default: []].insert(title)
            }
            return result
        }
    }
}
