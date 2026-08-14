import Foundation

/// The narrow slice of HTTP this module needs, kept behind a protocol purely so
/// tests can run offline and deterministically.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.notHTTP
        }
        return (data, http)
    }
}

public enum HTTPError: Error, Sendable, Equatable {
    case notHTTP
    case status(Int)
    /// The directory asked us to slow down (§8.1).
    case rateLimited(retryAfter: TimeInterval?)
}

/// Validators for a conditional GET, so an unchanged feed costs one round trip
/// and no body (§8.2).
public struct HTTPCacheValidators: Hashable, Sendable, Codable {
    public var etag: String?
    public var lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }

    public var isEmpty: Bool { etag == nil && lastModified == nil }
}

extension URLRequest {
    mutating func applyConditionalHeaders(_ validators: HTTPCacheValidators?) {
        guard let validators else { return }
        if let etag = validators.etag {
            setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
    }
}

extension HTTPURLResponse {
    var cacheValidators: HTTPCacheValidators {
        HTTPCacheValidators(
            etag: value(forHTTPHeaderField: "ETag"),
            lastModified: value(forHTTPHeaderField: "Last-Modified")
        )
    }
}
