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
