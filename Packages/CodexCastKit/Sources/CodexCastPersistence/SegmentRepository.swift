import CodexCastCore
import Foundation
import GRDB

/// Stores and loads detected segments (§5.0), preserving provenance —
/// the invariant the correction system depends on: every segment knows which
/// stage produced it and on what evidence.
public struct SegmentRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Replaces an episode's machine-produced segments with a fresh detection
    /// pass, leaving user-touched rows (confirmed/rejected/adjusted/manual)
    /// untouched — a re-scan must never erase a correction.
    public func replaceMachineSegments(
        _ segments: [DetectedSegment],
        episodeID: Episode.ID
    ) async throws {
        let encoder = JSONEncoder()
        try await database.write { db in
            try db.execute(
                sql: """
                DELETE FROM detected_segments
                WHERE episodeId = ? AND userState = 'unreviewed'
                """,
                arguments: [episodeID]
            )
            for segment in segments {
                let provenance = String(
                    data: (try? encoder.encode(segment.provenance)) ?? Data("{}".utf8),
                    encoding: .utf8
                )
                try db.execute(
                    sql: """
                    INSERT INTO detected_segments
                    (id, episodeId, startMs, endMs, kind, confidence, provenance,
                     rationale, userState, chunkId, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segment.id, segment.episodeID,
                        segment.startMs, segment.endMs,
                        segment.kind.rawValue, segment.confidence,
                        provenance, segment.rationale,
                        segment.userState.rawValue,
                        segment.chunkID?.uuidString, segment.createdAt,
                    ]
                )
            }
        }
    }

    /// Inserts one segment — the user-marked path (§6.4 "Mark missed ad",
    /// the highest-value correction in the system).
    public func insert(_ segment: DetectedSegment) async throws {
        let provenance = String(
            data: (try? JSONEncoder().encode(segment.provenance)) ?? Data("{}".utf8),
            encoding: .utf8
        )
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO detected_segments
                (id, episodeId, startMs, endMs, kind, confidence, provenance,
                 rationale, userState, chunkId, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    segment.id, segment.episodeID,
                    segment.startMs, segment.endMs,
                    segment.kind.rawValue, segment.confidence,
                    provenance, segment.rationale,
                    segment.userState.rawValue,
                    segment.chunkID?.uuidString, segment.createdAt,
                ]
            )
        }
    }

    public func segments(episodeID: Episode.ID) async throws -> [DetectedSegment] {
        let decoder = JSONDecoder()
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM detected_segments
                WHERE episodeId = ? ORDER BY startMs
                """,
                arguments: [episodeID]
            )
            return rows.compactMap { row in
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let kind = (row["kind"] as String?).flatMap(SegmentKind.init(rawValue:)),
                      let state = (row["userState"] as String?).flatMap(UserState.init(rawValue:))
                else { return nil }

                let provenance = (row["provenance"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? decoder.decode(Provenance.self, from: $0) }

                return DetectedSegment(
                    id: DetectedSegment.ID(id),
                    episodeID: episodeID,
                    startMs: row["startMs"],
                    endMs: row["endMs"],
                    kind: kind,
                    confidence: row["confidence"],
                    provenance: provenance ?? .manual,
                    rationale: row["rationale"],
                    userState: state,
                    chunkID: (row["chunkId"] as String?).flatMap(UUID.init(uuidString:)),
                    createdAt: row["createdAt"] ?? Date()
                )
            }
        }
    }
}
