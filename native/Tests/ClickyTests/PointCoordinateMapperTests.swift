//
//  PointCoordinateMapperTests.swift
//  Covers the px → point → AppKit-global coordinate pipeline plus the
//  screen-picking logic for single- and multi-display configurations.
//

import CoreGraphics
import XCTest
@testable import Clicky

final class PointCoordinateMapperTests: XCTestCase {

    // MARK: - Fixtures

    /// Single laptop display, 1512×982 points, Retina captured at 1280×832 px.
    private func singleDisplayManifest() -> CaptureManifest {
        let screen = CapturedScreen(
            screenNumber: 1,
            label: "screen1",
            jpegData: Data(),
            widthPx: 1280,
            heightPx: 832,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            isCursorScreen: true
        )
        return CaptureManifest(screens: [screen], capturedAt: Date())
    }

    /// Cursor laptop to the right of a 2560x1440 external display with
    /// AppKit origin at (-2560, 0). Mirrors a common side-by-side setup.
    private func multiDisplayManifest() -> CaptureManifest {
        let cursor = CapturedScreen(
            screenNumber: 1,
            label: "screen1 primary",
            jpegData: Data(),
            widthPx: 1280,
            heightPx: 832,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            isCursorScreen: true
        )
        let secondary = CapturedScreen(
            screenNumber: 2,
            label: "screen2 secondary",
            jpegData: Data(),
            widthPx: 1280,
            heightPx: 720,
            displayFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
            isCursorScreen: false
        )
        return CaptureManifest(screens: [cursor, secondary], capturedAt: Date())
    }

    // MARK: - Single-display math

    func testTopLeftPixelMapsToTopLeftOfDisplayWithYFlip() {
        let manifest = singleDisplayManifest()
        let target = PointCoordinateMapper.map(x: 0, y: 0, screenNumber: nil, label: nil, manifest: manifest)!
        // Top-left screenshot pixel is the top-left of the display.
        // AppKit y = displayHeight - 0 = 982.
        XCTAssertEqual(target.globalLocation.x, 0)
        XCTAssertEqual(target.globalLocation.y, 982)
        XCTAssertEqual(target.screenNumber, 1)
    }

    func testBottomRightPixelMapsToGlobalBottomRight() {
        let manifest = singleDisplayManifest()
        let target = PointCoordinateMapper.map(x: 1280, y: 832, screenNumber: nil, label: nil, manifest: manifest)!
        // Bottom-right pixel scales to (1512, 982) display-local, then
        // Y-flips to (1512, 0) in AppKit global coords.
        XCTAssertEqual(target.globalLocation.x, 1512, accuracy: 0.001)
        XCTAssertEqual(target.globalLocation.y, 0, accuracy: 0.001)
    }

    func testMidPointScalesProportionally() {
        let manifest = singleDisplayManifest()
        // Screenshot center = (640, 416). Display center = (756, 491).
        let target = PointCoordinateMapper.map(x: 640, y: 416, screenNumber: nil, label: nil, manifest: manifest)!
        XCTAssertEqual(target.globalLocation.x, 756, accuracy: 0.001)
        XCTAssertEqual(target.globalLocation.y, 491, accuracy: 0.001)
    }

    func testOutOfBoundsCoordsAreClamped() {
        let manifest = singleDisplayManifest()
        let target = PointCoordinateMapper.map(x: 99999, y: -50, screenNumber: nil, label: nil, manifest: manifest)!
        // Clamped to screenshot bottom-right corner → display bottom-right
        // → AppKit (1512, 0).
        XCTAssertEqual(target.globalLocation.x, 1512, accuracy: 0.001)
        XCTAssertEqual(target.globalLocation.y, 982, accuracy: 0.001, "clamped negative y becomes 0 → Y-flipped back to 982")
    }

    // MARK: - Multi-display screen picking

    func testOmittedScreenNumberDefaultsToCursorScreen() {
        let manifest = multiDisplayManifest()
        let target = PointCoordinateMapper.map(x: 0, y: 0, screenNumber: nil, label: nil, manifest: manifest)!
        XCTAssertEqual(target.screenNumber, 1, "nil screen number must pick the cursor screen, not the first entry")
    }

    func testExplicitScreen2MapsIntoNegativeOriginDisplay() {
        let manifest = multiDisplayManifest()
        // Center of the 1280×720 screenshot on screen2 (2560×1440 display,
        // origin at (-2560, 0)):
        //   displayLocal = (1280, 720)
        //   Y-flip       → 1440 - 720 = 720
        //   +origin      → (-2560 + 1280, 0 + 720) = (-1280, 720)
        let target = PointCoordinateMapper.map(x: 640, y: 360, screenNumber: 2, label: "save button", manifest: manifest)!
        XCTAssertEqual(target.screenNumber, 2)
        XCTAssertEqual(target.globalLocation.x, -1280, accuracy: 0.001)
        XCTAssertEqual(target.globalLocation.y, 720, accuracy: 0.001)
        XCTAssertEqual(target.label, "save button")
    }

    func testUnknownScreenNumberReturnsNil() {
        let manifest = multiDisplayManifest()
        // Claude hallucinated a 3rd screen on a 2-screen setup.
        XCTAssertNil(PointCoordinateMapper.map(x: 10, y: 10, screenNumber: 3, label: nil, manifest: manifest))
    }

    func testPointTagOverloadBridgesCorrectly() {
        let manifest = singleDisplayManifest()
        let tag = PointTag(x: 1280, y: 832, label: "anywhere", screen: nil)
        let target = PointCoordinateMapper.map(point: tag, manifest: manifest)!
        XCTAssertEqual(target.label, "anywhere")
        XCTAssertEqual(target.globalLocation.x, 1512, accuracy: 0.001)
    }

    func testNilPointReturnsNilTarget() {
        let manifest = singleDisplayManifest()
        XCTAssertNil(PointCoordinateMapper.map(point: nil, manifest: manifest))
    }
}
