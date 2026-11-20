import Darwin
import Foundation

/// Which image URLs fudge fetches for extensions: https only, with no user info, and never a host on this Mac or
/// the local network, so third-party markdown can't make fudge probe the LAN.
public enum RemoteImageURL {
    public enum Refusal: Error, Equatable, Sendable {
        /// `http://` or another scheme.
        case notHTTPS
        /// `https://user:pass@host/…`.
        case userInfo
        /// localhost, a `.local` name, a one-label name, or an IP address that isn't public.
        case localNetwork
        /// No host, or one that can't be read.
        case invalid
    }

    /// Whether an image source is a URL (`https://…`, `http://…`, `ftp://…`) rather than a file, an asset, an icon or
    /// an emoji. `file://` sources are files.
    public static func isURL(_ source: String) -> Bool {
        guard let colon = source.range(of: "://") else { return false }
        let scheme = source[..<colon.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return false }
        return scheme.lowercased() != "file"
    }

    /// Why `url` isn't fetched, or nil when it may be.
    public static func check(_ url: URL) -> Refusal? {
        guard url.scheme?.lowercased() == "https" else { return .notHTTPS }
        guard url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else {
            return .userInfo
        }
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return .invalid }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") {
            // An IPv6 literal, maybe with a zone ("fe80::1%en0").
            let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            guard let bytes = ipv6(address) else { return .invalid }
            return isPublic(ipv6: bytes) ? nil : .localNetwork
        }
        // Every form getaddrinfo reads as IPv4: 127.0.0.1, 127.1, 2130706433, 0x7f000001, 0177.0.0.1.
        if let address = ipv4(host) {
            return isPublic(ipv4: address) ? nil : .localNetwork
        }
        return isPublic(name: host) ? nil : .localNetwork
    }

    private static func ipv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// Refuses this network, private, shared (CGNAT), loopback and link-local addresses, and everything from
    /// multicast up.
    static func isPublic(ipv4 address: UInt32) -> Bool {
        let ranges: [(UInt32, Int)] = [
            (0x0000_0000, 8),  // 0.0.0.0/8
            (0x0A00_0000, 8),  // 10.0.0.0/8
            (0x6440_0000, 10),  // 100.64.0.0/10
            (0x7F00_0000, 8),  // 127.0.0.0/8
            (0xA9FE_0000, 16),  // 169.254.0.0/16
            (0xAC10_0000, 12),  // 172.16.0.0/12
            (0xC0A8_0000, 16),  // 192.168.0.0/16
            (0xE000_0000, 3),  // 224.0.0.0 and up
        ]
        return !ranges.contains { base, bits in address >> (32 - bits) == base >> (32 - bits) }
    }

    /// Refuses ::, ::1, link-local, site-local, unique-local (fc00::/7) and multicast addresses, and checks the IPv4
    /// address inside mapped (::ffff:a.b.c.d), compatible (::a.b.c.d), NAT64 (64:ff9b::) and 6to4 (2002::) ones.
    static func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        func v4(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let zeroPrefix = bytes[0..<10].allSatisfy { $0 == 0 }
        if zeroPrefix, bytes[10] == 0xFF, bytes[11] == 0xFF { return isPublic(ipv4: v4(12)) }
        if zeroPrefix, bytes[10] == 0, bytes[11] == 0 { return isPublic(ipv4: v4(12)) }
        if bytes[0..<4] == [0x00, 0x64, 0xFF, 0x9B], bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublic(ipv4: v4(12))
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return isPublic(ipv4: v4(2)) }
        if bytes[0] == 0xFE, bytes[1] & 0x80 == 0x80 { return false }  // fe80::/10 and fec0::/10
        if bytes[0] & 0xFE == 0xFC { return false }  // fc00::/7
        if bytes[0] == 0xFF { return false }  // multicast
        return true
    }

    /// Refuses localhost, one-label names (which the resolver's search domains can turn into a LAN host) and the
    /// names set aside for local networks.
    static func isPublic(name: String) -> Bool {
        guard name.contains(".") else { return false }
        let local = ["localhost", "local", "home.arpa", "internal", "lan"]
        return !local.contains { name == $0 || name.hasSuffix("." + $0) }
    }
}

/// Raycast's query parameters on a markdown image: `raycast-width`, `raycast-height` (points) and
/// `raycast-tint-color`. The URL is still fetched as written.
public struct MarkdownImageHints: Equatable, Sendable {
    public var width: Double?
    public var height: Double?
    public var tintColor: String?

    public init(width: Double? = nil, height: Double? = nil, tintColor: String? = nil) {
        self.width = width
        self.height = height
        self.tintColor = tintColor
    }

    public init(source: String) {
        self.init()
        guard let query = source.split(separator: "?", maxSplits: 1).dropFirst().first else { return }
        for pair in query.split(separator: "#", maxSplits: 1)[0].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "raycast-width": width = Double(parts[1]).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            case "raycast-height": height = Double(parts[1]).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            case "raycast-tint-color": tintColor = parts[1].isEmpty ? nil : parts[1]
            default: break
            }
        }
    }

    /// The size to draw an image whose own size is `natural`: both hints as given, or one of them with the other
    /// side scaled to keep the image's proportions. Nil when there's no size hint.
    /// `displaySize`, scaled down (never up) to fit `bounds`, keeping its proportions, so a hint can't make an
    /// image wider than the pane it's in.
    public func displaySize(natural: CGSize, fitting bounds: CGSize) -> CGSize? {
        guard let size = displaySize(natural: natural), size.width > 0, size.height > 0 else {
            return displaySize(natural: natural)
        }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    public func displaySize(natural: CGSize) -> CGSize? {
        switch (width, height) {
        case (let width?, let height?):
            return CGSize(width: width, height: height)
        case (let width?, nil):
            guard natural.width > 0 else { return nil }
            return CGSize(width: width, height: natural.height * width / natural.width)
        case (nil, let height?):
            guard natural.height > 0 else { return nil }
            return CGSize(width: natural.width * height / natural.height, height: height)
        case (nil, nil):
            return nil
        }
    }
}
