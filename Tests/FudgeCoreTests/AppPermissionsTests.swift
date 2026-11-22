import Foundation
import Testing

// SPEC-151 (FUD-159): the hardened runtime refuses a protected resource without its entitlement, and macOS asks the
// user with the app's usage description. Fudge starts extensions' processes, so their requests count as Fudge's.
// These pin both files, so an entitlement or a text can't be dropped or reworded by accident.

/// The repository's `App/…` property list at `path`.
private func appFile(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(path)
    return try #require(
        PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

@Test func fudgeHasExactlyTheEntitlementsFudgeAndItsExtensionsUse() throws {
    let entitlements = try appFile("App/Fudge.entitlements")
    #expect(
        Set(entitlements.keys) == [
            "com.apple.security.automation.apple-events",
            "com.apple.security.personal-information.calendars",
            "com.apple.security.personal-information.addressbook",
            "com.apple.security.personal-information.location",
            "com.apple.security.personal-information.photos-library",
            "com.apple.security.device.camera",
            "com.apple.security.device.audio-input",
        ])
    for (key, value) in entitlements {
        #expect(value as? Bool == true, "\(key) is true")
    }
}

@Test func macOSAsksWithExactlyTheseTexts() throws {
    let info = try appFile("App/Info.plist")
    let texts = info.filter { $0.key.hasSuffix("UsageDescription") }.mapValues { $0 as? String }
    let expected: [String: String] = [
        "NSAppleEventsUsageDescription":
            "Fudge and the extensions you installed use this to carry out commands in other apps, such as Empty Trash in Finder.",
        "NSBluetoothAlwaysUsageDescription": "An extension you installed wants to use Bluetooth.",
        "NSCalendarsFullAccessUsageDescription":
            "Fudge shows your upcoming events in My Schedule, and extensions you installed can use your calendars.",
        "NSCameraUsageDescription": "An extension you installed wants to use the camera.",
        "NSContactsUsageDescription": "An extension you installed wants to use your contacts.",
        "NSLocationUsageDescription": "An extension you installed wants to use your location.",
        "NSLocationWhenInUseUsageDescription": "An extension you installed wants to use your location.",
        "NSMicrophoneUsageDescription": "An extension you installed wants to use the microphone.",
        "NSPhotoLibraryUsageDescription": "An extension you installed wants to use your photos.",
        "NSRemindersFullAccessUsageDescription": "An extension you installed wants to use your reminders.",
    ]
    #expect(Set(texts.keys) == Set(expected.keys))
    for (key, text) in expected {
        #expect(texts[key] == text, "\(key)")
    }
}
