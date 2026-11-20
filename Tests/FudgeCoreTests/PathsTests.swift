import Foundation
import Testing

@testable import FudgeCore

@Test func supportDirectoryDefaultsToApplicationSupport() {
    let paths = FudgePaths.standard(environment: [:])
    #expect(paths.supportDirectory.path.hasSuffix("/Library/Application Support/fudge"))
}

@Test func supportDirectoryCanBeOverridden() {
    let paths = FudgePaths.standard(environment: ["FUDGE_SUPPORT_DIR": "/tmp/fudge-test"])
    #expect(paths.supportDirectory.path == "/tmp/fudge-test")
    #expect(paths.extensionsDirectory.path == "/tmp/fudge-test/extensions")
}

@Test func emptyOverrideIsIgnored() {
    #expect(FudgePaths.standard(environment: ["FUDGE_SUPPORT_DIR": ""]) == FudgePaths.standard(environment: [:]))
}
