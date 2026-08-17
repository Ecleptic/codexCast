import Foundation
import GRDB

/// Owns the database connection and its migrations.
///
/// GRDB rather than SwiftData because the learning layer needs FTS5, custom SQL
/// for calibration aggregates, deterministic migrations, and the ability to open
/// the file outside the app and look at it. SwiftData provides none of that
/// cleanly (§6.0).
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database at the given path, creating the directory if needed.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        // Foreign keys are on by default in GRDB, but the cascades in this
        // schema are load-bearing — deleting a show must not orphan its
        // episodes, transcripts, and segments.
        configuration.foreignKeysEnabled = true

        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// In-memory database, for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Catches a migration edited after it has shipped, which would
        // otherwise diverge silently between a fresh install and an upgrade.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        Schema.register(in: &migrator)
        SchemaV2.register(in: &migrator)
        SchemaV3.register(in: &migrator)
        SchemaV4.register(in: &migrator)
        SchemaV5.register(in: &migrator)
        SchemaV6.register(in: &migrator)
        SchemaV7.register(in: &migrator)
        return migrator
    }

    public func read<T: Sendable>(
        _ block: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await writer.read(block)
    }

    public func write<T: Sendable>(
        _ block: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await writer.write(block)
    }
}
