import CodexCastCore
import Foundation
import GRDB

// MARK: - Library

public struct PodcastRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Subscribes to a feed, or returns the existing subscription. Feed URL is
    /// the identity: subscribing twice to the same URL is a no-op, not a
    /// duplicate row.
    @discardableResult
    public func subscribe(
        feedURL: URL,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        imageURL: URL? = nil,
        itunesCollectionID: Int? = nil
    ) async throws -> PodcastRecord {
        try await database.write { db in
            if var existing = try PodcastRecord
                .filter(Column("feedURL") == feedURL.absoluteString)
                .fetchOne(db)
            {
                // Re-subscribing (e.g. tapping Follow in Discover on a show
                // that arrived via OPML) backfills identity the first source
                // didn't have — notably the iTunes ID, which is how Discover
                // decides to show the checkmark instead of the button.
                var changed = false
                if existing.itunesCollectionID == nil, let itunesCollectionID {
                    existing.itunesCollectionID = itunesCollectionID
                    changed = true
                }
                if existing.imageURL == nil, let imageURL {
                    existing.imageURL = imageURL.absoluteString
                    changed = true
                }
                if changed {
                    try existing.update(db)
                }
                return existing
            }

            var record = PodcastRecord(
                feedURL: feedURL.absoluteString,
                itunesCollectionID: itunesCollectionID,
                title: title,
                author: author,
                summary: summary,
                imageURL: imageURL?.absoluteString
            )
            try record.insert(db)
            return record
        }
    }

    /// Pinned first, then alphabetical — the favorites contract.
    public func all() async throws -> [PodcastRecord] {
        try await database.read { db in
            try PodcastRecord
                .order(Column("isPinned").desc, Column("title"))
                .fetchAll(db)
        }
    }

    public func setFollowed(_ followed: Bool, podcastID: Podcast.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET isFollowed = ? WHERE id = ?",
                arguments: [followed, podcastID]
            )
        }
    }

    public func setPinned(_ pinned: Bool, podcastID: Podcast.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET isPinned = ? WHERE id = ?",
                arguments: [pinned, podcastID]
            )
        }
    }

    public func find(feedURL: URL) async throws -> PodcastRecord? {
        try await database.read { db in
            try PodcastRecord.filter(Column("feedURL") == feedURL.absoluteString).fetchOne(db)
        }
    }

    /// Stores the validators returned by the last successful fetch, so the next
    /// refresh can be conditional.
    public func updateCacheValidators(
        podcastID: Podcast.ID,
        etag: String?,
        lastModified: String?,
        refreshedAt: Date = Date()
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE podcasts
                SET etag = ?, lastModified = ?, lastRefreshedAt = ?, lastErrorDescription = NULL
                WHERE id = ?
                """,
                arguments: [etag, lastModified, refreshedAt, podcastID]
            )
        }
    }

    /// A feed that fails to parse must not take the subscription down with it.
    public func recordError(podcastID: Podcast.ID, description: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET lastErrorDescription = ? WHERE id = ?",
                arguments: [description, podcastID]
            )
        }
    }

    public func setAutoDownload(_ enabled: Bool, podcastID: Podcast.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET autoDownloadEnabled = ? WHERE id = ?",
                arguments: [enabled, podcastID]
            )
        }
    }

    public func setPlaybackSettings(_ json: String?, podcastID: Podcast.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET playbackSettings = ? WHERE id = ?",
                arguments: [json, podcastID]
            )
        }
    }

    public func unsubscribe(podcastID: Podcast.ID) async throws {
        try await database.write { db in
            _ = try PodcastRecord.deleteOne(db, key: podcastID)
        }
    }
}

public struct EpisodeRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Inserts new episodes and refreshes the mutable metadata of existing
    /// ones, matching on `(podcastId, guid)`. Returns the guids newly added —
    /// which is what "notify on new episode" needs to know (§9.5).
    @discardableResult
    public func upsert(
        _ episodes: [ParsedEpisodeInput],
        podcastID: Podcast.ID
    ) async throws -> [String] {
        try await database.write { db in
            var inserted: [String] = []

            for episode in episodes {
                let existing = try EpisodeRecord
                    .filter(Column("podcastId") == podcastID)
                    .filter(Column("guid") == episode.guid)
                    .fetchOne(db)

                if var record = existing {
                    // Only feed-derived fields are refreshed. Local state —
                    // download path, playback position, media hash — belongs to
                    // this device and a feed refresh must not clobber it.
                    record.title = episode.title
                    record.summary = episode.summary
                    record.publishedAt = episode.publishedAt
                    record.durationMs = episode.durationMs
                    record.renditions = episode.renditionsJSON
                    record.feedTranscripts = episode.feedTranscriptsJSON
                    record.feedChaptersURL = episode.feedChaptersURL
                    try record.update(db)
                } else {
                    var record = EpisodeRecord(
                        podcastId: podcastID,
                        guid: episode.guid,
                        title: episode.title,
                        summary: episode.summary,
                        publishedAt: episode.publishedAt,
                        durationMs: episode.durationMs,
                        imageURL: episode.imageURL,
                        episodeNumber: episode.episodeNumber,
                        seasonNumber: episode.seasonNumber,
                        renditions: episode.renditionsJSON,
                        feedTranscripts: episode.feedTranscriptsJSON,
                        feedChaptersURL: episode.feedChaptersURL
                    )
                    try record.insert(db)
                    inserted.append(episode.guid)
                }
            }

            return inserted
        }
    }

    public func episodes(podcastID: Podcast.ID, limit: Int = 100) async throws -> [EpisodeRecord] {
        try await database.read { db in
            try EpisodeRecord
                .filter(Column("podcastId") == podcastID)
                .order(Column("publishedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func find(id: Episode.ID) async throws -> EpisodeRecord? {
        try await database.read { db in
            try EpisodeRecord.fetchOne(db, key: id)
        }
    }

    /// Saves playback position; marks played at the tail. Called on a timer
    /// during playback, so progress survives force-quit and relaunch — the
    /// "open the app and find your place" journey every player is built on.
    public func savePosition(episodeID: Episode.ID, positionMs: Int, durationMs: Int?) async throws {
        try await database.write { db in
            // 95% through counts as played; outros vary too much to demand 100%.
            let played = durationMs.map { positionMs >= Int(Double($0) * 0.95) } ?? false
            try db.execute(
                sql: """
                    UPDATE episodes
                    SET playbackPositionMs = ?, isPlayed = isPlayed OR ?, lastPlayedAt = ?
                    WHERE id = ?
                    """,
                arguments: [positionMs, played, Date(), episodeID]
            )
        }
    }

    public func setPlayed(_ played: Bool, episodeID: Episode.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE episodes SET isPlayed = ?, playbackPositionMs = ? WHERE id = ?",
                arguments: [played, played ? 0 : 0, episodeID]
            )
        }
    }

    /// Records that ad detection has run over this episode, whatever it found.
    public func markScanned(episodeID: Episode.ID, at date: Date = Date()) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE episodes SET lastScannedAt = ? WHERE id = ?",
                arguments: [date, episodeID]
            )
        }
    }

    /// Episodes started but unfinished, most recently published first — the
    /// Continue Listening shelf.
    /// Newest publish date per show — the signal behind the dormant marker
    /// (a show that has not published in months).
    public func latestPublishDates() async throws -> [Podcast.ID: Date] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT podcastId, MAX(publishedAt) AS newest FROM episodes GROUP BY podcastId"
            )
            var result: [Podcast.ID: Date] = [:]
            for row in rows {
                guard let idString: String = row["podcastId"],
                      let uuid = UUID(uuidString: idString),
                      let newest: Date = row["newest"]
                else { continue }
                result[Podcast.ID(uuid)] = newest
            }
            return result
        }
    }

    public func inProgress(limit: Int = 20) async throws -> [EpisodeRecord] {
        try await database.read { db in
            // Every show, followed or merely added — "what was I in the
            // middle of?" has nothing to do with following. Most recently
            // listened first, so nothing falls off behind fresh publishes.
            try EpisodeRecord
                .filter(Column("playbackPositionMs") > 15_000)
                .filter(Column("isPlayed") == false)
                .order(Column("lastPlayedAt").desc, Column("publishedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Newest unplayed episodes from FOLLOWED shows only — the New Releases
    /// shelf. Added-but-unfollowed shows stay out of the listener's face.
    public func newReleases(limit: Int = 30) async throws -> [EpisodeRecord] {
        try await database.read { db in
            try EpisodeRecord.fetchAll(db, sql: """
                SELECT episodes.* FROM episodes
                JOIN podcasts ON podcasts.id = episodes.podcastId
                WHERE episodes.isPlayed = 0
                  AND episodes.playbackPositionMs = 0
                  AND podcasts.isFollowed = 1
                ORDER BY episodes.publishedAt DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// Records the downloaded file and its content hash. A changed hash means
    /// the file was re-downloaded and dynamic ad insertion may have produced
    /// different ads, so any existing segments are invalidated (§4.1).
    public func recordDownload(
        episodeID: Episode.ID,
        localPath: String,
        mediaHash: String
    ) async throws -> Bool {
        try await database.write { db in
            guard let existing = try EpisodeRecord.fetchOne(db, key: episodeID) else { return false }
            let hashChanged = existing.mediaHash != nil && existing.mediaHash != mediaHash

            if hashChanged {
                try db.execute(
                    sql: "DELETE FROM detected_segments WHERE episodeId = ?",
                    arguments: [episodeID]
                )
            }

            try db.execute(
                sql: "UPDATE episodes SET localPath = ?, mediaHash = ? WHERE id = ?",
                arguments: [localPath, mediaHash, episodeID]
            )
            return hashChanged
        }
    }
}

/// The feed-derived fields needed to create or refresh an episode row, kept
/// separate from `ParsedEpisode` so persistence does not depend on the feed
/// module.
public struct ParsedEpisodeInput: Sendable {
    public var guid: String
    public var title: String
    public var summary: String?
    public var publishedAt: Date?
    public var durationMs: Int?
    public var imageURL: String?
    public var episodeNumber: Int?
    public var seasonNumber: Int?
    public var renditionsJSON: String?
    public var feedTranscriptsJSON: String?
    public var feedChaptersURL: String?

    public init(
        guid: String,
        title: String,
        summary: String? = nil,
        publishedAt: Date? = nil,
        durationMs: Int? = nil,
        imageURL: String? = nil,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil,
        renditionsJSON: String? = nil,
        feedTranscriptsJSON: String? = nil,
        feedChaptersURL: String? = nil
    ) {
        self.guid = guid
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.durationMs = durationMs
        self.imageURL = imageURL
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.renditionsJSON = renditionsJSON
        self.feedTranscriptsJSON = feedTranscriptsJSON
        self.feedChaptersURL = feedChaptersURL
    }
}

// MARK: - Transcripts

public struct TranscriptRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// A1: the feed-transcript drift check runs once per episode; this is
    /// the once.
    public func markDriftChecked(episodeID: Episode.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE transcripts SET driftCheckedAt = ? WHERE episodeId = ?",
                arguments: [Date(), episodeID]
            )
        }
    }

    public func isDriftChecked(episodeID: Episode.ID) async throws -> Bool {
        try await database.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT driftCheckedAt FROM transcripts WHERE episodeId = ?",
                arguments: [episodeID]
            ) != nil
        }
    }

    /// Transcripts are persisted and never recomputed. Transcription is the most
    /// expensive stage in the pipeline; doing it twice for one episode is pure
    /// waste (§9.9).
    public func save(_ transcript: TimedTranscript, episodeID: Episode.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE episodeId = ?",
                arguments: [episodeID]
            )
            try db.execute(
                sql: """
                INSERT INTO transcripts (episodeId, source, createdAt) VALUES (?, ?, ?)
                ON CONFLICT(episodeId) DO UPDATE SET source = excluded.source, createdAt = excluded.createdAt
                """,
                arguments: [episodeID, transcript.source.rawValue, Date()]
            )

            for (index, segment) in transcript.segments.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (episodeId, idx, startMs, endMs, text, speaker)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        episodeID, index, segment.startMs, segment.endMs, segment.text, segment.speaker,
                    ]
                )
            }

            try db.execute(
                sql: "UPDATE episodes SET transcriptSource = ? WHERE id = ?",
                arguments: [transcript.source.rawValue, episodeID]
            )
        }
    }

    public func transcript(episodeID: Episode.ID) async throws -> TimedTranscript? {
        try await database.read { db in
            guard let sourceRaw = try String.fetchOne(
                db,
                sql: "SELECT source FROM transcripts WHERE episodeId = ?",
                arguments: [episodeID]
            ), let source = TimedTranscript.Source(rawValue: sourceRaw) else {
                return nil
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT startMs, endMs, text, speaker FROM transcript_segments
                WHERE episodeId = ? ORDER BY idx
                """,
                arguments: [episodeID]
            )

            let segments = rows.map { row in
                TimedTranscript.Segment(
                    startMs: row["startMs"],
                    endMs: row["endMs"],
                    text: row["text"],
                    speaker: row["speaker"]
                )
            }

            return segments.isEmpty ? nil : TimedTranscript(source: source, segments: segments)
        }
    }

    /// Removes a stored transcript. The episode can be re-transcribed any
    /// time; this exists for cleanup and for redoing a bad transcription.
    public func delete(episodeID: Episode.ID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM transcript_segments WHERE episodeId = ?", arguments: [episodeID])
            try db.execute(sql: "DELETE FROM transcripts WHERE episodeId = ?", arguments: [episodeID])
            try db.execute(sql: "UPDATE episodes SET transcriptSource = NULL WHERE id = ?", arguments: [episodeID])
        }
    }

    public func hasTranscript(episodeID: Episode.ID) async throws -> Bool {
        try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcripts WHERE episodeId = ?",
                arguments: [episodeID]
            ) ?? 0 > 0
        }
    }
}

// MARK: - Learned patterns

public struct AdPatternRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func insert(_ record: AdPatternRecord) async throws -> AdPatternRecord {
        try await database.write { db in
            var copy = record
            try copy.insert(db)
            return copy
        }
    }

    /// Full-text search over the normalized pattern corpus — Stage 1's cheapest
    /// tier, catching identical read scripts, which is the common case for
    /// dynamically inserted ads and scripted host reads (§5.2).
    ///
    /// Patterns are text rather than timestamps, which is exactly why dynamic ad
    /// insertion does not defeat them: the same read inserted at 4:12 today and
    /// 7:45 next week matches both times.
    public func search(
        matching text: String,
        podcastID: Podcast.ID? = nil,
        limit: Int = 20
    ) async throws -> [AdPatternRecord] {
        let normalized = PatternNormalizer.normalize(text)
        guard !normalized.isEmpty else { return [] }

        return try await database.read { db in
            // Quoting each token keeps FTS5 operators in transcript text from
            // being interpreted as query syntax.
            let pattern = normalized
                .split(separator: " ")
                .map { "\"\($0)\"" }
                .joined(separator: " OR ")
            guard !pattern.isEmpty else { return [] }

            var sql = """
            SELECT ad_patterns.* FROM ad_patterns
            JOIN ad_patterns_fts ON ad_patterns_fts.rowid = ad_patterns.rowid
            WHERE ad_patterns_fts MATCH ?
            """
            var arguments: [any DatabaseValueConvertible] = [pattern]

            // A pattern scoped to no show is global, and global patterns are how
            // a sponsor learned on one show is caught on another.
            if let podcastID {
                sql += " AND (ad_patterns.podcastId IS NULL OR ad_patterns.podcastId = ?)"
                arguments.append(podcastID)
            }

            sql += " ORDER BY bm25(ad_patterns_fts) LIMIT ?"
            arguments.append(limit)

            return try AdPatternRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    public func recordConfirmation(patternID: AdPatternRecord.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE ad_patterns
                SET confirmCount = confirmCount + 1, lastMatchedAt = ?
                WHERE id = ?
                """,
                arguments: [Date(), patternID]
            )
        }
    }

    public func recordFalsePositive(patternID: AdPatternRecord.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE ad_patterns SET falsePositiveCount = falsePositiveCount + 1 WHERE id = ?",
                arguments: [patternID]
            )
        }
    }

    public func all() async throws -> [AdPatternRecord] {
        try await database.read { db in
            try AdPatternRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }
}

// MARK: - Corrections

/// Append-only by construction: the API exposes no delete or update.
///
/// Corrections are the user's accumulated effort and the raw material the whole
/// learning layer is built from. Losing them is unrecoverable, so the type
/// simply offers no way to.
public struct CorrectionRepository: Sendable {
    public enum Source: String, Sendable {
        /// Authoritative: creates, modifies, and disables rules directly.
        case explicit
        /// Weak: adjusts confidence and accumulates toward suggestions, and may
        /// never change a rule on its own (§6.7).
        case implicit
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// §6.8 implicit signal: weak evidence from how the listener behaves —
    /// never authoritative, may never create or disable a rule on its own.
    public func recordSignal(
        episodeID: Episode.ID,
        kind: String,
        positionMs: Int,
        weight: Double = 1.0
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO playback_signals (episodeId, kind, positionMs, weight, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [episodeID, kind, positionMs, weight, Date()]
            )
        }
    }

    /// The learned systematic bias of machine boundaries, from
    /// adjust-boundaries corrections: mean signed (corrected − proposed)
    /// per edge, per show. FINDINGS measured the model drawing boundaries
    /// consistently EARLY — a bias this size is a free correction once a
    /// few adjustments have taught it. Nil until ≥3 samples exist.
    public func meanBoundaryOffsets(
        podcastID: Podcast.ID
    ) async throws -> (startMs: Int, endMs: Int)? {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT corrections.previousValue, corrections.newValue
                FROM corrections
                JOIN episodes ON episodes.id = corrections.episodeId
                WHERE corrections.type = 'adjustBoundaries'
                  AND episodes.podcastId = ?
                ORDER BY corrections.createdAt DESC LIMIT 40
                """,
                arguments: [podcastID]
            )
            struct Span: Decodable { var startMs: Int; var endMs: Int }
            var startDeltas: [Int] = []
            var endDeltas: [Int] = []
            for row in rows {
                guard let previousJSON: String = row["previousValue"],
                      let newJSON: String = row["newValue"],
                      let previous = try? JSONDecoder().decode(Span.self, from: Data(previousJSON.utf8)),
                      let corrected = try? JSONDecoder().decode(Span.self, from: Data(newJSON.utf8))
                else { continue }
                startDeltas.append(corrected.startMs - previous.startMs)
                endDeltas.append(corrected.endMs - previous.endMs)
            }
            guard startDeltas.count >= 3 else { return nil }
            return (
                startDeltas.reduce(0, +) / startDeltas.count,
                endDeltas.reduce(0, +) / endDeltas.count
            )
        }
    }

    public func append(
        episodeID: Episode.ID,
        segmentID: DetectedSegment.ID?,
        type: String,
        source: Source,
        previousValue: String? = nil,
        newValue: String? = nil
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO corrections
                (id, episodeId, segmentId, type, source, previousValue, newValue, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString, episodeID, segmentID?.rawValue.uuidString,
                    type, source.rawValue, previousValue, newValue, Date(),
                ]
            )
        }
    }

    public func count(episodeID: Episode.ID? = nil) async throws -> Int {
        try await database.read { db in
            if let episodeID {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM corrections WHERE episodeId = ?",
                    arguments: [episodeID]
                ) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM corrections") ?? 0
        }
    }
}
