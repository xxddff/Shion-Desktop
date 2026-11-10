import AppKit
import XCTest

/// For ExtrasScreenshotTests and ExtrasTests: a row of a long page (Settings → 这台 Mac, a report
/// with its screen time) brought into view before its picture is taken.
extension XCTestCase {
    /// Scrolls the window's scroll view until `element` is in full view under the toolbar and above
    /// the Dock; with `atTop`, until it is just under the toolbar, so what follows it shows too. As
    /// LocalScreenshotTests scrolls Settings: which sign of a wheel delta moves the page which way is
    /// the runner's business, so a step that goes the wrong way flips it.
    @MainActor
    func bringIntoView(_ element: XCUIElement, in window: XCUIElement, atTop: Bool = false) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        // the scroll view the element is in: a main window's first one is the sidebar's
        let x = element.frame.midX
        let area = window.scrollViews.allElementsBoundByIndex.first { $0.frame.minX <= x && x <= $0.frame.maxX }
            ?? (window.scrollViews.firstMatch.exists ? window.scrollViews.firstMatch : window)
        let toolbar = window.toolbars.firstMatch
        var up: CGFloat = -1  // the sign of a delta that moves the page up
        var signKnown = false
        // the window can reach down behind the Dock (the runner's screen is small). Screen points,
        // top-left origin, as XCUI's.
        let dock: CGFloat = NSScreen.main.map { $0.frame.maxY - $0.visibleFrame.minY } ?? .greatestFiniteMagnitude
        for _ in 0..<40 {
            let top = (toolbar.exists ? toolbar.frame.maxY : window.frame.minY) + 6
            let bottom = min(window.frame.maxY, dock) - 6
            let frame = element.frame
            let inView = frame.minY >= top && frame.maxY <= bottom
            let target = atTop ? top + 48 : min(max(frame.minY, top), bottom - frame.height)
            let distance = frame.minY - target  // more than 0: the page has to move up
            if inView, abs(distance) <= (atTop ? 16 : 0.5) { return true }
            area.hover()
            area.scroll(byDeltaX: 0, deltaY: (distance > 0 ? up : -up) * max(16, min(240, abs(distance))))
            Thread.sleep(forTimeInterval: 0.25)
            let moved = element.frame.minY - frame.minY
            if abs(moved) < 1 {
                // nothing moved: the wrong way at an end of the page, or the end it has to go to
                if !signKnown {
                    up = -up
                    signKnown = true
                    continue
                }
                return inView
            }
            signKnown = true
            if (distance > 0) != (moved < 0) { up = -up }
        }
        return false
    }
}
