import Foundation
import Testing

@testable import FudgeCore

@Test func eachBundledOnlyCallIsAllowedForItsBundledIdOnly() throws {
    let bundled = [ExtensionStore.id, ClipboardHistory.id, FileSearch.id, BundledExtensions.emojiID]
    let allowed: [BundledCalls.Call: ExtensionID] = [
        .fudgeLog: ExtensionStore.id, .commandLineTools: ExtensionStore.id, .storeNotifications: ExtensionStore.id,
        .clipboardHistory: ClipboardHistory.id, .filesSearch: FileSearch.id,
    ]
    #expect(Set(allowed.keys) == Set(BundledCalls.Call.allCases))
    // The same names from another repository, or built in the development folder, are other extensions.
    let lookalikes = try [
        "someone+tools+fudge-extension-store", "someone+tools+fudge-clipboard-history",
        "someone+tools+fudge-file-search",
        "fudgeapp+development+fudge-extension-store", "fudgeapp+development+fudge-clipboard-history",
        "fudgeapp+development+fudge-file-search", "github",
    ].map { try #require(ExtensionID(stored: $0)) }
    for call in BundledCalls.Call.allCases {
        let caller = try #require(allowed[call])
        #expect(BundledCalls.mayCall(call, from: caller), "\(call)")
        for other in bundled where other != caller { #expect(!BundledCalls.mayCall(call, from: other), "\(call)") }
        for other in lookalikes { #expect(!BundledCalls.mayCall(call, from: other), "\(call) from \(other)") }
        #expect(!BundledCalls.mayCall(call, from: nil), "\(call)")
    }
}
