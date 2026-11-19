import CoreGraphics
import Testing
@testable import SingleThreadCore

@Suite("Screen geometry")
struct GeometryTests {
    // A built-in 1710×1107 display as primary, plus a 2560×1440 display
    // arranged above it and shifted left, like a laptop under a monitor.
    let primaryHeight: CGFloat = 1107
    let primaryAppKit = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let upperAppKit = CGRect(x: -475, y: 1107, width: 2560, height: 1440)

    @Test("Window on the primary display")
    func primaryDisplay() {
        let cg = CGRect(x: 100, y: 34, width: 800, height: 600)
        let appKit = ScreenGeometry.appKitRect(fromCG: cg, primaryScreenHeight: primaryHeight)
        #expect(appKit == CGRect(x: 100, y: 1107 - 634, width: 800, height: 600))
    }

    @Test("Window on a display above the primary has negative CG y")
    func displayAbove() {
        // Fills the upper display: CG y is negative above the primary.
        let cg = CGRect(x: -475, y: -1440, width: 2560, height: 1440)
        let appKit = ScreenGeometry.appKitRect(fromCG: cg, primaryScreenHeight: primaryHeight)
        #expect(appKit == upperAppKit)
    }

    @Test("Window on a display below the primary has negative AppKit y")
    func displayBelow() {
        let cg = CGRect(x: 0, y: 1107, width: 1920, height: 1080)
        let appKit = ScreenGeometry.appKitRect(fromCG: cg, primaryScreenHeight: primaryHeight)
        #expect(appKit == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test("Window on a display to the left keeps its negative x")
    func displayLeft() {
        let cg = CGRect(x: -1500, y: 200, width: 700, height: 500)
        let appKit = ScreenGeometry.appKitRect(fromCG: cg, primaryScreenHeight: primaryHeight)
        #expect(appKit == CGRect(x: -1500, y: 407, width: 700, height: 500))
    }

    @Test("Conversion round-trips", arguments: [
        CGRect(x: 10, y: 20, width: 300, height: 200),
        CGRect(x: -475, y: -1440, width: 2560, height: 1440),
        CGRect(x: 1600, y: 1000, width: 400, height: 300),
    ])
    func roundTrip(rect: CGRect) {
        let there = ScreenGeometry.appKitRect(fromCG: rect, primaryScreenHeight: primaryHeight)
        let back = ScreenGeometry.cgRect(fromAppKit: there, primaryScreenHeight: primaryHeight)
        #expect(back == rect)
    }

    @Test("A window spanning two displays belongs to the one holding most of it")
    func displayIndex() {
        let displays = [primaryAppKit, upperAppKit]
        let mostlyUpper = CGRect(x: 100, y: 1000, width: 400, height: 400)
        #expect(ScreenGeometry.displayIndex(containingMostOf: mostlyUpper, displayFrames: displays) == 1)
        let mostlyPrimary = CGRect(x: 100, y: 900, width: 400, height: 400)
        #expect(ScreenGeometry.displayIndex(containingMostOf: mostlyPrimary, displayFrames: displays) == 0)
        let offscreen = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        #expect(ScreenGeometry.displayIndex(containingMostOf: offscreen, displayFrames: displays) == nil)
    }

    @Test("Approximate frame equality tolerates sub-point differences")
    func approximateEquality() {
        let a = CGRect(x: 100, y: 100, width: 500, height: 400)
        #expect(ScreenGeometry.approximatelyEqual(a, a.offsetBy(dx: 0.5, dy: -1)))
        #expect(!ScreenGeometry.approximatelyEqual(a, a.insetBy(dx: 5, dy: 0)))
    }
}
