import CodexCastCore
import Foundation
import GRDB
import Testing

@testable import CodexCastPersistence

private struct Fixture {
    let database: AppDatabase
    let podcasts: PodcastRepository
    let episodes: EpisodeRepository
    let playlists: PlaylistRepository
    let retention: RetentionPolicy

    init() throws {
        database = try AppDatabase.inMemory()
        podcasts = PodcastRepository(database: database)
        episodes = EpisodeRepository(database: database)
        playlists = PlaylistRepository(database: database)
        retention = RetentionPolicy(database: database)
    }

    func makeShow(_ name: String) async throws -> PodcastRecord {
        try await podcasts.subscribe(
            feedURL: URL(string: "https://example.com/\(name).rss")!,
            title: name
        )
    }

    /// Episodes numbered oldest-to-newest, one day apart.
    func makeEpisodes(_ count: Int, podcastID: Podcast.ID) async throws -> [EpisodeRecord] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let inputs = (0..<count).map { index in
            ParsedEpisodeInput(
                guid: "\(podcastID)-\(index)",
                title: "Episode \(index)",
                publishedAt: base.addingTimeInterval(Double(index) * 86_400),
                durationMs: (index + 1) * 60_000
            )
        }
        try await episodes.upsert(inputs, podcastID: podcastID)
        return try await episodes.episodes(podcastID: podcastID)
    }
}

@Suite("Schema migration to v2")
struct MigrationV2Tests {
    @Test("v2 adds library-management tables without disturbing v1 data")
    func migratesCleanly() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        _ = try await fixture.makeEpisodes(2, podcastID: show.id)

        let applied = try await fixture.database.read { db in
            try AppDatabase.migrator.appliedMigrations(db)
        }
        // The chain grows over time; what matters here is that v2 applied
        // and in order after v1.
        #expect(Array(applied.prefix(2)) == ["v1.initial", "v2.libraryManagement"])

        // v1 data survives the v2 migration.
        let surviving = try await fixture.episodes.episodes(podcastID: show.id)
        #expect(surviving.count == 2)
    }
}

@Suite("Playlists")
struct PlaylistTests {
    @Test("Built-in playlists are created once and are idempotent")
    func builtIns() async throws {
        let fixture = try Fixture()

        try await fixture.playlists.ensureBuiltIns()
        try await fixture.playlists.ensureBuiltIns()

        let all = try await fixture.playlists.all()
        #expect(all.count == 2)
        #expect(all.map(\.name) == [Playlist.allEpisodesName, Playlist.upNextName])
        #expect(all.allSatisfy { $0.isBuiltIn })
    }

    @Test("Built-in playlists cannot be deleted")
    func builtInsProtected() async throws {
        let fixture = try Fixture()
        try await fixture.playlists.ensureBuiltIns()
        let allEpisodes = try #require(try await fixture.playlists.all().first)

        try await fixture.playlists.delete(allEpisodes.id)

        let remaining = try await fixture.playlists.all()
        #expect(remaining.count == 2)
    }

    @Test("A user playlist can be created and deleted")
    func userPlaylistLifecycle() async throws {
        let fixture = try Fixture()
        try await fixture.playlists.ensureBuiltIns()

        let daily = try await fixture.playlists.create(name: "Daily podcasts", colorName: "yellow")
        let withUser = try await fixture.playlists.all()
        #expect(withUser.count == 3)

        try await fixture.playlists.delete(daily.id)
        let afterDelete = try await fixture.playlists.all()
        #expect(afterDelete.count == 2)
    }

    /// A rules-based playlist is a live query across shows.
    @Test("Rules filter by show and unplayed state, and sort as configured")
    func rulesBasedMembership() async throws {
        let fixture = try Fixture()
        let daily = try await fixture.makeShow("Daily")
        let weekly = try await fixture.makeShow("Weekly")
        _ = try await fixture.makeEpisodes(3, podcastID: daily.id)
        _ = try await fixture.makeEpisodes(2, podcastID: weekly.id)

        let playlist = try await fixture.playlists.create(
            name: "Just Daily",
            rules: Playlist.Rules(includedPodcastIDs: [daily.id], sortOrder: .newestFirst)
        )

        let episodes = try await fixture.playlists.episodes(in: playlist)
        #expect(episodes.count == 3)
        #expect(episodes.allSatisfy { $0.podcastId == daily.id })
        // Newest first.
        #expect(episodes.first?.title == "Episode 2")
    }

    @Test("An excluded show is left out even when nothing is explicitly included")
    func exclusionRules() async throws {
        let fixture = try Fixture()
        let keep = try await fixture.makeShow("Keep")
        let drop = try await fixture.makeShow("Drop")
        _ = try await fixture.makeEpisodes(2, podcastID: keep.id)
        _ = try await fixture.makeEpisodes(2, podcastID: drop.id)

        let playlist = try await fixture.playlists.create(
            name: "Everything but Drop",
            rules: Playlist.Rules(excludedPodcastIDs: [drop.id])
        )

        let episodes = try await fixture.playlists.episodes(in: playlist)
        #expect(episodes.count == 2)
        #expect(episodes.allSatisfy { $0.podcastId == keep.id })
    }

    /// The queue is a hand-curated playlist; ordering is the listener's.
    @Test("A curated playlist keeps manual order and survives reordering")
    func curatedOrdering() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(3, podcastID: show.id)
        let queue = try await fixture.playlists.create(name: "Up Next")

        for episode in episodes {
            try await fixture.playlists.append(episodeID: episode.id, to: queue.id)
        }

        let initial = try await fixture.playlists.episodes(in: queue)
        #expect(initial.map(\.id) == episodes.map(\.id))

        let reversed = Array(episodes.map(\.id).reversed())
        try await fixture.playlists.reorder(playlistID: queue.id, episodeIDs: reversed)

        let reordered = try await fixture.playlists.episodes(in: queue)
        #expect(reordered.map(\.id) == reversed)
    }

    @Test("Adding the same episode twice does not duplicate it")
    func noDuplicateEntries() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(1, podcastID: show.id)
        let queue = try await fixture.playlists.create(name: "Up Next")

        try await fixture.playlists.append(episodeID: episodes[0].id, to: queue.id)
        try await fixture.playlists.append(episodeID: episodes[0].id, to: queue.id)

        let deduped = try await fixture.playlists.episodes(in: queue)
        #expect(deduped.count == 1)
    }

    @Test("Removing an episode takes it out of the playlist, not the library")
    func removalIsScopedToPlaylist() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(2, podcastID: show.id)
        let queue = try await fixture.playlists.create(name: "Up Next")

        for episode in episodes {
            try await fixture.playlists.append(episodeID: episode.id, to: queue.id)
        }
        try await fixture.playlists.remove(episodeID: episodes[0].id, from: queue.id)

        let queued = try await fixture.playlists.episodes(in: queue)
        #expect(queued.count == 1)
        let surviving = try await fixture.episodes.episodes(podcastID: show.id)
        #expect(surviving.count == 2)
    }
}

@Suite("Episode limits (retention)")
struct RetentionTests {
    private func downloadAll(_ fixture: Fixture, _ episodes: [EpisodeRecord]) async throws {
        for episode in episodes {
            _ = try await fixture.episodes.recordDownload(
                episodeID: episode.id,
                localPath: "/tmp/\(episode.id).mp3",
                mediaHash: "hash-\(episode.id)"
            )
        }
    }

    @Test("No limit means nothing is ever evicted")
    func unlimitedByDefault() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(10, podcastID: show.id)
        try await downloadAll(fixture, episodes)

        let evictions = try await fixture.retention.evictions(podcastID: show.id)
        #expect(evictions.isEmpty)
    }

    @Test("Keeping the 3 newest evicts the older downloads")
    func keepsNewest() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(6, podcastID: show.id)
        try await downloadAll(fixture, episodes)
        try await fixture.retention.setLimit(3, podcastID: show.id)

        let evictions = try await fixture.retention.evictions(podcastID: show.id)

        #expect(evictions.count == 3)
        // The three oldest go; "Episode 0" is the oldest of six.
        let evictedIDs = Set(evictions.map(\.episodeID))
        let oldest = episodes.sorted { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }
        #expect(evictedIDs == Set(oldest.prefix(3).map(\.id)))
    }

    /// Re-downloading an episode to resume it would be maddening.
    @Test("An episode with playback progress is never evicted")
    func inProgressIsProtected() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(5, podcastID: show.id)
        try await downloadAll(fixture, episodes)
        try await fixture.retention.setLimit(1, podcastID: show.id)

        let oldest = episodes.min { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }!
        try await fixture.database.write { db in
            try db.execute(
                sql: "UPDATE episodes SET playbackPositionMs = 60000 WHERE id = ?",
                arguments: [oldest.id]
            )
        }

        let evictions = try await fixture.retention.evictions(podcastID: show.id)

        #expect(!evictions.contains { $0.episodeID == oldest.id })
    }

    @Test("The now-playing episode is never evicted")
    func nowPlayingIsProtected() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(5, podcastID: show.id)
        try await downloadAll(fixture, episodes)
        try await fixture.retention.setLimit(1, podcastID: show.id)

        let oldest = episodes.min { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }!
        let evictions = try await fixture.retention.evictions(
            podcastID: show.id, nowPlayingEpisodeID: oldest.id
        )

        #expect(!evictions.contains { $0.episodeID == oldest.id })
    }

    /// The point of A5.3: audio is disposable, learning is not.
    @Test("Eviction clears the media path but keeps transcripts and segments")
    func evictionPreservesLearning() async throws {
        let fixture = try Fixture()
        let show = try await fixture.makeShow("Show")
        let episodes = try await fixture.makeEpisodes(2, podcastID: show.id)
        try await downloadAll(fixture, episodes)
        let victim = episodes[0]

        let transcripts = TranscriptRepository(database: fixture.database)
        try await transcripts.save(
            TimedTranscript(source: .onDevice, segments: [
                .init(startMs: 0, endMs: 1_000, text: "hello"),
            ]),
            episodeID: victim.id
        )
        try await fixture.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO detected_segments
                (id, episodeId, startMs, endMs, kind, confidence, provenance, userState, createdAt)
                VALUES (?, ?, 0, 30000, 'ad', 0.95, '{}', 'confirmed', ?)
                """,
                arguments: [UUID().uuidString, victim.id, Date()]
            )
        }

        try await fixture.retention.markEvicted([victim.id])

        let after = try #require(try await fixture.episodes.find(id: victim.id))
        #expect(after.localPath == nil)
        let restored = try await transcripts.transcript(episodeID: victim.id)
        #expect(restored != nil)

        let segmentCount = try await fixture.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM detected_segments WHERE episodeId = ?",
                arguments: [victim.id]
            ) ?? 0
        }
        #expect(segmentCount == 1)
    }
}

@Suite("Discover re-follow backfill")
struct ResubscribeBackfillTests {
    @Test("Re-subscribing an OPML-imported show backfills the iTunes ID")
    func backfillsCollectionID() async throws {
        let podcasts = PodcastRepository(database: try AppDatabase.inMemory())
        let url = URL(string: "https://example.com/feed.rss")!

        // OPML import: no iTunes identity.
        let imported = try await podcasts.subscribe(feedURL: url, title: "Show")
        #expect(imported.itunesCollectionID == nil)

        // Discover follow: same feed, now with the ID.
        let followed = try await podcasts.subscribe(
            feedURL: url, title: "Show", itunesCollectionID: 12345
        )
        #expect(followed.id == imported.id)
        #expect(followed.itunesCollectionID == 12345)

        let reloaded = try await podcasts.all().first { $0.id == imported.id }
        #expect(reloaded?.itunesCollectionID == 12345)
    }
}
