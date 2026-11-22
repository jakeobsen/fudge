// swift-tools-version: 6.0
import PackageDescription

// The app product is `FudgeApp`, not `Fudge`: macOS file systems are case-insensitive,
// and `Fudge` would collide with the `fudge` command-line tool in the build folder.
let package = Package(
    name: "fudge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FudgeApp", targets: ["FudgeApp"]),
        .executable(name: "fudge", targets: ["FudgeCLI"]),
        .executable(name: "FudgeLinks", targets: ["FudgeLinks"]),
    ],
    targets: [
        .target(name: "FudgeCore"),
        .executableTarget(name: "FudgeApp", dependencies: ["FudgeCore"]),
        .executableTarget(name: "FudgeCLI", dependencies: ["FudgeCore"]),
        .executableTarget(name: "FudgeLinks", dependencies: ["FudgeCore"]),
        .testTarget(name: "FudgeCoreTests", dependencies: ["FudgeCore"], exclude: ["Fixtures"]),
    ]
)
