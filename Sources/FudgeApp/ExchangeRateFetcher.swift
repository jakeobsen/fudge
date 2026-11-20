import Foundation
import FudgeCore

/// Downloads the European Central Bank's daily reference rates: the one connection fudge makes on its own, and only
/// while currency conversion is turned on. Its session keeps no cookies, credentials or cache.
struct ECBRatesFetcher: RatesFetcher {
    static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    /// The file is about 1.5 KB; anything near this is not it.
    static let byteLimit = 1_000_000

    enum Failure: LocalizedError {
        case status(Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .status(let code): "The ECB answered \(code)"
            case .tooLarge: "The ECB's file was over 1 MB"
            }
        }
    }

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

    func fetchRates() async throws -> Data {
        var request = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        request.setValue("fudge/\(version ?? FudgeVersion.current)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.status(http.statusCode) }
        if response.expectedContentLength > Self.byteLimit { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.byteLimit { throw Failure.tooLarge }
        }
        return data
    }
}

/// Checks every hour whether the rates are due (`ExchangeRatePolicy`: a day old, at most one try per 12 hours), so
/// they're downloaded once a day while fudge runs, also after the Mac wakes from sleep.
@MainActor
final class ExchangeRateSchedule {
    private var timer: Timer?

    func start(_ updater: ExchangeRateUpdater) {
        Task { await updater.updateIfNeeded(now: Date()) }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await updater.updateIfNeeded(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
