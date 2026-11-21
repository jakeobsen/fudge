import Foundation
import FudgeCore

/// Asks GitHub for Fudge's newest release: one GET of `releases/latest` with `User-Agent` and `Accept`. Its session
/// keeps no cookies, credentials or cache, gives up after 15 s, and reads at most 1 MB. It never downloads the
/// release itself. URLSession adds `Host`, `Connection` and `Accept-Encoding`; `Accept-Language` is set to "en",
/// since URLSession would otherwise fill in the Mac's languages.
struct GitHubReleaseFetcher: ReleaseFetcher {
    let userAgent = UpdateCheck.userAgent(version: FudgeVersion.current)

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    func fetchLatestRelease() async throws -> Data? {
        var request = URLRequest(
            url: UpdateCheck.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckFailure.notARelease }
        // GitHub answers 404 while the repository has no release.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateCheckFailure.status(http.statusCode) }
        return try await UpdateCheck.readBody(bytes, expectedLength: response.expectedContentLength)
    }
}

/// A snapshot run's fetcher: it never asks GitHub, so Check Now there fails.
struct SnapshotReleaseFetcher: ReleaseFetcher {
    struct NotInSnapshots: LocalizedError {
        var errorDescription: String? { "Snapshots don't check for updates" }
    }

    func fetchLatestRelease() async throws -> Data? {
        throw NotInSnapshots()
    }
}

/// Asks the checker at launch and every hour whether a check is due (`UpdateCheckPolicy`): the chosen interval has
/// passed since the last success, or a failure is waiting to be tried again. Also after the Mac wakes from sleep.
@MainActor
final class UpdateCheckSchedule {
    private var timer: Timer?

    func start(_ checker: UpdateChecker) {
        Task { await checker.checkIfDue(now: Date()) }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await checker.checkIfDue(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
