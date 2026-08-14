import Foundation

/// A UUID identifier tagged with the entity it belongs to, so an `Episode.ID`
/// cannot be passed where a `Sponsor.ID` is expected. Detection carries IDs
/// across several subsystems (§5.0) and mixing them up would be silent.
public struct TaggedID<Tag: Sendable>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
