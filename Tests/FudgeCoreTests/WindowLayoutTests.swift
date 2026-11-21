import CoreGraphics
import Foundation
import Testing

@testable import FudgeCore

/// A landscape screen's visible frame, below a 25-point menu bar, in top-left coordinates.
private let landscape = CGRect(x: 0, y: 25, width: 1440, height: 875)
/// A portrait screen to the right of it, not at the origin.
private let portrait = CGRect(x: 1440, y: -200, width: 1080, height: 1920)
private let window = CGRect(x: 100, y: 125, width: 800, height: 500)

private func frame(_ command: WindowCommand, _ visible: CGRect = landscape, current: CGRect = window) -> CGRect? {
    WindowLayout.frame(for: command, in: visible, current: current)
}

@Test func halvesAndQuartersFillTheirPartOfTheVisibleFrame() {
    #expect(frame(.leftHalf) == CGRect(x: 0, y: 25, width: 720, height: 875))
    #expect(frame(.rightHalf) == CGRect(x: 720, y: 25, width: 720, height: 875))
    #expect(frame(.topHalf) == CGRect(x: 0, y: 25, width: 1440, height: 438))
    #expect(frame(.bottomHalf) == CGRect(x: 0, y: 463, width: 1440, height: 437), "odd heights round, with no gap")
    #expect(frame(.topLeftQuarter) == CGRect(x: 0, y: 25, width: 720, height: 438))
    #expect(frame(.topRightQuarter) == CGRect(x: 720, y: 25, width: 720, height: 438))
    #expect(frame(.bottomLeftQuarter) == CGRect(x: 0, y: 463, width: 720, height: 437))
    #expect(frame(.bottomRightQuarter) == CGRect(x: 720, y: 463, width: 720, height: 437))
    #expect(frame(.maximize) == landscape)
}

@Test func thirdsGoAcrossALandscapeScreenAndDownAPortraitOne() {
    #expect(frame(.firstThird) == CGRect(x: 0, y: 25, width: 480, height: 875))
    #expect(frame(.centerThird) == CGRect(x: 480, y: 25, width: 480, height: 875))
    #expect(frame(.lastThird) == CGRect(x: 960, y: 25, width: 480, height: 875))
    #expect(frame(.firstTwoThirds) == CGRect(x: 0, y: 25, width: 960, height: 875))
    #expect(frame(.lastTwoThirds) == CGRect(x: 480, y: 25, width: 960, height: 875))

    #expect(frame(.firstThird, portrait) == CGRect(x: 1440, y: -200, width: 1080, height: 640))
    #expect(frame(.centerThird, portrait) == CGRect(x: 1440, y: 440, width: 1080, height: 640))
    #expect(frame(.lastThird, portrait) == CGRect(x: 1440, y: 1080, width: 1080, height: 640))
    #expect(frame(.lastTwoThirds, portrait) == CGRect(x: 1440, y: 440, width: 1080, height: 1280))
}

@Test func thirdsOfAnOddWidthMeetWithoutAGap() throws {
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 700)
    let first = try #require(frame(.firstThird, odd))
    let center = try #require(frame(.centerThird, odd))
    let last = try #require(frame(.lastThird, odd))
    #expect(first.maxX == center.minX && center.maxX == last.minX && last.maxX == 1001)
    for part in [first, center, last] {
        #expect(part.minX == part.minX.rounded() && part.width == part.width.rounded(), "whole points")
    }
}

@Test func centeredSizes() {
    #expect(frame(.almostMaximize) == CGRect(x: 72, y: 69, width: 1296, height: 787))
    #expect(frame(.reasonableSize) == CGRect(x: 288, y: 200, width: 864, height: 525))
    #expect(frame(.center) == CGRect(x: 320, y: 213, width: 800, height: 500))
    let huge = CGRect(x: -50, y: 0, width: 3000, height: 2000)
    #expect(frame(.center, current: huge) == landscape, "a window bigger than the screen is clamped to it")
}

@Test func maximizeWidthOrHeightKeepsTheOther() {
    #expect(frame(.maximizeWidth) == CGRect(x: 0, y: 125, width: 1440, height: 500))
    #expect(frame(.maximizeHeight) == CGRect(x: 100, y: 25, width: 800, height: 875))
    let low = CGRect(x: 1000, y: 700, width: 800, height: 500)
    #expect(frame(.maximizeWidth, current: low) == CGRect(x: 0, y: 400, width: 1440, height: 500), "kept inside")
    #expect(frame(.maximizeHeight, current: low) == CGRect(x: 640, y: 25, width: 800, height: 875))
}

@Test func makeLargerAndSmallerStepAboutTheCenterWithinLimits() {
    // 5% of the screen on each side: 72 points across, about 44 down.
    #expect(frame(.makeLarger) == CGRect(x: 28, y: 81, width: 944, height: 588))
    #expect(frame(.makeSmaller) == CGRect(x: 172, y: 169, width: 656, height: 412))
    #expect(frame(.makeLarger, current: landscape) == landscape, "never past the visible frame")
    let tiny = CGRect(x: 600, y: 400, width: 300, height: 180)
    #expect(frame(.makeSmaller, current: tiny) == CGRect(x: 606, y: 403, width: 288, height: 175), "never below 20%")
    let corner = CGRect(x: 0, y: 25, width: 400, height: 300)
    #expect(frame(.makeLarger, current: corner)?.origin == CGPoint(x: 0, y: 25), "grows inward at an edge")
}

@Test func commandsThatArentAFrameOnTheSameScreenHaveNone() {
    for command in [WindowCommand.restore, .nextDisplay, .previousDisplay, .toggleFullScreen] {
        #expect(frame(command) == nil, "\(command)")
    }
    for command in WindowCommand.allCases where ![.restore, .nextDisplay, .previousDisplay, .toggleFullScreen].contains(command) {
        let target = frame(command)
        #expect(target.map { landscape.contains($0) } == true, "\(command) stays inside the visible frame")
    }
}

@Test func movingToAnotherDisplayKeepsThePlaceAndSizeRelativeToIt() {
    let moved = WindowLayout.moved(window, from: landscape, to: portrait)
    #expect(moved == CGRect(x: 1515, y: 19, width: 600, height: 1098))
    let big = CGRect(x: 0, y: 25, width: 1440, height: 875)
    #expect(WindowLayout.moved(big, from: landscape, to: portrait) == portrait, "a full window stays full")
    let wide = CGRect(x: 0, y: 0, width: 400, height: 300)
    #expect(portrait.contains(WindowLayout.moved(wide.offsetBy(dx: 1300, dy: 0), from: landscape, to: portrait)))
}

@Test func displaysAreOrderedLeftToRightThenTopToBottom() {
    let above = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
    let left = CGRect(x: -1280, y: 100, width: 1280, height: 775)
    #expect(WindowLayout.displayOrder([landscape, portrait, above, left]) == [left, above, landscape, portrait])
    #expect(WindowLayout.neighbour(of: 0, among: 3, forward: true) == 1)
    #expect(WindowLayout.neighbour(of: 2, among: 3, forward: true) == 0)
    #expect(WindowLayout.neighbour(of: 0, among: 3, forward: false) == 2)
}

@Test func aWindowThatCantBeResizedMovesToTheTargetsCornerInside() {
    let target = CGRect(x: 720, y: 25, width: 720, height: 875)
    #expect(
        WindowLayout.movedOnly(size: CGSize(width: 900, height: 500), to: target, in: landscape)
            == CGRect(x: 540, y: 25, width: 900, height: 500))
}
