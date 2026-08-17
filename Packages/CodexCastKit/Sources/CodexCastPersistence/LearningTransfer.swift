import CodexCastCore
import Foundation
import GRDB

/// Everything the app has learned, as one portable JSON file (§6.10, A3.3).
///
/// Two uses of the same envelope: a raw dump the author feeds to a frontier
/// model offline, and the distilled result that model sends back — patterns
/// deduplicated, sponsors named, position rules proposed — imported as
/// starting knowledge. Shows travel by feed URL, the only key that survives
/// crossing devices.
public struct LearningTransfer: Sendable {
    public static let format = "codexcast-learning-v1"

    public struct Archive: Codable, Sendable {
        public var format: String
        public var exportedAt: Date
        public var patterns: [Pattern]
        public var sponsors: [Sponsor]
        public var positionRules: [Rule]
        public var showNotes: [ShowNote]
        public var reviewedSegments: [ReviewedSegment]

        public struct Pattern: Codable, Sendable {
            public var feedURL: String?
            public var text: String
            public var confirmCount: Int
            public var falsePositiveCount: Int
            public var createdFrom: String?
        }

        public struct Sponsor: Codable, Sendable {
            public var name: String
            public var aliases: [String]
            public var occurrenceCount: Int
        }

        public struct Rule: Codable, Sendable {
            public var feedURL: String
            public var anchor: PositionRule.Anchor
            public var meanDurationMs: Double
            public var sampleCount: Int
            public var hitCount: Int
            public var missCount: Int
            public var userCreated: Bool
        }

        public struct ShowNote: Codable, Sendable {
            public var feedURL: String
            public var note: String

            public init(feedURL: String, note: String) {
                self.feedURL = feedURL
                self.note = note
            }
        }

        /// User-reviewed spans with their words — the raw material a frontier
        /// model distills patterns and sponsors from.
        public struct ReviewedSegment: Codable, Sendable {
            public var feedURL: String?
            public var episodeTitle: String?
            public var startMs: Int
            public var endMs: Int
            public var kind: String
            public var verdict: String
            public var stage: String
            public var text: String?
        }
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Export

    /// `showNotes` come from the caller — they live in the app-side prefs
    /// envelope, not in a dedicated table.
    public func export(showNotes: [Archive.ShowNote]) async throws -> Archive {
        try await database.read { db in
            let feedURLByPodcast: [String: String] = try Row
                .fetchAll(db, sql: "SELECT id, feedURL FROM podcasts")
                .reduce(into: [:]) { result, row in
                    if let id: String = row["id"], let url: String = row["feedURL"] {
                        result[id] = url
                    }
                }

            let patterns = try Row.fetchAll(db, sql: "SELECT * FROM ad_patterns").map { row in
                Archive.Pattern(
                    feedURL: (row["podcastId"] as String?).flatMap { feedURLByPodcast[$0] },
                    text: row["text"],
                    confirmCount: row["confirmCount"],
                    falsePositiveCount: row["falsePositiveCount"],
                    createdFrom: row["createdFrom"]
                )
            }

            let sponsors = try Row.fetchAll(db, sql: "SELECT * FROM sponsors").map { row in
                Archive.Sponsor(
                    name: row["canonicalName"],
                    aliases: (row["aliases"] as String?)
                        .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
                    occurrenceCount: row["occurrenceCount"]
                )
            }

            let rules = try Row.fetchAll(db, sql: "SELECT * FROM position_rules").compactMap { row -> Archive.Rule? in
                guard let podcastId: String = row["podcastId"],
                      let feedURL = feedURLByPodcast[podcastId],
                      let anchorJSON: String = row["anchor"],
                      let anchor = try? JSONDecoder().decode(PositionRule.Anchor.self, from: Data(anchorJSON.utf8))
                else { return nil }
                return Archive.Rule(
                    feedURL: feedURL,
                    anchor: anchor,
                    meanDurationMs: row["meanDurationMs"],
                    sampleCount: row["sampleCount"],
                    hitCount: row["hitCount"],
                    missCount: row["missCount"],
                    userCreated: row["userCreated"]
                )
            }

            // Reviewed segments with their transcript words, joined in SQL so
            // a big library exports without loading whole transcripts.
            let segments = try Row.fetchAll(
                db,
                sql: """
                SELECT detected_segments.startMs, detected_segments.endMs,
                       detected_segments.kind, detected_segments.userState,
                       detected_segments.provenance,
                       episodes.title AS episodeTitle, episodes.podcastId,
                       (SELECT group_concat(transcript_segments.text, ' ')
                        FROM transcript_segments
                        WHERE transcript_segments.episodeId = detected_segments.episodeId
                          AND transcript_segments.endMs > detected_segments.startMs
                          AND transcript_segments.startMs < detected_segments.endMs
                       ) AS spanText
                FROM detected_segments
                JOIN episodes ON episodes.id = detected_segments.episodeId
                WHERE detected_segments.userState != 'unreviewed'
                """
            ).map { row -> Archive.ReviewedSegment in
                let provenance: String = row["provenance"] ?? ""
                let stage = ["positionPrior", "patternMatch", "onDeviceModel", "acoustic", "externalModel", "manual"]
                    .first { provenance.contains($0) } ?? "manual"
                return Archive.ReviewedSegment(
                    feedURL: (row["podcastId"] as String?).flatMap { feedURLByPodcast[$0] },
                    episodeTitle: row["episodeTitle"],
                    startMs: row["startMs"],
                    endMs: row["endMs"],
                    kind: row["kind"],
                    verdict: row["userState"],
                    stage: stage,
                    // The WORDS of the span, not just its clock times — the
                    // whole point of feeding this back to a bigger model.
                    text: (row["spanText"] as String?).map { String($0.prefix(2_000)) }
                )
            }

            return Archive(
                format: Self.format,
                exportedAt: Date(),
                patterns: patterns,
                sponsors: sponsors,
                positionRules: rules,
                showNotes: showNotes,
                reviewedSegments: segments
            )
        }
    }

    // MARK: - Import (distilled or raw)

    public struct ImportSummary: Sendable {
        public var patternsAdded = 0
        public var sponsorsAdded = 0
        public var rulesAdded = 0
    }

    /// Merges an archive into the local learning store. Additive only —
    /// nothing local is deleted or downgraded by an import.
    public func importArchive(_ archive: Archive) async throws -> ImportSummary {
        guard archive.format == Self.format else {
            throw DatabaseError(message: "Unrecognized learning file format: \(archive.format)")
        }
        return try await database.write { db in
            var summary = ImportSummary()
            let podcastByFeedURL: [String: String] = try Row
                .fetchAll(db, sql: "SELECT id, feedURL FROM podcasts")
                .reduce(into: [:]) { result, row in
                    if let id: String = row["id"], let url: String = row["feedURL"] {
                        result[url] = id
                    }
                }

            let existingPatterns = Set(
                try String.fetchAll(db, sql: "SELECT normalizedText FROM ad_patterns")
            )
            for pattern in archive.patterns {
                let normalized = pattern.text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                guard !normalized.isEmpty, !existingPatterns.contains(normalized) else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO ad_patterns
                    (id, podcastId, text, normalizedText, confirmCount,
                     falsePositiveCount, createdFrom, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        pattern.feedURL.flatMap { podcastByFeedURL[$0] },
                        pattern.text, normalized,
                        pattern.confirmCount, pattern.falsePositiveCount,
                        pattern.createdFrom ?? "import", Date(),
                    ]
                )
                summary.patternsAdded += 1
            }

            let existingSponsors = Set(
                try String.fetchAll(db, sql: "SELECT canonicalName FROM sponsors")
                    .map(SponsorRepository.normalize)
            )
            for sponsor in archive.sponsors {
                guard !existingSponsors.contains(SponsorRepository.normalize(sponsor.name)) else { continue }
                let aliases = String(
                    data: (try? JSONEncoder().encode(sponsor.aliases)) ?? Data("[]".utf8),
                    encoding: .utf8
                )
                try db.execute(
                    sql: """
                    INSERT INTO sponsors
                    (id, canonicalName, aliases, firstSeenAt, lastSeenAt, occurrenceCount)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, sponsor.name, aliases,
                        Date(), Date(), sponsor.occurrenceCount,
                    ]
                )
                summary.sponsorsAdded += 1
            }

            for rule in archive.positionRules {
                guard let podcastId = podcastByFeedURL[rule.feedURL] else { continue }
                let anchorJSON = String(
                    data: (try? JSONEncoder().encode(rule.anchor)) ?? Data("{}".utf8),
                    encoding: .utf8
                )
                let exists = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM position_rules WHERE podcastId = ? AND anchor = ?",
                    arguments: [podcastId, anchorJSON]
                ) ?? 0
                guard exists == 0 else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO position_rules
                    (id, podcastId, anchor, meanDurationMs, m2, sampleCount,
                     hitCount, missCount, enabled, userCreated, createdAt)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, 1, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, podcastId, anchorJSON,
                        rule.meanDurationMs, rule.sampleCount,
                        rule.hitCount, rule.missCount, rule.userCreated, Date(),
                    ]
                )
                summary.rulesAdded += 1
            }
            return summary
        }
    }
}
