import CodexCastCore
import Foundation
import GRDB

/// Per-stage, per-decile correction tallies backing §5.7 calibration.
public struct CalibrationRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func bins() async throws -> [ConfidenceCalibrator.Bin] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM calibration_bins")
            return rows.map { row in
                ConfidenceCalibrator.Bin(
                    stage: row["stage"], decile: row["decile"],
                    proposals: row["proposals"], confirms: row["confirms"],
                    rejects: row["rejects"]
                )
            }
        }
    }

    public func recordProposals(stage: String, deciles: [Int]) async throws {
        guard !deciles.isEmpty else { return }
        try await database.write { db in
            for decile in deciles {
                try db.execute(
                    sql: """
                    INSERT INTO calibration_bins (stage, decile, proposals, updatedAt)
                    VALUES (?, ?, 1, ?)
                    ON CONFLICT(stage, decile) DO UPDATE SET
                        proposals = proposals + 1, updatedAt = excluded.updatedAt
                    """,
                    arguments: [stage, decile, Date()]
                )
            }
        }
    }

    public func recordOutcome(stage: String, decile: Int, confirmed: Bool) async throws {
        let column = confirmed ? "confirms" : "rejects"
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO calibration_bins (stage, decile, \(column), updatedAt)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(stage, decile) DO UPDATE SET
                    \(column) = \(column) + 1, updatedAt = excluded.updatedAt
                """,
                arguments: [stage, decile, Date()]
            )
        }
    }

    /// Raw scores the on-device model reported recently, for the degenerate-
    /// confidence check. Stage lives inside the provenance JSON; a LIKE on
    /// the enum's case name is crude but the JSON shape is ours.
    public func recentModelRawConfidences(limit: Int = 200) async throws -> [Double] {
        try await database.read { db in
            try Double.fetchAll(
                db,
                sql: """
                SELECT COALESCE(rawConfidence, confidence) FROM detected_segments
                WHERE provenance LIKE '%onDeviceModel%'
                ORDER BY createdAt DESC LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }
}
