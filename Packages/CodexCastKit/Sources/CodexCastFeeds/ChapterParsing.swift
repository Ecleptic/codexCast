import CodexCastCore
import Foundation

/// Parses the Podcasting 2.0 JSON chapters format.
public enum ChapterParser {
    private struct Document: Decodable {
        struct Entry: Decodable {
            let startTime: Double
            let title: String?
            let img: String?
            let url: String?
            /// Chapters marked `toc: false` are not navigation points.
            let toc: Bool?
        }
        let chapters: [Entry]
    }

    public static func parse(_ data: Data) throws -> [Chapter] {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw ChapterParseError.malformed(error.localizedDescription)
        }

        let chapters = document.chapters.compactMap { entry -> Chapter? in
            guard entry.toc != false else { return nil }
            let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            return Chapter(
                startMs: Int(entry.startTime * 1000),
                title: title,
                source: .feed,
                imageURL: entry.img.flatMap(sanitizedURL),
                url: entry.url.flatMap(sanitizedURL)
            )
        }

        // Chapter files arrive out of order in the wild — LINUX Unplugged ships
        // episodes whose list runs from "Outro" at 0s to "Intro" at the end.
        // Sorting here means no caller has to remember to.
        return chapters.sortedByStart()
    }
}

public enum ChapterParseError: Error, Sendable, Equatable {
    case malformed(String)
}
