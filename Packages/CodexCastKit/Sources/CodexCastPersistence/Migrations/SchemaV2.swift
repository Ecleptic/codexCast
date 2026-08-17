import Foundation
import GRDB

/// v2 — library management (addendum A5): playlists and per-show retention.
///
/// A separate migration rather than an edit to v1: v1 has shipped to a
/// database on disk, and migrations are append-only from that moment.
enum SchemaV2 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2.libraryManagement") { db in
            // Retention: how many downloaded episodes to keep per show.
            // NULL means unlimited. Deletes media only — transcripts, detected
            // segments, and learned patterns survive, because they are small
            // and cannot be cheaply re-derived (A5.3).
            try db.alter(table: "podcasts") { table in
                table.add(column: "episodeLimit", .integer)
                table.add(column: "autoDownloadEnabled", .boolean).notNull().defaults(to: false)
            }

            // A playlist and the queue are the same object seen two ways, so
            // there is one model rather than two (A5.2).
            try db.create(table: "playlists") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("colorName", .text)
                table.column("iconName", .text)
                table.column("sortIndex", .integer).notNull().defaults(to: 0)
                /// Built-ins ("All Episodes", "Up Next") cannot be deleted.
                table.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                /// Rules as JSON: read whole, written whole, never queried by field.
                table.column("rules", .text)
                table.column("createdAt", .datetime).notNull()
            }

            // Manual ordering and manual membership. A rules-based playlist
            // uses no rows here; a hand-curated one uses only these.
            try db.create(table: "playlist_entries") { table in
                table.autoIncrementedPrimaryKey("id")
                table.belongsTo("playlist", onDelete: .cascade).notNull()
                table.belongsTo("episode", onDelete: .cascade).notNull()
                table.column("position", .integer).notNull()
                table.column("addedAt", .datetime).notNull()
                table.uniqueKey(["playlistId", "episodeId"])
            }

            try db.create(indexOn: "playlist_entries", columns: ["playlistId", "position"])
        }
    }
}

/// v3 — pinned podcasts: favorites sort to the top of the library grid.
enum SchemaV3 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3.pinnedPodcasts") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }
    }
}

/// v4 — followed vs added: every subscription is "added"; only followed shows
/// feed New Releases. Following defaults on, so existing libraries keep their
/// behavior until curated.
enum SchemaV4 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4.followedPodcasts") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "isFollowed", .boolean).notNull().defaults(to: true)
            }
        }
    }
}

/// v5 — calibration needs the score a stage actually reported, before any
/// adjustment: bins are keyed by raw-score decile, and the stored (possibly
/// calibrated) confidence would drift the keys (§5.7).
enum SchemaV5 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5.rawConfidence") { db in
            try db.alter(table: "detected_segments") { table in
                table.add(column: "rawConfidence", .double)
            }
        }
    }
}

/// v6 — A1: remembers that a feed transcript was checked against the actual
/// audio, so the (transcribe-3-samples) drift check runs once per episode.
enum SchemaV6 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6.transcriptDriftCheck") { db in
            try db.alter(table: "transcripts") { table in
                table.add(column: "driftCheckedAt", .datetime)
            }
        }
    }
}

/// v7 — audio fingerprints of confirmed ads. Dynamically inserted ads repeat
/// byte-identically across episodes and shows; one confirmation becomes an
/// acoustic detector everywhere (Stage 1b, roadmap round 2).
enum SchemaV7 {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7.adFingerprints") { db in
            try db.create(table: "ad_fingerprints") { table in
                table.primaryKey("id", .text)
                table.column("podcastId", .text).references("podcasts", onDelete: .setNull)
                table.column("sponsorId", .text).references("sponsors", onDelete: .setNull)
                table.column("label", .text)
                table.column("signature", .blob).notNull()
                table.column("durationMs", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
    }
}
