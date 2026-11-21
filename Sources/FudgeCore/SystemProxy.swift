import Foundation

/// The Mac's proxy, for the Extension Store's npm and git (SPEC-116 §3). An app opened from Finder or at login has no
/// `HTTPS_PROXY`, so the proxy set in System Settings → Network (`CFNetworkCopySystemProxySettings`, read by the app)
/// goes to the extension host as `FUDGE_SYSTEM_PROXY`, and the store passes it on to its own npm and git only where
/// no proxy variable is set already. A proxy auto-configuration file isn't resolved, only noted, so a failure's cause
/// line can say so. Credentials are never read: the settings don't hold the password, and no user name goes into a
/// URL.
public struct SystemProxy: Equatable, Sendable, Codable {
    /// `http://<host>:<port>` for HTTPS requests (an HTTPS proxy is reached over HTTP and tunnels with CONNECT).
    public var https: String?
    /// `http://<host>:<port>` for plain HTTP requests.
    public var http: String?
    /// The bypass list as `NO_PROXY` writes it: `*.example.com` becomes `.example.com`.
    public var noProxy: String?
    /// A PAC file or automatic proxy discovery is on, which npm and git can't use.
    public var autoConfig: Bool

    public static let environmentKey = "FUDGE_SYSTEM_PROXY"

    public init(https: String? = nil, http: String? = nil, noProxy: String? = nil, autoConfig: Bool = false) {
        self.https = https
        self.http = http
        self.noProxy = noProxy
        self.autoConfig = autoConfig
    }

    /// Reads `CFNetworkCopySystemProxySettings`' dictionary, by its keys' string values, taking only what's well
    /// formed: a host of letters, digits, `.`, `-` (or an IPv6 address) and a port from 1 to 65535.
    public init(settings: [String: Any]) {
        func enabled(_ key: String) -> Bool { (settings[key] as? NSNumber)?.boolValue == true }
        func proxy(_ prefix: String) -> String? {
            guard enabled("\(prefix)Enable"), let host = settings["\(prefix)Proxy"] as? String,
                let port = (settings["\(prefix)Port"] as? NSNumber)?.intValue, (1...65535).contains(port)
            else { return nil }
            return Self.url(host: host, port: port)
        }
        let exceptions = (settings["ExceptionsList"] as? [String] ?? []).compactMap(Self.bypass)
        self.init(
            https: proxy("HTTPS"), http: proxy("HTTP"),
            noProxy: exceptions.isEmpty ? nil : exceptions.joined(separator: ","),
            autoConfig: enabled("ProxyAutoConfigEnable") || enabled("ProxyAutoDiscoveryEnable"))
    }

    /// What the host gets: JSON, or nil when there's nothing to say.
    public var environmentValue: String? {
        guard https != nil || http != nil || autoConfig else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func url(host: String, port: Int) -> String? {
        let host = host.trimmingCharacters(in: .whitespaces)
        if host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }), !host.isEmpty, !host.hasPrefix("-") {
            return "http://\(host):\(port)"
        }
        if host.contains(":"), host.unicodeScalars.allSatisfy({ ipv6Characters.contains($0) }) {
            return "http://[\(host)]:\(port)"
        }
        return nil
    }

    /// One bypass entry as `NO_PROXY` reads it, or nil for one it can't express (macOS's `169.254/16`).
    static func bypass(_ entry: String) -> String? {
        var entry = entry.trimmingCharacters(in: .whitespaces)
        if entry.hasPrefix("*.") { entry.removeFirst() }
        guard !entry.isEmpty, entry.unicodeScalars.allSatisfy({ hostCharacters.contains($0) || $0 == ":" }) else {
            return nil
        }
        return entry
    }

    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
}
