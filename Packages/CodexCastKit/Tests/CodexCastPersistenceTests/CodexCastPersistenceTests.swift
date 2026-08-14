import CodexCastCore
import Foundation
import GRDB
import Testing

@testable import CodexCastPersistence

@Suite("Schema and migrations")
struct MigrationTests {
    @Test("A fresh database migrates and creates every table the spec calls for")
    func freshMigration() async throws {
        let database = try AppDatabase.inMemory()

        let tables = try await database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }

        let expected = [
            "ad_patterns", "calibration_bins", "chapters", "corrections",
            "detected_segments", "episodes", "inference_log", "never_skip_rules",
            "playback_signals", "podcasts", "position_rules", "sponsors",
            "suggestions", "transcript_segments", "transcripts",
        ]
        for table in expected {
            #expect(tables.contains(table), "missing table: \(table)")
        }
    }

    @Test("Migrating an already-migrated database is a no-op")
    func migrationIsIdempotent() async throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue)

        let applied = try await queue.read { db in
            try AppDatabase.migrator.appliedMigrations(db)
        }
        #expect(applied == ["v1.initial"])
    }

    /// Deleting a show must not leave its episodes, transcripts, and segments
    /// behind as orphans.
    @Test("Deleting a podcast cascades to its episodes")
    func cascadeDelete() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!,
            title: "Show"
        )
        try await episodes.upsert(
            [ParsedEpisodeInput(guid: "a", title: "Ep 1")],
            podcastID: podcast.id
        )

        try await podcasts.unsubscribe(podcastID: podcast.id)

        let remaining = try await episodes.episodes(podcastID: podcast.id)
        #expect(remaining.isEmpty)
    }
}

@Suite("Subscriptions and episodes")
struct LibraryRepositoryTests {
    @Test("Subscribing twice to the same feed URL does not duplicate the show")
    func subscribeIsIdempotent() async throws {
        let database = try AppDatabase.inMemory()
        let repository = PodcastRepository(database: database)
        let url = URL(string: "https://feeds.megaphone.fm/ridehome")!

        let first = try await repository.subscribe(feedURL: url, title: "Tech Brew Ride Home")
        let second = try await repository.subscribe(feedURL: url, title: "Renamed")

        #expect(first.id == second.id)
        #expect(try await repository.all().count == 1)
    }

    @Test("Upsert inserts new episodes and refreshes existing ones by guid")
    func upsertMatchesOnGUID() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!,
            title: "Show"
        )

        let inserted = try await episodes.upsert(
            [
                ParsedEpisodeInput(guid: "a", title: "Original title"),
                ParsedEpisodeInput(guid: "b", title: "Second"),
            ],
            podcastID: podcast.id
        )
        #expect(inserted == 2)

        // A refresh where one title changed must update, not duplicate.
        let insertedAgain = try await episodes.upsert(
            [
                ParsedEpisodeInput(guid: "a", title: "Corrected title"),
                ParsedEpisodeInput(guid: "c", title: "Third"),
            ],
            podcastID: podcast.id
        )
        #expect(insertedAgain == 1)

        let all = try await episodes.episodes(podcastID: podcast.id)
        #expect(all.count == 3)
        #expect(all.first { $0.guid == "a" }?.title == "Corrected title")
    }

    /// Local state belongs to this device. A feed refresh must never clobber a
    /// download path or a playback position.
    @Test("A feed refresh preserves local download state")
    func refreshPreservesLocalState() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!,
            title: "Show"
        )
        try await episodes.upsert([ParsedEpisodeInput(guid: "a", title: "Ep")], podcastID: podcast.id)

        let episode = try #require(try await episodes.episodes(podcastID: podcast.id).first)
        _ = try await episodes.recordDownload(
            episodeID: episode.id,
            localPath: "/tmp/a.mp3",
            mediaHash: "hash-1"
        )

        try await episodes.upsert(
            [ParsedEpisodeInput(guid: "a", title: "Ep (updated)")],
            podcastID: podcast.id
        )

        let after = try #require(try await episodes.find(id: episode.id))
        #expect(after.title == "Ep (updated)")
        #expect(after.localPath == "/tmp/a.mp3")
        #expect(after.mediaHash == "hash-1")
    }

    /// Dynamic ad insertion means a re-download can legitimately contain
    /// different ads at different offsets, so cached segments must go.
    @Test("A changed media hash invalidates that episode's detected segments")
    func changedHashInvalidatesSegments() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!,
            title: "Show"
        )
        try await episodes.upsert([ParsedEpisodeInput(guid: "a", title: "Ep")], podcastID: podcast.id)
        let episode = try #require(try await episodes.episodes(podcastID: podcast.id).first)

        _ = try await episodes.recordDownload(
            episodeID: episode.id, localPath: "/tmp/a.mp3", mediaHash: "hash-1"
        )
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO detected_segments
                (id, episodeId, startMs, endMs, kind, confidence, provenance, userState, createdAt)
                VALUES (?, ?, 0, 1000, 'ad', 0.9, '{}', 'unreviewed', ?)
                """,
                arguments: [UUID().uuidString, episode.id, Date()]
            )
        }

        let invalidated = try await episodes.recordDownload(
            episodeID: episode.id, localPath: "/tmp/a.mp3", mediaHash: "hash-2"
        )

        #expect(invalidated)
        let remaining = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM detected_segments WHERE episodeId = ?",
                arguments: [episode.id]
            ) ?? 0
        }
        #expect(remaining == 0)
    }

    @Test("An unchanged hash on re-download keeps the segments")
    func unchangedHashKeepsSegments() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!, title: "Show"
        )
        try await episodes.upsert([ParsedEpisodeInput(guid: "a", title: "Ep")], podcastID: podcast.id)
        let episode = try #require(try await episodes.episodes(podcastID: podcast.id).first)

        _ = try await episodes.recordDownload(
            episodeID: episode.id, localPath: "/tmp/a.mp3", mediaHash: "hash-1"
        )
        let invalidated = try await episodes.recordDownload(
            episodeID: episode.id, localPath: "/tmp/a.mp3", mediaHash: "hash-1"
        )

        #expect(!invalidated)
    }

    @Test("Cache validators round-trip and a stored error is cleared on success")
    func cacheValidators() async throws {
        let database = try AppDatabase.inMemory()
        let repository = PodcastRepository(database: database)

        let podcast = try await repository.subscribe(
            feedURL: URL(string: "https://example.com/feed")!, title: "Show"
        )
        try await repository.recordError(podcastID: podcast.id, description: "boom")
        try await repository.updateCacheValidators(
            podcastID: podcast.id, etag: "\"v1\"", lastModified: "Wed, 13 Aug 2026 10:00:00 GMT"
        )

        let stored = try #require(
            try await repository.find(feedURL: URL(string: "https://example.com/feed")!)
        )
        #expect(stored.etag == "\"v1\"")
        #expect(stored.lastErrorDescription == nil)
    }
}

@Suite("Transcript persistence")
struct TranscriptRepositoryTests {
    /// Transcription is the most expensive stage in the pipeline. Persisting it
    /// is what stops it running twice for one episode.
    @Test("A transcript round-trips with timings and speakers intact")
    func roundTrip() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)
        let transcripts = TranscriptRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!, title: "Show"
        )
        try await episodes.upsert([ParsedEpisodeInput(guid: "a", title: "Ep")], podcastID: podcast.id)
        let episode = try #require(try await episodes.episodes(podcastID: podcast.id).first)

        let transcript = TimedTranscript(
            source: .podcasting20,
            segments: [
                .init(startMs: 31_752, endMs: 35_961, text: "Hello there", speaker: "Chris"),
                .init(startMs: 35_961, endMs: 37_610, text: "And welcome", speaker: "Wes"),
            ]
        )
        try await transcripts.save(transcript, episodeID: episode.id)

        let loaded = try #require(try await transcripts.transcript(episodeID: episode.id))
        #expect(loaded == transcript)
        #expect(loaded.segments.first?.speaker == "Chris")
        #expect(try await transcripts.hasTranscript(episodeID: episode.id))
    }

    @Test("Re-saving replaces segments rather than appending them")
    func resaveReplaces() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)
        let transcripts = TranscriptRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!, title: "Show"
        )
        try await episodes.upsert([ParsedEpisodeInput(guid: "a", title: "Ep")], podcastID: podcast.id)
        let episode = try #require(try await episodes.episodes(podcastID: podcast.id).first)

        try await transcripts.save(
            TimedTranscript(source: .onDevice, segments: [
                .init(startMs: 0, endMs: 1_000, text: "first pass"),
            ]),
            episodeID: episode.id
        )
        try await transcripts.save(
            TimedTranscript(source: .podcasting20, segments: [
                .init(startMs: 0, endMs: 1_000, text: "better transcript from the feed"),
            ]),
            episodeID: episode.id
        )

        let loaded = try #require(try await transcripts.transcript(episodeID: episode.id))
        #expect(loaded.segments.count == 1)
        #expect(loaded.source == .podcasting20)
    }
}

@Suite("Pattern search (FTS5)")
struct AdPatternRepositoryTests {
    private func makeDatabase() async throws -> (AppDatabase, Podcast.ID) {
        let database = try AppDatabase.inMemory()
        let podcast = try await PodcastRepository(database: database).subscribe(
            feedURL: URL(string: "https://example.com/feed")!, title: "Show"
        )
        return (database, podcast.id)
    }

    @Test("An identical read script is found by full-text search")
    func findsExactScript() async throws {
        let (database, podcastID) = try await makeDatabase()
        let repository = AdPatternRepository(database: database)

        try await repository.insert(
            AdPatternRecord(
                podcastId: podcastID,
                text: "This episode is brought to you by Squarespace. Head to squarespace.com slash show."
            )
        )

        let matches = try await repository.search(
            matching: "this episode is brought to you by Squarespace, head to squarespace.com",
            podcastID: podcastID
        )

        #expect(matches.count == 1)
        #expect(matches.first?.text.contains("Squarespace") == true)
    }

    /// The single most convincing demonstration that the design works: a
    /// sponsor learned on one show caught on a different one. Global patterns
    /// are how that happens.
    @Test("A global pattern matches on a show it was never learned from")
    func globalPatternCrossesShows() async throws {
        let (database, podcastID) = try await makeDatabase()
        let repository = AdPatternRepository(database: database)
        let otherPodcast = try await PodcastRepository(database: database).subscribe(
            feedURL: URL(string: "https://example.com/other")!, title: "Other Show"
        )

        try await repository.insert(
            AdPatternRecord(podcastId: nil, text: "Go to squarespace.com and use code PODCAST")
        )

        let matches = try await repository.search(
            matching: "go to squarespace.com and use code PODCAST",
            podcastID: otherPodcast.id
        )

        #expect(matches.count == 1)
        #expect(podcastID != otherPodcast.id)
    }

    @Test("A pattern scoped to one show does not match another show")
    func scopedPatternDoesNotLeak() async throws {
        let (database, podcastID) = try await makeDatabase()
        let repository = AdPatternRepository(database: database)
        let otherPodcast = try await PodcastRepository(database: database).subscribe(
            feedURL: URL(string: "https://example.com/other")!, title: "Other Show"
        )

        try await repository.insert(
            AdPatternRecord(podcastId: podcastID, text: "Support us on Patreon at patreon.com/thisshow")
        )

        let matches = try await repository.search(
            matching: "support us on patreon at patreon.com/thisshow",
            podcastID: otherPodcast.id
        )

        #expect(matches.isEmpty)
    }

    /// Transcript text is full of punctuation that FTS5 would otherwise read as
    /// query syntax.
    @Test("Search text containing FTS operators does not blow up the query")
    func handlesFTSOperatorsInInput() async throws {
        let (database, podcastID) = try await makeDatabase()
        let repository = AdPatternRepository(database: database)

        try await repository.insert(
            AdPatternRecord(podcastId: podcastID, text: "visit example dot com today")
        )

        let matches = try await repository.search(
            matching: "visit \"example\" AND (dot OR com) NEAR today*",
            podcastID: podcastID
        )

        #expect(!matches.isEmpty)
    }

    @Test("Deleting a pattern keeps the FTS index in step")
    func ftsStaysSynchronized() async throws {
        let (database, podcastID) = try await makeDatabase()
        let repository = AdPatternRepository(database: database)

        let inserted = try await repository.insert(
            AdPatternRecord(podcastId: podcastID, text: "unique sponsor phrase here")
        )
        try await database.write { db in
            _ = try AdPatternRecord.deleteOne(db, key: inserted.id)
        }

        let matches = try await repository.search(matching: "unique sponsor phrase here")
        #expect(matches.isEmpty)
    }

    @Test("False-positive rate drives demotion thresholds")
    func falsePositiveRate() async throws {
        let (database, podcastID) = try await makeDatabase()
        let repository = AdPatternRepository(database: database)

        let record = try await repository.insert(
            AdPatternRecord(podcastId: podcastID, text: "a mattress you will love")
        )
        try await repository.recordConfirmation(patternID: record.id)
        try await repository.recordFalsePositive(patternID: record.id)
        try await repository.recordFalsePositive(patternID: record.id)

        let stored = try #require(try await repository.all().first)
        #expect(stored.confirmCount == 1)
        #expect(stored.falsePositiveCount == 2)
        #expect(abs(stored.falsePositiveRate - 2.0 / 3.0) < 0.001)
    }

    @Test("Normalization makes punctuation and case irrelevant to matching")
    func normalization() {
        #expect(
            PatternNormalizer.normalize("Squarespace.com — use code PODCAST!")
                == "squarespace com use code podcast"
        )
    }
}

@Suite("Corrections")
struct CorrectionRepositoryTests {
    /// Corrections are the user's accumulated effort and the raw material the
    /// learning layer is built from, so the API offers no way to delete them.
    @Test("Corrections accumulate and record whether they were explicit")
    func appendOnly() async throws {
        let database = try AppDatabase.inMemory()
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)
        let corrections = CorrectionRepository(database: database)

        let podcast = try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/feed")!, title: "Show"
        )
        try await episodes.upsert([ParsedEpisodeInput(guid: "a", title: "Ep")], podcastID: podcast.id)
        let episode = try #require(try await episodes.episodes(podcastID: podcast.id).first)

        try await corrections.append(
            episodeID: episode.id, segmentID: nil, type: "confirm", source: .explicit
        )
        try await corrections.append(
            episodeID: episode.id, segmentID: nil, type: "rewindAfterSkip", source: .implicit
        )

        #expect(try await corrections.count() == 2)

        let sources = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT source FROM corrections ORDER BY type")
        }
        #expect(Set(sources) == ["explicit", "implicit"])
    }
}
