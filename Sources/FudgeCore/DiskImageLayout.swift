import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Finder window of Fudge's disk image (SPEC-150): `Fudge.app` on the left, `Applications` on the right, a
/// picture with an arrow behind them, in icon view with no toolbar, sidebar or status bar.
///
/// Finder reads all of it from the volume's `.DS_Store`, which `make dmg-image` has `FudgeDiskImage` write while the
/// image is still writable, as dmgbuild does, so nothing scripts Finder. The picture is `.background/background.tiff`
/// on the volume, found through an alias record (`AliasRecord`) in the icon view's settings.
public enum DiskImageLayout {
    /// The window's whole frame, title bar included: Finder's `WindowBounds` sets the frame, not the content.
    /// The content is 600 × 400 points under macOS 26's 32-point title bar, and 600 × 404 under the 28-point one before.
    public static let windowSize = CGSize(width: 600, height: 432)
    /// Where the window opens: its frame's bottom left corner, counted from the bottom left of the main screen, as
    /// `WindowBounds` counts. Finder moves a window that wouldn't fit back onto the screen.
    public static let windowOrigin = CGPoint(x: 200, y: 300)
    public static let iconSize = 128
    public static let textSize = 13
    public static let appName = "Fudge.app"
    public static let applicationsName = "Applications"
    /// The icons' centres, from the top left of the window's content.
    public static let appCentre = CGPoint(x: 150, y: 190)
    public static let applicationsCentre = CGPoint(x: 450, y: 190)
    /// The picture's folder and file on the volume; Finder doesn't show names that start with a dot.
    public static let backgroundFolder = ".background"
    public static let backgroundFile = "background.tiff"

    public enum Problem: Error, Equatable {
        /// The folder given isn't the root of a volume, so it isn't a mounted disk image.
        case notAVolume(String)
    }

    /// Writes the volume's `.DS_Store`, for the picture already at `.background/background.tiff` on it.
    public static func write(toVolume volume: URL) throws {
        let values = try volume.resourceValues(forKeys: [.isVolumeKey])
        guard values.isVolume == true else { throw Problem.notAVolume(volume.path) }
        let picture = volume.appendingPathComponent(backgroundFolder).appendingPathComponent(backgroundFile)
        let alias = try AliasRecord.forFile(at: picture)
        try dsStore(backgroundAlias: alias.bytes).write(to: volume.appendingPathComponent(".DS_Store"))
    }

    /// The volume's `.DS_Store`, with `backgroundAlias` (an `AliasRecord`'s bytes) naming the picture.
    ///
    /// It has no `pBBk` record: that bookmark, which Finder writes for itself on a volume it can write to, names the
    /// disk image's own file and the Mac it was made on whenever `URL.bookmarkData` makes it, and the alias does the job.
    public static func dsStore(backgroundAlias: Data) throws -> Data {
        try DSStore.file(records(backgroundAlias: backgroundAlias))
    }

    static func records(backgroundAlias: Data) throws -> [DSStore.Record] {
        let bounds =
            "{{\(Int(windowOrigin.x)), \(Int(windowOrigin.y))}, {\(Int(windowSize.width)), \(Int(windowSize.height))}}"
        let window: [String: Any] = [
            "WindowBounds": bounds,
            "ShowToolbar": false, "ShowSidebar": false, "ContainerShowSidebar": false, "ShowStatusBar": false,
            "ShowPathbar": false, "ShowTabView": false, "PreviewPaneVisibility": false, "SidebarWidth": 180,
        ]
        let fill = DiskImageBackground.fill
        let iconView: [String: Any] = [
            "viewOptionsVersion": 1,
            "backgroundType": 2,  // a picture
            "backgroundImageAlias": backgroundAlias,
            "backgroundColorRed": fill.red, "backgroundColorGreen": fill.green, "backgroundColorBlue": fill.blue,
            "arrangeBy": "none", "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
            "iconSize": Double(iconSize), "textSize": Double(textSize), "labelOnBottom": true,
            "showIconPreview": false, "showItemInfo": false, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        ]
        return [
            .init(name: ".", code: "bwsp", value: .blob(try binaryPlist(window))),
            .init(name: ".", code: "icvp", value: .blob(try binaryPlist(iconView))),
            .init(name: ".", code: "vSrn", value: .long(1)),
            .init(name: ".", code: "vstl", value: .type("icnv")),  // icon view, whatever the Mac's default view is
            .init(name: appName, code: "Iloc", value: .blob(iconLocation(appCentre))),
            .init(name: applicationsName, code: "Iloc", value: .blob(iconLocation(applicationsCentre))),
        ]
    }

    /// An icon's place: its centre, then 0xffffffff and 0xffff0000, as Finder writes it.
    static func iconLocation(_ centre: CGPoint) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(centre.x))
        data.appendBigEndian(UInt32(centre.y))
        data.appendBigEndian(UInt32(0xffff_ffff))
        data.appendBigEndian(UInt32(0xffff_0000))
        return data
    }

    static func binaryPlist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }
}

/// A `.DS_Store` file: Finder's records about a folder (`"."`) and its items, kept in a B-tree inside a buddy
/// allocator. This writes the smallest such file, a tree of one leaf node, which a disk image's few records fit in.
public enum DSStore {
    public enum Value: Equatable, Sendable {
        case long(UInt32)
        case type(String)
        case blob(Data)
    }

    public struct Record: Equatable, Sendable {
        public var name: String
        public var code: String
        public var value: Value

        public init(name: String, code: String, value: Value) {
            self.name = name
            self.code = code
            self.value = value
        }
    }

    public enum Problem: Error, Equatable {
        /// A record's code or a `type` value that isn't four ASCII characters.
        case badCode(String)
        /// Records that don't fit in one node, with the bytes they'd need.
        case tooBig(Int)
    }

    /// The size of the one leaf node, which is also the B-tree's page size.
    static let nodeSize = 4096

    /// The file holding `records`, sorted as Finder keeps them: by name ignoring case, then by code.
    public static func file(_ records: [Record]) throws -> Data {
        let sorted = records.sorted {
            let left = $0.name.lowercased()
            let right = $1.name.lowercased()
            return left != right ? left < right : $0.code < $1.code
        }
        var node = Data()
        node.appendBigEndian(UInt32(0))  // no last child: a leaf
        node.appendBigEndian(UInt32(sorted.count))
        for record in sorted { node.append(try encode(record)) }
        guard node.count <= nodeSize else { throw Problem.tooBig(node.count) }

        // The allocator's space starts at byte 4 of the file, and offsets count from there. It holds its header
        // (32 bytes at 0), the B-tree's header (32 bytes at 32), the allocator's own block (2,048 bytes at 2,048) and
        // the leaf (4,096 bytes at 4,096). A block's address is its offset, with the power of two of its size in the
        // low five bits.
        let rootOffset: UInt32 = 2048
        let addresses: [UInt32] = [rootOffset | 11, 32 | 5, 4096 | 12]
        var root = Data()
        root.appendBigEndian(UInt32(addresses.count))
        root.appendBigEndian(UInt32(0))
        for index in 0..<256 { root.appendBigEndian(index < addresses.count ? addresses[index] : 0) }
        // The table of contents: the B-tree ("DSDB") is block 1.
        root.appendBigEndian(UInt32(1))
        root.append(4)
        root.append(contentsOf: Array("DSDB".utf8))
        root.appendBigEndian(UInt32(1))
        // The free blocks, a list per size: the rest of the first 2,048 bytes, and every block from 8,192 on.
        for power in 0..<32 {
            let free = (6...10).contains(power) || (13...30).contains(power)
            root.appendBigEndian(UInt32(free ? 1 : 0))
            if free { root.appendBigEndian(UInt32(1) << UInt32(power)) }
        }

        var tree = Data()
        tree.appendBigEndian(UInt32(2))  // the root node is block 2, the leaf
        tree.appendBigEndian(UInt32(0))  // with no levels above it
        tree.appendBigEndian(UInt32(sorted.count))
        tree.appendBigEndian(UInt32(1))  // one node in all
        tree.appendBigEndian(UInt32(nodeSize))

        var header = Data("Bud1".utf8)
        header.appendBigEndian(rootOffset)
        header.appendBigEndian(UInt32(root.count))
        header.appendBigEndian(rootOffset)
        header.append(Data(count: 16))

        var space = Data(count: 8192)
        space.replaceSubrange(0..<header.count, with: header)
        space.replaceSubrange(32..<32 + tree.count, with: tree)
        space.replaceSubrange(2048..<2048 + root.count, with: root)
        space.replaceSubrange(4096..<4096 + node.count, with: node)
        var file = Data()
        file.appendBigEndian(UInt32(1))
        file.append(space)
        return file
    }

    static func encode(_ record: Record) throws -> Data {
        try check(record.code)
        var data = Data()
        let name = Array(record.name.utf16)
        data.appendBigEndian(UInt32(name.count))
        for unit in name { data.appendBigEndian(unit) }
        data.append(contentsOf: Array(record.code.utf8))
        switch record.value {
        case .long(let value):
            data.append(contentsOf: Array("long".utf8))
            data.appendBigEndian(value)
        case .type(let type):
            try check(type)
            data.append(contentsOf: Array("type".utf8))
            data.append(contentsOf: Array(type.utf8))
        case .blob(let blob):
            data.append(contentsOf: Array("blob".utf8))
            data.appendBigEndian(UInt32(blob.count))
            data.append(blob)
        }
        return data
    }

    static func check(_ code: String) throws {
        guard code.utf8.count == 4, code.unicodeScalars.allSatisfy(\.isASCII) else { throw Problem.badCode(code) }
    }
}

/// A classic Mac OS alias record, version 2: what Finder resolves to find a folder's background picture.
///
/// It's built here, as mac_alias (dmgbuild's) builds one, rather than by the system, since only facts about the volume
/// and the file go in. An alias from `FSNewAliasFromPath`, like a bookmark from `URL.bookmarkData`, also records the
/// disk image's own file, so a published image would carry the path of the folder it was made in, `/Users/…` and all.
public struct AliasRecord: Equatable, Sendable {
    public var volumeName: String
    public var volumeCreated: Date
    /// The file's path below the volume's root, folders first.
    public var path: [String]
    /// The folders' file ids (CNIDs), in the same order as their names in `path`.
    public var folderIDs: [UInt32]
    public var fileID: UInt32
    public var fileCreated: Date

    public init(
        volumeName: String, volumeCreated: Date, path: [String], folderIDs: [UInt32], fileID: UInt32, fileCreated: Date
    ) {
        self.volumeName = volumeName
        self.volumeCreated = volumeCreated
        self.path = path
        self.folderIDs = folderIDs
        self.fileID = fileID
        self.fileCreated = fileCreated
    }

    public enum Problem: Error, Equatable {
        case unreadable(String)
        case notOnItsVolume(String)
    }

    /// The alias of the file at `url`, read from the file system: its volume, and its path from the volume's root.
    public static func forFile(at url: URL) throws -> AliasRecord {
        let file = url.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [
            .creationDateKey, .volumeURLKey, .volumeNameKey, .volumeCreationDateKey,
        ])
        guard let volume = values.volume?.resolvingSymlinksInPath(), let volumeName = values.volumeName,
            let volumeCreated = values.volumeCreationDate, let fileCreated = values.creationDate
        else { throw Problem.unreadable(file.path) }
        let root = volume.pathComponents
        let components = file.pathComponents
        guard components.count > root.count, Array(components.prefix(root.count)) == root else {
            throw Problem.notOnItsVolume(file.path)
        }
        let path = Array(components.dropFirst(root.count))
        var folder = volume
        var folderIDs: [UInt32] = []
        for name in path.dropLast() {
            folder.appendPathComponent(name)
            folderIDs.append(try fileID(of: folder))
        }
        return AliasRecord(
            volumeName: volumeName, volumeCreated: volumeCreated, path: path, folderIDs: folderIDs,
            fileID: try fileID(of: file), fileCreated: fileCreated)
    }

    /// A file's id, which on HFS+ and APFS is its inode number.
    static func fileID(of url: URL) throws -> UInt32 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Problem.unreadable(url.path) }
        return UInt32(truncatingIfNeeded: info.st_ino)
    }

    /// Seconds from 1 January 1904, the classic Mac OS epoch.
    static func macTime(_ date: Date) -> Double { max(0, date.timeIntervalSince1970 + 2_082_844_800) }

    /// The record: its fixed 150 bytes, then tagged items, each tag's number as mac_alias names it.
    public var bytes: Data {
        let fileName = path.last ?? ""
        let parentName = path.count > 1 ? path[path.count - 2] : volumeName
        let parentID = folderIDs.last ?? 2  // 2 is a volume's root folder
        let volumeTime = Self.macTime(volumeCreated)
        let fileTime = Self.macTime(fileCreated)

        var data = Data(count: 4)  // the creating application's code: none
        data.appendBigEndian(UInt16(0))  // the record's length, filled in at the end
        data.appendBigEndian(UInt16(2))  // version 2
        data.appendBigEndian(UInt16(0))  // a file, not a folder
        data.append(Self.pascal(volumeName, size: 28))
        data.appendBigEndian(UInt32(volumeTime))
        data.append(contentsOf: Array("H+".utf8))
        data.appendBigEndian(UInt16(0))  // a fixed disk
        data.appendBigEndian(parentID)
        data.append(Self.pascal(fileName, size: 64))
        data.appendBigEndian(fileID)
        data.appendBigEndian(UInt32(fileTime))
        data.append(Data(count: 8))  // the file's creator and type codes: none
        data.appendBigEndian(UInt16(0xffff))  // the levels from and to: unknown
        data.appendBigEndian(UInt16(0xffff))
        data.append(Data(count: 16))  // the volume's attributes, its file system id, and ten reserved bytes

        data.append(Self.item(0, Data(Self.carbon(parentName).utf8)))  // the parent folder's name
        var high = Data()
        high.appendBigEndian(UInt64(volumeTime * 65536))
        data.append(Self.item(16, high))  // the volume's creation date, in 1/65,536 seconds
        high = Data()
        high.appendBigEndian(UInt64(fileTime * 65536))
        data.append(Self.item(17, high))  // the file's
        var ids = Data()
        for id in folderIDs { ids.appendBigEndian(id) }
        data.append(Self.item(1, ids))  // the folders' ids
        data.append(Self.item(2, Data(([volumeName] + path).map(Self.carbon).joined(separator: ":").utf8)))
        data.append(Self.item(14, Self.unicode(fileName)))
        data.append(Self.item(15, Self.unicode(volumeName)))
        data.append(Self.item(18, Data(("/" + path.joined(separator: "/")).utf8)))  // the path on the volume
        // Where the volume is mounted when someone opens the image, whatever folder it was in while this was made.
        data.append(Self.item(19, Data(("/Volumes/" + volumeName).utf8)))
        data.appendBigEndian(UInt16(0xffff))  // the end
        data.appendBigEndian(UInt16(0))
        let length = UInt16(data.count)
        data[4] = UInt8(length >> 8)
        data[5] = UInt8(length & 0xff)
        return data
    }

    /// A name as the classic Mac OS wrote it, where `:` separates a path's parts.
    static func carbon(_ name: String) -> String { name.replacingOccurrences(of: ":", with: "/") }

    /// A Pascal string in `size` bytes: its length, then at most `size - 1` bytes of UTF-8, cut between characters.
    static func pascal(_ string: String, size: Int) -> Data {
        var bytes: [UInt8] = []
        for character in carbon(string) {
            let next = Array(String(character).utf8)
            if bytes.count + next.count > size - 1 { break }
            bytes += next
        }
        return Data([UInt8(bytes.count)] + bytes + [UInt8](repeating: 0, count: size - 1 - bytes.count))
    }

    /// A tagged item: its tag, its length, its data, and a zero byte when the length is odd.
    static func item(_ tag: UInt16, _ value: Data) -> Data {
        var data = Data()
        data.appendBigEndian(tag)
        data.appendBigEndian(UInt16(value.count))
        data.append(value)
        if value.count % 2 == 1 { data.append(0) }
        return data
    }

    /// A name in UTF-16, after its length in code units.
    static func unicode(_ name: String) -> Data {
        let units = Array(carbon(name).utf16)
        var data = Data()
        data.appendBigEndian(UInt16(units.count))
        for unit in units { data.appendBigEndian(unit) }
        return data
    }
}

/// The picture behind the disk image's icons: a plain light background, and an arrow from Fudge to Applications.
///
/// Finder draws the names under the icons dark over a background picture, in dark mode too, so a light one reads in
/// both. `App/DiskImage/background.tiff` is this, rendered by `FudgeDiskImage background`.
public enum DiskImageBackground {
    public static let fill = (red: 0.96, green: 0.96, blue: 0.97)
    public static let arrow = (red: 0.56, green: 0.56, blue: 0.58)
    /// Its size in points: the window's whole frame, so it covers the content whatever height the title bar has.
    public static var size: CGSize { DiskImageLayout.windowSize }
    /// The arrow's ends and height, from the top left: from the right of Fudge's icon to the left of Applications', a
    /// margin away from each, level with their centres.
    public static var arrowStart: CGPoint {
        CGPoint(
            x: DiskImageLayout.appCentre.x + CGFloat(DiskImageLayout.iconSize) / 2 + 26, y: DiskImageLayout.appCentre.y)
    }
    public static var arrowEnd: CGPoint {
        CGPoint(
            x: DiskImageLayout.applicationsCentre.x - CGFloat(DiskImageLayout.iconSize) / 2 - 26,
            y: DiskImageLayout.applicationsCentre.y)
    }

    public enum Problem: Error { case drawing }

    /// The picture at 1× or 2×, opaque, in sRGB.
    public static func image(scale: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // CoreGraphics counts from the bottom left.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setStrokeColor(CGColor(srgbRed: arrow.red, green: arrow.green, blue: arrow.blue, alpha: 1))
        context.setLineWidth(6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let start = arrowStart
        let end = arrowEnd
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: CGPoint(x: end.x - 22, y: end.y - 22))
        context.addLine(to: end)
        context.addLine(to: CGPoint(x: end.x - 22, y: end.y + 22))
        context.strokePath()
        return context.makeImage()
    }

    /// The picture as Finder takes it for Retina screens: one TIFF holding the 1× image at 72 dpi and the 2× at 144,
    /// as `tiffutil -cathidpicheck` makes them, compressed with LZW.
    public static func tiff() throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil)
        else { throw Problem.drawing }
        for scale in [1, 2] {
            guard let image = image(scale: scale) else { throw Problem.drawing }
            let dpi = 72 * scale
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],  // LZW
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Problem.drawing }
        return data as Data
    }
}

extension Data {
    /// Appends an integer's bytes, most significant first.
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
