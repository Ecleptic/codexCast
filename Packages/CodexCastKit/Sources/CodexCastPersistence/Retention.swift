import CodexCastCore
import Foundation
import GRDB

/// Per-show download retention — "keep the N newest episodes" (A5.3, §8.4).
///
/// Deletes downloaded **media only**. Transcripts, detected segments, learned
/// patterns, and corrections are all kept: they are tiny compared to audio, and
/// they are the part that cannot be cheaply re-derived. Deleting a 200 MB file
/// should never cost the listener the ad labels they corrected by hand.
///
/// This matters far more with video, where episodes run to gigabytes (§8.3).
public struct RetentionPolicy: Sendable {
    /// Media the sweep decided to delete.
    public struct Eviction: Sendable {
        public var episodeID: Episode.ID
        public var localPath: String
    }

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func setLimit(_ limit: Int?, podcastID: Podcast.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET episodeLimit = ? WHERE id = ?",
                arguments: [limit, podcastID]
            )
        }
    }

    public func limit(podcastID: Podcast.ID) async throws -> Int? {
        try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT episodeLimit FROM podcasts WHERE id = ?",
                arguments: [podcastID]
            )
        }
    }

    /// Decides which downloads to evict for one show, newest-first.
    ///
    /// Never evicts the episode currently being listened to, and never evicts
    /// one with playback progress — a half-heard episode is not stale, and
    /// re-downloading it to resume would be maddening.
    public func evictions(
        podcastID: Podcast.ID,
        nowPlayingEpisodeID: Episode.ID? = nil
    ) async throws -> [Eviction] {
        try await database.read { db in
            guard let limit = try Int.fetchOne(
                db,
                sql: "SELECT episodeLimit FROM podcasts WHERE id = ?",
                arguments: [podcastID]
            ) else {
                return []   // NULL limit means unlimited
            }

            let downloaded = try EpisodeRecord
                .filter(Column("podcastId") == podcastID)
                .filter(Column("localPath") != nil)
                .order(Column("publishedAt").desc)
                .fetchAll(db)

            return downloaded
                .dropFirst(max(0, limit))
                .filter { episode in
                    guard episode.id != nowPlayingEpisodeID else { return false }
                    guard episode.playbackPositionMs == 0 || episode.isPlayed else { return false }
                    return true
                }
                .compactMap { episode in
                    episode.localPath.map { Eviction(episodeID: episode.id, localPath: $0) }
                }
        }
    }

    /// Clears the stored path after the file itself has been removed. Keeps
    /// everything else about the episode, including its learned segments.
    public func markEvicted(_ episodeIDs: [Episode.ID]) async throws {
        guard !episodeIDs.isEmpty else { return }
        try await database.write { db in
            for id in episodeIDs {
                try db.execute(
                    sql: "UPDATE episodes SET localPath = NULL WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// Bytes currently occupied by downloaded media for one show, for the
    /// storage screen (§8.4).
    public func downloadedByteCount(podcastID: Podcast.ID) async throws -> Int64 {
        let paths = try await database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT localPath FROM episodes WHERE podcastId = ? AND localPath IS NOT NULL",
                arguments: [podcastID]
            )
        }
        return paths.reduce(into: Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? Int64) ?? 0
        }
    }
}
