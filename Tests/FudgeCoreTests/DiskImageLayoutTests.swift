import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import FudgeCore

// The disk image's Finder window (SPEC-150). The `.DS_Store` is read back by `StoreReader` below, written from the
// file format's description (a buddy allocator holding a B-tree of records) rather than from the writer, so a mistake
// in `DSStore.file` shows up as a file this reader can't read, or reads differently.

/// A `.DS_Store` reader that shares no code with `DSStore`: it follows the allocator's header to its own block, finds
/// the B-tree by name in the table of contents, and walks the tree, leaves and internal nodes alike.
private struct StoreReader {
    struct Block {
        let offset: Int
        let size: Int
    }

    let bytes: [UInt8]
    var blocks: [Block] = []
    var table: [String: Int] = [:]
    var free: [[Int]] = []
    var records: [(name: String, code: String, type: String, value: [UInt8])] = []

    enum Problem: Error { case malformed(String) }

    init(_ data: Data) throws {
        bytes = Array(data)
        guard u32(0) == 1, ascii(4, 4) == "Bud1" else { throw Problem.malformed("not a buddy allocator file") }
        // Offsets in the allocator count from byte 4 of the file.
        let root = Int(u32(8))
        let rootSize = Int(u32(12))
        guard u32(16) == UInt32(root), 4 + root + rootSize <= bytes.count else {
            throw Problem.malformed("the allocator's own block")
        }
        var at = 4 + root
        let count = Int(u32(at))
        at += 8
        for index in 0..<count {
            let address = Int(u32(at + 4 * index))
            blocks.append(Block(offset: address & ~0x1f, size: 1 << (address & 0x1f)))
        }
        at += 4 * ((count + 255) / 256 * 256)
        let entries = Int(u32(at))
        at += 4
        for _ in 0..<entries {
            let length = Int(bytes[at])
            table[ascii(at + 1, length)] = Int(u32(at + 1 + length))
            at += 5 + length
        }
        for _ in 0..<32 {
            let count = Int(u32(at))
            free.append((0..<count).map { Int(u32(at + 4 + 4 * $0)) })
            at += 4 + 4 * count
        }
        guard let tree = table["DSDB"], tree < blocks.count else { throw Problem.malformed("no DSDB") }
        let header = 4 + blocks[tree].offset
        let rootNode = Int(u32(header))
        try walk(node: rootNode)
        guard records.count == Int(u32(header + 8)) else { throw Problem.malformed("the record count") }
    }

    func u32(_ at: Int) -> UInt32 { bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func ascii(_ at: Int, _ count: Int) -> String { String(decoding: bytes[at..<at + count], as: UTF8.self) }

    mutating func walk(node: Int) throws {
        guard node < blocks.count else { throw Problem.malformed("node \(node)") }
        var at = 4 + blocks[node].offset
        let next = Int(u32(at))
        let count = Int(u32(at + 4))
        at += 8
        for _ in 0..<count {
            if next != 0 {
                try walk(node: Int(u32(at)))
                at += 4
            }
            let length = Int(u32(at))
            let units = (0..<length).map { UInt16(bytes[at + 4 + 2 * $0]) << 8 | UInt16(bytes[at + 5 + 2 * $0]) }
            at += 4 + 2 * length
            let code = ascii(at, 4)
            let type = ascii(at + 4, 4)
            at += 8
            let value: [UInt8]
            switch type {
            case "long", "shor", "type":
                value = Array(bytes[at..<at + 4])
                at += 4
            case "blob":
                let size = Int(u32(at))
                value = Array(bytes[at + 4..<at + 4 + size])
                at += 4 + size
            default:
                throw Problem.malformed("type \(type)")
            }
            records.append((String(decoding: units, as: UTF16.self), code, type, value))
        }
        if next != 0 { try walk(node: next) }
    }

    func record(_ name: String, _ code: String) -> [UInt8]? {
        records.first { $0.name == name && $0.code == code }?.value
    }

    func plist(_ name: String, _ code: String) -> [String: Any]? {
        record(name, code).flatMap {
            try? PropertyListSerialization.propertyList(from: Data($0), format: nil) as? [String: Any]
        }
    }

    /// An icon's place, the first two of `Iloc`'s four numbers.
    func place(of name: String) -> [UInt32]? {
        record(name, "Iloc").map { value in
            (0..<2).map { index in value[4 * index..<4 * index + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        }
    }
}

/// An alias of a made-up file, so the window's records can be read without a disk image.
private let madeUpAlias = AliasRecord(
    volumeName: "Fudge", volumeCreated: Date(timeIntervalSince1970: 1_795_000_000),
    path: [".background", "background.tiff"], folderIDs: [18], fileID: 19,
    fileCreated: Date(timeIntervalSince1970: 1_795_000_100))

// MARK: - The window

@Test func theWindowReadsBackAsTheSpecSays() throws {
    let store = try StoreReader(try DiskImageLayout.dsStore(backgroundAlias: madeUpAlias.bytes))
    let window = try #require(store.plist(".", "bwsp"))
    // The frame, title bar included, its bottom left corner 200 by 300 points from the screen's.
    #expect(window["WindowBounds"] as? String == "{{200, 300}, {600, 432}}")
    for bar in ["ShowToolbar", "ShowSidebar", "ContainerShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"] {
        #expect(window[bar] as? Bool == false, "\(bar)")
    }
    let view = try #require(store.plist(".", "icvp"))
    #expect(view["iconSize"] as? Double == 128)
    #expect(view["arrangeBy"] as? String == "none")
    #expect(view["labelOnBottom"] as? Bool == true)
    #expect(view["backgroundType"] as? Int == 2)
    #expect(view["backgroundImageAlias"] as? Data == madeUpAlias.bytes)
    #expect(store.record(".", "vstl").map { String(decoding: $0, as: UTF8.self) } == "icnv")
    #expect(store.place(of: "Fudge.app") == [150, 190])
    #expect(store.place(of: "Applications") == [450, 190])
    // Exactly these records, and no bookmark (`pBBk`), which would name the Mac the image was made on.
    #expect(
        store.records.map { "\($0.name)/\($0.code)" } == [
            "./bwsp", "./icvp", "./vSrn", "./vstl", "Applications/Iloc", "Fudge.app/Iloc",
        ])
}

@Test func theFilesBlocksAreWhereTheAllocatorSays() throws {
    let data = try DiskImageLayout.dsStore(backgroundAlias: madeUpAlias.bytes)
    let store = try StoreReader(data)
    // Every block is aligned to its size, inside the file, and apart from the header, the others and the free ones.
    var taken: [Range<Int>] = [0..<32]
    for block in store.blocks {
        #expect(block.offset % block.size == 0)
        #expect(4 + block.offset + block.size <= data.count)
        taken.append(block.offset..<block.offset + block.size)
    }
    for (power, offsets) in store.free.enumerated() {
        for offset in offsets {
            #expect(offset % (1 << power) == 0)
            taken.append(offset..<offset + (1 << power))
        }
    }
    taken.sort { $0.lowerBound < $1.lowerBound }
    // Together they cover the allocator's whole space, 2^31 bytes, once.
    #expect(taken.first?.lowerBound == 0)
    #expect(taken.last?.upperBound == 1 << 31)
    for (left, right) in zip(taken, taken.dropFirst()) { #expect(left.upperBound == right.lowerBound) }
}

@Test func recordsAreSortedAsFinderKeepsThem() throws {
    let records: [DSStore.Record] = [
        .init(name: "b", code: "Iloc", value: .long(1)), .init(name: "A", code: "Iloc", value: .long(2)),
        .init(name: ".", code: "vstl", value: .type("icnv")), .init(name: ".", code: "bwsp", value: .blob(Data())),
    ]
    let store = try StoreReader(try DSStore.file(records))
    #expect(store.records.map { "\($0.name)/\($0.code)" } == ["./bwsp", "./vstl", "A/Iloc", "b/Iloc"])
}

@Test func codesMustBeFourCharactersAndTheRecordsMustFit() {
    #expect(throws: DSStore.Problem.badCode("Ilo")) {
        try DSStore.file([.init(name: ".", code: "Ilo", value: .long(1))])
    }
    #expect(throws: DSStore.Problem.badCode("ic")) {
        try DSStore.file([.init(name: ".", code: "vstl", value: .type("ic"))])
    }
    // The node's 8-byte header, then the record: 4 + 2 for the name, 4 and 4 for the code and type, 4 + 5,000 bytes.
    #expect(throws: DSStore.Problem.tooBig(5_026)) {
        try DSStore.file([.init(name: ".", code: "icvp", value: .blob(Data(count: 5_000)))])
    }
}

// MARK: - The alias record

@Test func theAliasHoldsOnlyTheVolumeAndThePathOnIt() {
    let bytes = madeUpAlias.bytes
    #expect(bytes.count == Int(bytes[4]) << 8 | Int(bytes[5]))
    #expect(bytes[6..<8] == Data([0, 2]))  // version 2
    #expect(bytes[10] == 5)  // "Fudge", a Pascal string
    #expect(bytes[11..<16] == Data("Fudge".utf8))
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(text.contains("Fudge:.background:background.tiff"))
    #expect(text.contains("/.background/background.tiff"))
    #expect(text.contains("/Volumes/Fudge"))
    // The last tagged item is the end: 0xffff with no length.
    #expect(bytes.suffix(4) == Data([0xff, 0xff, 0, 0]))
}

@Test func longNamesAreCutBetweenCharacters() {
    // 27 bytes is a volume name's limit; "é" is two, so the cut can't fall inside it.
    let name = String(repeating: "a", count: 26) + "é"
    let pascal = AliasRecord.pascal(name, size: 28)
    #expect(pascal.count == 28)
    #expect(pascal[0] == 26)
    #expect(AliasRecord.pascal("a:b", size: 28)[1..<4] == Data("a/b".utf8))
}

@Test func onlyAVolumesRootCanBeLaidOut() throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: DiskImageLayout.Problem.notAVolume(folder.path)) {
        try DiskImageLayout.write(toVolume: folder)
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".DS_Store").path))
}

/// Runs a tool, on a thread of its own, and says whether it exited 0.
private func run(_ tool: String, _ arguments: [String]) async throws -> Bool {
    try await OffThePool.run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// A real, writable HFS+ image, mounted out of sight (`-nobrowse -noautoopen`) in a temporary folder, laid out, and
/// read: the `.DS_Store` names nothing outside the volume, neither the folder it's mounted in nor this Mac.
@Test func aScratchImagesLayoutNamesNothingOutsideIt() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("scratch.dmg")
    let mount = folder.appendingPathComponent("mount-point-of-the-test")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let hdiutil = "/usr/bin/hdiutil"
    try #require(
        await run(hdiutil, ["create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "Fudge", image.path]))
    try #require(
        await run(
            hdiutil,
            ["attach", "-quiet", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount.path, image.path]))
    var detached = false
    defer {
        if !detached {
            // A test that failed early still leaves nothing mounted.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hdiutil)
            process.arguments = ["detach", "-force", "-quiet", mount.path]
            try? process.run()
            process.waitUntilExit()
        }
    }
    let pictures = mount.appendingPathComponent(DiskImageLayout.backgroundFolder)
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    try DiskImageBackground.tiff().write(to: pictures.appendingPathComponent(DiskImageLayout.backgroundFile))

    try DiskImageLayout.write(toVolume: mount)

    let data = try Data(contentsOf: mount.appendingPathComponent(".DS_Store"))
    let alias = try AliasRecord.forFile(
        at: pictures.appendingPathComponent(DiskImageLayout.backgroundFile))
    detached = try await run(hdiutil, ["detach", "-quiet", mount.path])
    #expect(detached)

    #expect(alias.volumeName == "Fudge")
    #expect(alias.path == [".background", "background.tiff"])
    #expect(alias.folderIDs.count == 1)
    let store = try StoreReader(data)
    #expect(store.plist(".", "icvp")?["backgroundImageAlias"] as? Data == alias.bytes)
    #expect(store.record(".", "pBBk") == nil)
    // Byte by byte, as UTF-8 and as UTF-16, as `strings` would look.
    let text = String(decoding: data, as: UTF8.self)
    let wide = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    let folderName = folder.lastPathComponent
    for outside in ["/Users/", "/private/", "/var/", "mount-point-of-the-test", folderName, "book", NSUserName()] {
        #expect(!text.contains(outside), "\(outside)")
        #expect(!wide.contains(outside), "\(outside)")
    }
}

// MARK: - The picture

@Test func thePictureIsLightWithAnArrowBetweenTheIcons() throws {
    let image = try #require(DiskImageBackground.image(scale: 2))
    #expect(image.width == 1200 && image.height == 864)
    #expect(image.alphaInfo == .noneSkipLast)
    let pixels = try rgb(of: image)
    let fill = [0.96, 0.96, 0.97].map { UInt8(($0 * 255).rounded()) }
    let arrow = [0.56, 0.56, 0.58].map { UInt8(($0 * 255).rounded()) }
    // The corners and the icons' centres are plain; the middle of the arrow's shaft is the arrow.
    for point in [(0, 0), (1199, 863), (300, 380), (900, 380)] { #expect(pixels(point) == fill, "\(point)") }
    #expect(pixels((600, 380)) == arrow)
    // Above and below the shaft, away from the head, it's plain again.
    #expect(pixels((560, 340)) == fill)
    #expect(pixels((560, 420)) == fill)
}

/// The committed `App/DiskImage/background.tiff` is today's drawing: 1x at 72 dpi and 2x at 144, with the same
/// colours in the same places.
@Test func theCommittedPictureIsTheDrawing() throws {
    let file = Fixtures.repository.appendingPathComponent("App/DiskImage/background.tiff")
    let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == 2)
    for (index, scale) in [1, 2].enumerated() {
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == Double(72 * scale))
        let committed = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        let drawn = try #require(DiskImageBackground.image(scale: scale))
        #expect(committed.width == drawn.width && committed.height == drawn.height)
        let left = try rgb(of: committed)
        let right = try rgb(of: drawn)
        let points = [(0, 0), (150, 190), (250, 190), (300, 190), (450, 190), (300, 250), (599, 431)]
        for point in points.map({ ($0.0 * scale, $0.1 * scale) }) {
            #expect(left(point) == right(point), "\(point) at \(scale)x")
        }
    }
}

private struct NoPixels: Error {}

/// A way to read an image's pixels as sRGB bytes.
private func rgb(of image: CGImage) throws -> ((Int, Int)) -> [UInt8] {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw NoPixels() }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = buffer
    // Rows come top first.
    return { point in
        let start = (point.1 * width + point.0) * 4
        return Array(pixels[start..<start + 3])
    }
}
