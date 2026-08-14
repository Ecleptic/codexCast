import CodexCastCore
import Foundation

/// A contiguous region that playback skips over, formed by merging adjacent
/// detected segments (§5.5).
///
/// Ads run in blocks — typically two to four spots of about thirty seconds back
/// to back — so skipping them individually would produce skip-play-skip
/// stutter. The block is what gets skipped, indicated, and undone as a unit,
/// while the database keeps the constituent segments so that rejecting one spot
/// does not discard the learning from the others.
public struct SkipBlock: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startMs: Int
    public var endMs: Int
    public var segmentIDs: [DetectedSegment.ID]

    public init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int,
        segmentIDs: [DetectedSegment.ID] = []
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.segmentIDs = segmentIDs
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func contains(_ mediaMs: Int) -> Bool {
        mediaMs >= startMs && mediaMs < endMs
    }
}

/// Maps between true media time and the time shown to the user.
///
/// **True media time is the source of truth.** The display timeline is derived
/// from it by removing skipped regions, and the two must never drift (§11.4).
/// Competing apps have well-documented failures here — episodes reporting
/// complete while still playing, scrubbing landing in dead zones — and they all
/// come from maintaining two independent representations. Here there is one,
/// plus a pure function between them.
///
/// With no skip blocks this is the identity mapping, which is why it is built
/// before skipping exists rather than retrofitted afterward.
public struct DisplayTimeline: Hashable, Sendable {
    public let mediaDurationMs: Int
    /// Normalized: sorted, merged, clamped to the media duration, and free of
    /// empty blocks.
    public let blocks: [SkipBlock]

    /// Cumulative skipped duration before each block, so conversion is a binary
    /// search rather than a scan.
    private let skippedBefore: [Int]

    public init(mediaDurationMs: Int, blocks: [SkipBlock] = []) {
        self.mediaDurationMs = max(0, mediaDurationMs)
        self.blocks = Self.normalize(blocks, mediaDurationMs: self.mediaDurationMs)

        var running = 0
        var prefix: [Int] = []
        prefix.reserveCapacity(self.blocks.count)
        for block in self.blocks {
            prefix.append(running)
            running += block.durationMs
        }
        self.skippedBefore = prefix
    }

    /// Overlapping or touching blocks are merged. Overlaps are not merely
    /// untidy: they would be double-counted in the duration arithmetic and the
    /// two timelines would drift apart.
    static func normalize(_ blocks: [SkipBlock], mediaDurationMs: Int) -> [SkipBlock] {
        let clamped = blocks.compactMap { block -> SkipBlock? in
            let start = max(0, min(block.startMs, mediaDurationMs))
            let end = max(0, min(block.endMs, mediaDurationMs))
            guard end > start else { return nil }
            return SkipBlock(id: block.id, startMs: start, endMs: end, segmentIDs: block.segmentIDs)
        }.sorted { $0.startMs < $1.startMs }

        var merged: [SkipBlock] = []
        for block in clamped {
            if var last = merged.last, block.startMs <= last.endMs {
                last.endMs = max(last.endMs, block.endMs)
                last.segmentIDs.append(contentsOf: block.segmentIDs)
                merged[merged.count - 1] = last
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    public var totalSkippedMs: Int {
        blocks.reduce(0) { $0 + $1.durationMs }
    }

    /// What the user sees as the episode length.
    public var displayDurationMs: Int {
        max(0, mediaDurationMs - totalSkippedMs)
    }

    /// The block containing this media time, if any.
    public func block(at mediaMs: Int) -> SkipBlock? {
        blocks.first { $0.contains(mediaMs) }
    }

    /// Converts true media time to displayed time.
    ///
    /// A media time inside a skipped block maps to that block's start, since
    /// from the listener's point of view no time passes there.
    public func displayMs(forMedia mediaMs: Int) -> Int {
        let clamped = max(0, min(mediaMs, mediaDurationMs))
        var skipped = 0

        for block in blocks {
            if clamped < block.startMs { break }
            if clamped < block.endMs {
                // Inside the block: everything before it has been skipped, and
                // the block itself contributes nothing.
                return max(0, block.startMs - skipped)
            }
            skipped += block.durationMs
        }

        return max(0, clamped - skipped)
    }

    /// Converts displayed time back to true media time — the scrubbing path.
    ///
    /// The result never lands inside a skipped block, which is the bug that
    /// produces "dead zones" on a scrubber in other apps.
    public func mediaMs(forDisplay displayMs: Int) -> Int {
        let clamped = max(0, min(displayMs, displayDurationMs))

        for (index, block) in blocks.enumerated() {
            let blockStartInDisplay = block.startMs - skippedBefore[index]
            if clamped < blockStartInDisplay {
                return clamped + skippedBefore[index]
            }
            if clamped == blockStartInDisplay {
                // Landing exactly on a skipped region resumes at its end, not
                // its start, or playback would immediately skip again.
                return block.endMs
            }
        }

        return clamped + totalSkippedMs
    }

    /// Where playback should continue from, given a media position. Returns the
    /// end of the block when inside one, otherwise the position unchanged.
    public func resumePosition(afterSkippingFrom mediaMs: Int) -> Int {
        guard let block = block(at: mediaMs) else { return mediaMs }
        return block.endMs
    }

    /// Media times at which a boundary observer should fire (§11.1). Only block
    /// starts matter — the observer seeks to the block end when one is reached.
    public var boundaryTimesMs: [Int] {
        blocks.map(\.startMs).filter { $0 > 0 }
    }

    /// Fraction of the episode flagged for skipping, from non-user-originated
    /// provenance only. Feeds the runaway guard in §5.6.
    public func flaggedFraction() -> Double {
        guard mediaDurationMs > 0 else { return 0 }
        return Double(totalSkippedMs) / Double(mediaDurationMs)
    }
}
