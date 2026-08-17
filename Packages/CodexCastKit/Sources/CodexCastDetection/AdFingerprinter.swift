import AVFoundation
import CodexCastCore
import Foundation
import ShazamKit

/// Audio fingerprints of confirmed ads — Shazam's matcher pointed at our own
/// catalog, entirely on device.
///
/// Dynamically inserted ads are the same audio file replayed across episodes
/// and shows on the same ad network. Text patterns catch the same WORDS;
/// fingerprints catch the same AUDIO — robust to transcription differences
/// and immune to the classifier having an off day. One confirmation becomes
/// a near-zero-false-positive detector everywhere (roadmap round 2, #1).
public enum AdFingerprinter {
    // MARK: - Signature capture (on confirm)

    /// Fingerprint of one slice of a local audio file, as portable data.
    /// Slices shorter than ~4s don't produce stable signatures; nil then.
    public static func signature(
        fileURL: URL, startMs: Int, endMs: Int
    ) throws -> Data? {
        guard endMs - startMs >= 4_000 else { return nil }
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let startFrame = AVAudioFramePosition(Double(startMs) / 1000 * format.sampleRate)
        let frameCount = AVAudioFrameCount(Double(endMs - startMs) / 1000 * format.sampleRate)
        guard startFrame + AVAudioFramePosition(frameCount) <= file.length else { return nil }

        file.framePosition = startFrame
        let generator = SHSignatureGenerator()
        var remaining = frameCount
        while remaining > 0 {
            let chunk = min(remaining, AVAudioFrameCount(format.sampleRate * 4))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            try generator.append(buffer, at: nil)
            remaining -= buffer.frameLength
        }
        return try generator.signature().dataRepresentation
    }

    // MARK: - Matching (at scan)

    public struct Reference: Sendable {
        public var id: String
        public var signature: Data
        public var durationMs: Int

        public init(id: String, signature: Data, durationMs: Int) {
            self.id = id
            self.signature = signature
            self.durationMs = durationMs
        }
    }

    public struct Match: Hashable, Sendable {
        public var referenceID: String
        public var startMs: Int
        public var endMs: Int
    }

    /// Scans a whole local file against the reference catalog by matching
    /// overlapping slices — a hit at slice T with reference offset O means
    /// the ad started near T − O. Consecutive hits on one reference merge.
    public static func matches(
        fileURL: URL,
        references: [Reference],
        sliceSeconds: Double = 12,
        hopSeconds: Double = 8
    ) async -> [Match] {
        guard !references.isEmpty else { return [] }
        guard let catalog = try? makeCatalog(references) else { return [] }
        guard let file = try? AVAudioFile(forReading: fileURL) else { return [] }
        let format = file.processingFormat
        let totalSeconds = Double(file.length) / format.sampleRate
        let durationByID = Dictionary(
            uniqueKeysWithValues: references.map { ($0.id, $0.durationMs) }
        )

        var hits: [(id: String, startMs: Int)] = []
        var offset = 0.0
        while offset + sliceSeconds <= totalSeconds {
            defer { offset += hopSeconds }
            file.framePosition = AVAudioFramePosition(offset * format.sampleRate)
            let frames = AVAudioFrameCount(sliceSeconds * format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  (try? file.read(into: buffer, frameCount: frames)) != nil,
                  buffer.frameLength > 0
            else { continue }

            let generator = SHSignatureGenerator()
            guard (try? generator.append(buffer, at: nil)) != nil,
                  let query = try? generator.signature()
            else { continue }

            guard let matched = await firstMatch(of: query, in: catalog) else { continue }
            // matchOffset: how far into the REFERENCE the query landed.
            let adStartMs = Int(offset * 1000) - Int(matched.offsetSeconds * 1000)
            hits.append((matched.id, max(0, adStartMs)))
        }

        // Merge consecutive hits of the same reference (their computed
        // starts agree within a slice); span = start + reference duration.
        var merged: [Match] = []
        for hit in hits.sorted(by: { $0.startMs < $1.startMs }) {
            let durationMs = durationByID[hit.id] ?? 30_000
            if let last = merged.last, last.referenceID == hit.id,
               abs(last.startMs - hit.startMs) < 15_000 {
                continue
            }
            merged.append(Match(
                referenceID: hit.id,
                startMs: hit.startMs,
                endMs: hit.startMs + durationMs
            ))
        }
        return merged
    }

    // MARK: - ShazamKit plumbing

    static func makeCatalog(_ references: [Reference]) throws -> SHCustomCatalog {
        let catalog = SHCustomCatalog()
        for reference in references {
            let signature = try SHSignature(dataRepresentation: reference.signature)
            let item = SHMediaItem(properties: [.title: reference.id])
            try catalog.addReferenceSignature(signature, representing: [item])
        }
        return catalog
    }

    /// One query against the catalog, delegate wrapped as async.
    static func firstMatch(
        of query: SHSignature, in catalog: SHCustomCatalog
    ) async -> (id: String, offsetSeconds: Double)? {
        let session = SHSession(catalog: catalog)
        let delegate = MatchDelegate()
        session.delegate = delegate
        return await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            session.match(query)
        }
    }

    private final class MatchDelegate: NSObject, SHSessionDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<(id: String, offsetSeconds: Double)?, Never>?

        func session(_ session: SHSession, didFind match: SHMatch) {
            let item = match.mediaItems.first
            continuation?.resume(returning: item.flatMap { matched in
                (matched.title ?? "").isEmpty
                    ? nil
                    : (matched.title ?? "", matched.matchOffset)
            })
            continuation = nil
        }

        func session(
            _ session: SHSession,
            didNotFindMatchFor signature: SHSignature,
            error: Error?
        ) {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}
