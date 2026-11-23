import Testing

@testable import FudgeCore

@Test func messageTextJoinsTwoPartsWithAColon() {
    #expect(
        MessageText.joined("Can't open Notes", "The file isn't there.") == "Can't open Notes: The file isn't there.")
    #expect(MessageText.joined("Weather failed", "No network") == "Weather failed: No network")
    #expect(MessageText.joined("Copied", "3 items") == "Copied: 3 items")
}

@Test func messageTextJoinsWithASpaceAfterAPartThatAlreadyEnds() {
    for ending in [".", ":", "!", "?", "…"] {
        #expect(MessageText.joined("Done\(ending)", "3 items") == "Done\(ending) 3 items", "\(ending)")
    }
    #expect(MessageText.endings == [".", ":", "!", "?", "…"])
    // Only the last character counts: a mark inside the first part, or another ending, still takes the colon.
    #expect(MessageText.joined("v1.2 failed", "No network") == "v1.2 failed: No network")
    #expect(MessageText.joined("Saved;", "3 items") == "Saved;: 3 items")
    #expect(MessageText.joined("Saved,", "3 items") == "Saved,: 3 items")
}

@Test func messageTextDropsAMissingOrEmptyFirstPart() {
    #expect(MessageText.joined(nil, "No network") == "No network")
    #expect(MessageText.joined("", "No network") == "No network")
    #expect(MessageText.joined("  \n", "No network") == "No network")
}

@Test func messageTextDropsAMissingOrEmptySecondPart() {
    #expect(MessageText.joined("Weather failed", nil) == "Weather failed")
    #expect(MessageText.joined("Weather failed", "") == "Weather failed")
    #expect(MessageText.joined("Weather failed", " \t") == "Weather failed")
    #expect(MessageText.joined("Done.", nil) == "Done.")
}

@Test func messageTextIsEmptyWithNeitherPart() {
    #expect(MessageText.joined(nil, nil) == "")
    #expect(MessageText.joined("", "") == "")
    #expect(MessageText.joined(nil, " ") == "")
}

@Test func messageTextTrimsTheWhitespaceAroundEachPart() {
    #expect(MessageText.joined("Weather failed ", "  No network\n") == "Weather failed: No network")
    // The ending is read after the trim, so "Done. " still takes a space.
    #expect(MessageText.joined("Done. ", "3 items") == "Done. 3 items")
    // Inside a part, nothing changes.
    #expect(MessageText.joined("Can't open  Notes", "line one\nline two") == "Can't open  Notes: line one\nline two")
}

@Test func messageTextNeverWritesAnEmDash() {
    let joined = [
        MessageText.joined("a", "b"), MessageText.joined("a.", "b"), MessageText.joined(nil, "b"),
        MessageText.joined("a", nil),
    ]
    #expect(joined.allSatisfy { !$0.unicodeScalars.contains("\u{2014}") })
}
