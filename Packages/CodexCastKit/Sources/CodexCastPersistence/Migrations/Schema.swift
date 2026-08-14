import Foundation
import GRDB

/// The database schema, as ordered migrations.
///
/// The whole §6.1 schema lands in v1, including tables nothing reads yet.
/// Creating empty tables costs nothing; reshaping a populated database on a
/// user's phone costs plenty, and the learning tables are the ones that will
/// hold data the user cannot recreate.
enum Schema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1.initial") { db in
            try createLibraryTables(db)
            try createTranscriptTables(db)
            // Learning precedes detection: detected_segments carries a foreign
            // key to sponsors, so that table has to exist first.
            try createLearningTables(db)
            try createDetectionTables(db)
            try createDiagnosticsTables(db)
        }
    }

    // MARK: - Library

    private static func createLibraryTables(_ db: Database) throws {
        try db.create(table: "podcasts") { table in
            table.primaryKey("id", .text)
            table.column("feedURL", .text).notNull().unique()
            table.column("itunesCollectionID", .integer)
            table.column("title", .text).notNull()
            table.column("author", .text)
            table.column("summary", .text)
            table.column("imageURL", .text)
            table.column("addedAt", .datetime).notNull()

            // Settings are stored as JSON blobs rather than exploded into
            // columns: they are read whole, written whole, and never queried
            // by field.
            table.column("skipPolicy", .text)
            table.column("pipelineSettings", .text)
            table.column("playbackSettings", .text)
            table.column("notificationSettings", .text)
            table.column("confidenceThresholdOverride", .double)
            table.column("preferredRendition", .text)
            table.column("notes", .text)

            // Conditional-GET validators, so an unchanged feed costs no body.
            table.column("etag", .text)
            table.column("lastModified", .text)
            table.column("lastRefreshedAt", .datetime)
            table.column("lastErrorDescription", .text)
        }

        try db.create(table: "episodes") { table in
            table.primaryKey("id", .text)
            table.belongsTo("podcast", onDelete: .cascade).notNull()
            table.column("guid", .text).notNull()
            table.column("title", .text).notNull()
            table.column("summary", .text)
            table.column("publishedAt", .datetime)
            table.column("durationMs", .integer)
            table.column("imageURL", .text)
            table.column("episodeNumber", .integer)
            table.column("seasonNumber", .integer)

            table.column("renditions", .text)
            table.column("selectedRenditionID", .text)
            table.column("feedTranscripts", .text)
            table.column("feedChaptersURL", .text)

            table.column("localPath", .text)
            /// Dynamic ad insertion means a re-download may legitimately differ.
            /// When this changes, the episode's segments are invalidated and
            /// detection is requeued (§4.1).
            table.column("mediaHash", .text)
            table.column("transcriptSource", .text)
            table.column("processingState", .text).notNull().defaults(to: "pending")
            table.column("notTranscribableReason", .text)

            table.column("playbackPositionMs", .integer).notNull().defaults(to: 0)
            table.column("isPlayed", .boolean).notNull().defaults(to: false)

            // An episode is identified within its show by guid; the same guid
            // across two shows is not a conflict.
            table.uniqueKey(["podcastId", "guid"])
        }

        try db.create(indexOn: "episodes", columns: ["publishedAt"])
    }

    // MARK: - Transcripts and chapters

    private static func createTranscriptTables(_ db: Database) throws {
        try db.create(table: "transcripts") { table in
            table.primaryKey("episodeId", .text)
                .references("episodes", onDelete: .cascade)
            table.column("source", .text).notNull()
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: "transcript_segments") { table in
            table.autoIncrementedPrimaryKey("id")
            table.belongsTo("episode", onDelete: .cascade).notNull()
            table.column("idx", .integer).notNull()
            table.column("startMs", .integer).notNull()
            table.column("endMs", .integer).notNull()
            table.column("text", .text).notNull()
            table.column("speaker", .text)

            table.uniqueKey(["episodeId", "idx"])
        }

        try db.create(indexOn: "transcript_segments", columns: ["episodeId", "startMs"])

        try db.create(table: "chapters") { table in
            table.primaryKey("id", .text)
            table.belongsTo("episode", onDelete: .cascade).notNull()
            table.column("startMs", .integer).notNull()
            table.column("title", .text).notNull()
            table.column("source", .text).notNull()
            table.column("imageURL", .text)
            table.column("url", .text)
        }

        try db.create(indexOn: "chapters", columns: ["episodeId", "startMs"])
    }

    // MARK: - Detection

    private static func createDetectionTables(_ db: Database) throws {
        try db.create(table: "detected_segments") { table in
            table.primaryKey("id", .text)
            table.belongsTo("episode", onDelete: .cascade).notNull()
            table.column("startMs", .integer).notNull()
            table.column("endMs", .integer).notNull()
            table.column("kind", .text).notNull()
            table.column("confidence", .double).notNull()
            /// Which stage produced this and on what evidence. Corrections route
            /// by provenance — a bad pattern is demoted, a bad model call
            /// becomes a negative exemplar, and the two must never be conflated.
            table.column("provenance", .text).notNull()
            table.column("rationale", .text)
            table.column("sponsorId", .text).references("sponsors", onDelete: .setNull)
            table.column("userState", .text).notNull().defaults(to: "unreviewed")
            /// Adjacent segments merged into one skip block share this. The UI
            /// presents the block; the database keeps the components, so
            /// rejecting one spot preserves the learning from the others.
            table.column("chunkId", .text)
            table.column("createdAt", .datetime).notNull()
            table.column("reviewedAt", .datetime)
        }

        try db.create(indexOn: "detected_segments", columns: ["episodeId", "startMs"])

        try db.create(table: "never_skip_rules") { table in
            table.primaryKey("id", .text)
            table.column("podcastId", .text).references("podcasts", onDelete: .cascade)
            table.column("episodeId", .text).references("episodes", onDelete: .cascade)
            table.column("startMs", .integer).notNull()
            table.column("endMs", .integer).notNull()
            table.column("reason", .text)
            table.column("createdAt", .datetime).notNull()
        }
    }

    // MARK: - Learning

    private static func createLearningTables(_ db: Database) throws {
        try db.create(table: "sponsors") { table in
            table.primaryKey("id", .text)
            table.column("canonicalName", .text).notNull()
            table.column("aliases", .text)
            table.column("firstSeenAt", .datetime).notNull()
            table.column("lastSeenAt", .datetime).notNull()
            table.column("occurrenceCount", .integer).notNull().defaults(to: 0)
            table.column("embedding", .blob)
        }

        try db.create(indexOn: "sponsors", columns: ["canonicalName"])

        try db.create(table: "ad_patterns") { table in
            table.primaryKey("id", .text)
            table.column("sponsorId", .text).references("sponsors", onDelete: .setNull)
            /// Null scopes the pattern globally, which is how a sponsor learned
            /// on one show is caught on another.
            table.column("podcastId", .text).references("podcasts", onDelete: .cascade)
            table.column("text", .text).notNull()
            table.column("normalizedText", .text).notNull()
            table.column("embedding", .blob)
            table.column("confirmCount", .integer).notNull().defaults(to: 0)
            table.column("falsePositiveCount", .integer).notNull().defaults(to: 0)
            table.column("createdFrom", .text)
            table.column("createdAt", .datetime).notNull()
            table.column("lastMatchedAt", .datetime)
        }

        // Patterns are text, not timestamps, which is precisely why dynamic ad
        // insertion does not defeat them: a sponsor read inserted at 4:12 today
        // and 7:45 next week matches the same pattern both times.
        try db.create(virtualTable: "ad_patterns_fts", using: FTS5()) { table in
            table.synchronize(withTable: "ad_patterns")
            table.column("normalizedText")
            table.tokenizer = .porter(wrapping: .unicode61())
        }

        try db.create(table: "position_rules") { table in
            table.primaryKey("id", .text)
            table.belongsTo("podcast", onDelete: .cascade).notNull()
            table.column("anchor", .text).notNull()
            /// Welford's online algorithm: mean and M2 only, never the samples.
            table.column("meanDurationMs", .double).notNull().defaults(to: 0)
            table.column("m2", .double).notNull().defaults(to: 0)
            table.column("sampleCount", .integer).notNull().defaults(to: 0)
            table.column("hitCount", .integer).notNull().defaults(to: 0)
            table.column("missCount", .integer).notNull().defaults(to: 0)
            table.column("enabled", .boolean).notNull().defaults(to: true)
            /// A rule the user drew by hand is an instruction, not a hypothesis:
            /// it never auto-disables and Stage 2 never overrides it.
            table.column("userCreated", .boolean).notNull().defaults(to: false)
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: "corrections") { table in
            table.primaryKey("id", .text)
            table.belongsTo("episode", onDelete: .cascade).notNull()
            table.column("segmentId", .text)
            table.column("type", .text).notNull()
            /// Explicit corrections are authoritative; implicit playback signals
            /// are weak and may never create or disable a rule on their own.
            table.column("source", .text).notNull()
            table.column("previousValue", .text)
            table.column("newValue", .text)
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: "playback_signals") { table in
            table.autoIncrementedPrimaryKey("id")
            table.belongsTo("episode", onDelete: .cascade).notNull()
            table.column("segmentId", .text)
            table.column("kind", .text).notNull()
            table.column("positionMs", .integer).notNull()
            table.column("weight", .double).notNull().defaults(to: 1)
            table.column("createdAt", .datetime).notNull()
        }

        try db.create(table: "suggestions") { table in
            table.primaryKey("id", .text)
            table.belongsTo("podcast", onDelete: .cascade).notNull()
            table.column("kind", .text).notNull()
            table.column("payload", .text)
            table.column("evidenceCount", .integer).notNull().defaults(to: 0)
            table.column("createdAt", .datetime).notNull()
            table.column("dismissedAt", .datetime)
        }
    }

    // MARK: - Diagnostics

    private static func createDiagnosticsTables(_ db: Database) throws {
        try db.create(table: "calibration_bins") { table in
            table.column("stage", .text).notNull()
            table.column("decile", .integer).notNull()
            table.column("proposals", .integer).notNull().defaults(to: 0)
            table.column("confirms", .integer).notNull().defaults(to: 0)
            table.column("rejects", .integer).notNull().defaults(to: 0)
            table.column("updatedAt", .datetime).notNull()
            table.primaryKey(["stage", "decile"])
        }

        try db.create(table: "inference_log") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("episodeId", .text)
            table.column("timestamp", .datetime).notNull()
            table.column("windowIndex", .integer).notNull()
            table.column("windowTokens", .integer)
            table.column("outputTokens", .integer)
            table.column("wallClockMs", .integer)
            table.column("thermalState", .text)
            table.column("modelTier", .text)
        }
    }
}
