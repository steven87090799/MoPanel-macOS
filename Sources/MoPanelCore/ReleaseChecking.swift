// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public let tagName: String
    public let htmlUrl: URL
    public let prerelease: Bool
    public let draft: Bool
    public let publishedAt: String?

    public var isMacStable: Bool {
        !prerelease && !draft && MoleVersion(string: tagName)?.isStable == true &&
        htmlUrl.scheme == "https" && htmlUrl.host == "github.com" &&
        htmlUrl.user == nil && htmlUrl.password == nil && htmlUrl.port == nil &&
        htmlUrl.query == nil && htmlUrl.fragment == nil &&
        htmlUrl.path == "/tw93/Mole/releases/tag/" + tagName
    }
}

public enum ReleaseCheckFailure: Error, Equatable, Sendable {
    case offline, timedOut, rateLimited, server(Int), invalidResponse, noStableRelease, cancelled, connection

    public init(error: Error) {
        if let failure = error as? Self { self = failure }
        else if error is CancellationError { self = .cancelled }
        else if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: self = .offline
            case .timedOut: self = .timedOut
            case .cancelled: self = .cancelled
            default: self = .connection
            }
        } else { self = .invalidResponse }
    }
}

/// Checking never installs anything. A completed check remains visible even if
/// the release tag is identical to the one from the previous request.
public struct ReleaseCheckState: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case updateAvailable, upToDate, localNewer, differentChannel, notInstalled }
    public private(set) var isChecking = false
    public private(set) var release: ReleaseInfo?
    public private(set) var checkedAt: Date?
    public private(set) var failure: ReleaseCheckFailure?
    public init() {}

    @discardableResult public mutating func begin() -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        failure = nil
        return true
    }

    public mutating func complete(_ release: ReleaseInfo, at date: Date = Date()) {
        guard isChecking else { return }
        guard release.isMacStable else { fail(.invalidResponse); return }
        self.release = release
        checkedAt = date
        isChecking = false
        failure = nil
    }

    public mutating func fail(_ failure: ReleaseCheckFailure) {
        guard isChecking else { return }
        self.failure = failure
        isChecking = false
    }

    public func outcome(installed: String?) -> Outcome? {
        guard !isChecking, failure == nil, let release, let latest = MoleVersion(string: release.tagName) else { return nil }
        guard let installed else { return .notInstalled }
        guard let current = MoleVersion(string: installed), current.isStable else { return .differentChannel }
        if current < latest { return .updateAvailable }
        if latest < current { return .localNewer }
        return .upToDate
    }
}

public enum OfficialReleaseClient {
    public static func decode(_ data: Data, statusCode: Int) throws -> [ReleaseInfo] {
        if statusCode == 403 || statusCode == 429 { throw ReleaseCheckFailure.rateLimited }
        guard statusCode == 200 else { throw ReleaseCheckFailure.server(statusCode) }
        guard data.count < 2 * 1024 * 1024 else { throw ReleaseCheckFailure.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
                return try decoder.decode([ReleaseInfo].self, from: data)
            }
            return [try decoder.decode(ReleaseInfo.self, from: data)]
        } catch { throw ReleaseCheckFailure.invalidResponse }
    }

    public static func latestRelease() async throws -> ReleaseInfo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func fetch(_ suffix: String) async throws -> [ReleaseInfo] {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/tw93/Mole/releases" + suffix)!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MoPanel/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReleaseCheckFailure.invalidResponse }
            return try decode(data, statusCode: http.statusCode)
        }
        do {
            if let latest = try await fetch("/latest").first(where: \.isMacStable) { return latest }
        } catch ReleaseCheckFailure.server(404) {
            // GitHub may not have a latest pointer while stable tags still exist.
        }
        // The repository also publishes Windows and prerelease tags.
        guard let release = try await fetch("?per_page=30").first(where: \.isMacStable) else {
            throw ReleaseCheckFailure.noStableRelease
        }
        return release
    }
}
