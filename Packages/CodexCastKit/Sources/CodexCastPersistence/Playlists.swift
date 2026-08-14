import CodexCastCore
import Foundation
import GRDB

/// A named collection of episodes across shows (A5.2).
///
/// Playlists and the Up Next queue are the same object: a queue is simply the
/// built-in playlist the player draws from. One model, two presentations.
public struct Playlist: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "playlists"

    public enum Tag: Sendable {}
    public typealias ID = TaggedID<Tag>

    /// Membership rules. A playlist with rules is a live query; a playlist
    /// without them is hand-curated through `playlist_entries`.
    public struct Rules: Hashable, Sendable, Codable {
        public enum SortOrder: String, Hashable, Sendable, Codable, CaseIterable {
            case newestFirst
            case oldestFirst
            case shortestFirst
            case longestFirst
        }

        /// Empty means every subscribed show.
        public var includedPodcastIDs: [Podcast.ID]
        public var excludedPodcastIDs: [Podcast.ID]
        public var unplayedOnly: Bool
        public var downloadedOnly: Bool
        public var sortOrder: SortOrder
        /// Cap on how many episodes the list shows.
        public var limit: Int?

        public init(
            includedPodcastIDs: [Podcast.ID] = [],
            excludedPodcastIDs: [Podcast.ID] = [],
            unplayedOnly: Bool = true,
            downloadedOnly: Bool = false,
            sortOrder: SortOrder = .newestFirst,
            limit: Int? = nil
        ) {
            self.includedPodcastIDs = includedPodcastIDs
            self.excludedPodcastIDs = excludedPodcastIDs
            self.unplayedOnly = unplayedOnly
            self.downloadedOnly = downloadedOnly
            self.sortOrder = sortOrder
            self.limit = limit
        }
    }

    public var id: ID
    public var name: String
    public var colorName: String?
    public var iconName: String?
    public var sortIndex: Int
    /// Built-ins cannot be deleted or renamed away.
    public var isBuiltIn: Bool
    /// JSON-encoded `Rules`; nil means hand-curated.
    public var rules: String?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        name: String,
        colorName: String? = nil,
        iconName: String? = nil,
        sortIndex: Int = 0,
        isBuiltIn: Bool = false,
        rules: Rules? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.iconName = iconName
        self.sortIndex = sortIndex
        self.isBuiltIn = isBuiltIn
        self.rules = rules.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? nil
        self.createdAt = createdAt
    }

    public var decodedRules: Rules? {
        guard let rules, let data = rules.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Rules.self, from: data)
    }

    /// The two built-ins every library starts with.
    public static let allEpisodesName = "All Episodes"
    public static let upNextName = "Up Next"
}

public struct PlaylistEntry: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "playlist_entries"

    public var id: Int64?
    public var playlistId: Playlist.ID
    public var episodeId: Episode.ID
    public var position: Int
    public var addedAt: Date

    public init(
        id: Int64? = nil,
        playlistId: Playlist.ID,
        episodeId: Episode.ID,
        position: Int,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.playlistId = playlistId
        self.episodeId = episodeId
        self.position = position
        self.addedAt = addedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct PlaylistRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Creates the built-in playlists if they are missing. Idempotent, so it
    /// can run at every launch.
    public func ensureBuiltIns() async throws {
        try await database.write { db in
            let existing = try Playlist.filter(Column("isBuiltIn") == true).fetchAll(db)
            let names = Set(existing.map(\.name))

            if !names.contains(Playlist.allEpisodesName) {
                var all = Playlist(
                    name: Playlist.allEpisodesName,
                    colorName: "orange",
                    iconName: "square.stack",
                    sortIndex: 0,
                    isBuiltIn: true,
                    rules: Playlist.Rules(unplayedOnly: true)
                )
                try all.insert(db)
            }
            if !names.contains(Playlist.upNextName) {
                // Hand-curated: the queue is ordered by the listener, not by a rule.
                var upNext = Playlist(
                    name: Playlist.upNextName,
                    colorName: "blue",
                    iconName: "text.line.first.and.arrowtriangle.forward",
                    sortIndex: 1,
                    isBuiltIn: true
                )
                try upNext.insert(db)
            }
        }
    }

    public func all() async throws -> [Playlist] {
        try await database.read { db in
            try Playlist.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
        }
    }

    @discardableResult
    public func create(
        name: String,
        colorName: String? = nil,
        iconName: String? = nil,
        rules: Playlist.Rules? = nil
    ) async throws -> Playlist {
        try await database.write { db in
            let count = try Playlist.fetchCount(db)
            var playlist = Playlist(
                name: name,
                colorName: colorName,
                iconName: iconName,
                sortIndex: count,
                rules: rules
            )
            try playlist.insert(db)
            return playlist
        }
    }

    /// Built-ins are protected: deleting "All Episodes" is not a thing.
    public func delete(_ id: Playlist.ID) async throws {
        try await database.write { db in
            guard let playlist = try Playlist.fetchOne(db, key: id), !playlist.isBuiltIn else {
                return
            }
            _ = try Playlist.deleteOne(db, key: id)
        }
    }

    // MARK: - Membership

    public func append(episodeID: Episode.ID, to playlistID: Playlist.ID) async throws {
        try await database.write { db in
            let next = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_entries WHERE playlistId = ?",
                arguments: [playlistID]
            ) ?? 0
            var entry = PlaylistEntry(playlistId: playlistID, episodeId: episodeID, position: next)
            // Already present is not an error; the listener asked twice.
            try? entry.insert(db)
        }
    }

    public func remove(episodeID: Episode.ID, from playlistID: Playlist.ID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_entries WHERE playlistId = ? AND episodeId = ?",
                arguments: [playlistID, episodeID]
            )
        }
    }

    /// Rewrites positions to match the given order — what a drag-to-reorder
    /// gesture commits.
    public func reorder(playlistID: Playlist.ID, episodeIDs: [Episode.ID]) async throws {
        try await database.write { db in
            for (index, episodeID) in episodeIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE playlist_entries SET position = ? WHERE playlistId = ? AND episodeId = ?",
                    arguments: [index, playlistID, episodeID]
                )
            }
        }
    }

    /// Resolves a playlist to its episodes.
    ///
    /// Membership is the UNION of two sources, because a category playlist
    /// like "Daily" holds whole shows (new episodes appear automatically) AND
    /// individually added episodes. Manual entries come first in their kept
    /// order; rule matches follow in the rules' sort.
    public func episodes(in playlist: Playlist, limit: Int = 200) async throws -> [EpisodeRecord] {
        try await database.read { db in
            let manual = try EpisodeRecord
                .fetchAll(db, sql: """
                    SELECT episodes.* FROM episodes
                    JOIN playlist_entries ON playlist_entries.episodeId = episodes.id
                    WHERE playlist_entries.playlistId = ?
                    ORDER BY playlist_entries.position
                    LIMIT ?
                    """, arguments: [playlist.id, limit])

            guard let rules = playlist.decodedRules else { return manual }

            var request = EpisodeRecord.all()
            if !rules.includedPodcastIDs.isEmpty {
                request = request.filter(rules.includedPodcastIDs.contains(Column("podcastId")))
            } else if manual.isEmpty {
                // A rules playlist with no shows selected matches everything;
                // one that ALSO has manual entries matches nothing extra.
            } else {
                return manual
            }
            if !rules.excludedPodcastIDs.isEmpty {
                request = request.filter(!rules.excludedPodcastIDs.contains(Column("podcastId")))
            }
            if rules.unplayedOnly {
                request = request.filter(Column("isPlayed") == false)
            }
            if rules.downloadedOnly {
                request = request.filter(Column("localPath") != nil)
            }
            switch rules.sortOrder {
            case .newestFirst: request = request.order(Column("publishedAt").desc)
            case .oldestFirst: request = request.order(Column("publishedAt"))
            case .shortestFirst: request = request.order(Column("durationMs"))
            case .longestFirst: request = request.order(Column("durationMs").desc)
            }

            let ruled = try request.limit(min(rules.limit ?? limit, limit)).fetchAll(db)
            let manualIDs = Set(manual.map(\.id))
            return manual + ruled.filter { !manualIDs.contains($0.id) }
        }
    }

    /// Sets the shows a playlist follows as a category — "Daily always has my
    /// daily podcasts". New episodes of these shows appear automatically.
    public func setIncludedShows(
        _ podcastIDs: [Podcast.ID],
        playlistID: Playlist.ID
    ) async throws {
        try await database.write { db in
            guard let playlist = try Playlist.fetchOne(db, key: playlistID) else { return }
            var rules = playlist.decodedRules ?? Playlist.Rules(unplayedOnly: false)
            rules.includedPodcastIDs = podcastIDs
            let json = (try? JSONEncoder().encode(rules))
                .flatMap { String(data: $0, encoding: .utf8) }
            try db.execute(
                sql: "UPDATE playlists SET rules = ? WHERE id = ?",
                arguments: [json, playlistID]
            )
        }
    }

    public func includedShows(playlistID: Playlist.ID) async throws -> [Podcast.ID] {
        try await database.read { db in
            guard let playlist = try Playlist.fetchOne(db, key: playlistID) else { return [] }
            return playlist.decodedRules?.includedPodcastIDs ?? []
        }
    }
}
