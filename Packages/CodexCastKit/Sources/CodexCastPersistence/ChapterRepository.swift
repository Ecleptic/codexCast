import CodexCastCore
import Foundation
import GRDB

/// Stores chapters — feed-authored now, generated later (§5.8). Both are the
/// same object in the same table; `source` tells them apart and the UI marks
/// generated ones as such.
public struct ChapterRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(_ chapters: [Chapter], episodeID: Episode.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM chapters WHERE episodeId = ?", arguments: [episodeID]
            )
            for chapter in chapters {
                try db.execute(
                    sql: """
                    INSERT INTO chapters (id, episodeId, startMs, title, source, imageURL, url)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chapter.id, episodeID, chapter.startMs, chapter.title,
                        chapter.source.rawValue,
                        chapter.imageURL?.absoluteString, chapter.url?.absoluteString,
                    ]
                )
            }
        }
    }

    public func chapters(episodeID: Episode.ID) async throws -> [Chapter] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM chapters WHERE episodeId = ? ORDER BY startMs",
                arguments: [episodeID]
            )
            return rows.compactMap { row in
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let source = (row["source"] as String?).flatMap(Chapter.Source.init(rawValue:))
                else { return nil }
                return Chapter(
                    id: Chapter.ID(id),
                    startMs: row["startMs"],
                    title: row["title"],
                    source: source,
                    imageURL: (row["imageURL"] as String?).flatMap(URL.init(string:)),
                    url: (row["url"] as String?).flatMap(URL.init(string:))
                )
            }
        }
    }
}
