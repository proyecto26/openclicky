//
//  PointCoordinateMapper.swift
//  Translates Claude's POINT tag (screenshot-pixel coordinates) into
//  a global AppKit CGPoint the overlay cursor can fly to.
//
//  Math pipeline:
//    1. Clamp (x, y) to the screenshot's pixel bounds. Claude sometimes
//       emits coords just outside the frame; we don't want to point off-
//       screen.
//    2. Scale px → display-local points. Screenshots are resolution-
//       capped (e.g. 1280x800 for a 3024x1890 Retina display), so we
//       must scale back up to the *display's* point space before any
//       global-coord math.
//    3. Flip Y axis. Screenshots use top-left origin; AppKit's global
//       coordinate system uses bottom-left origin. On a display
//       1114pt tall, a screenshot's (100, 50) maps to display-local
//       (100, 1064) in AppKit.
//    4. Translate by the target display's frame origin to land in the
//       global coordinate space all NSWindow / NSEvent / NSPanel APIs
//       share.
//
//  Pure function — unit-tested without any NSScreen / ScreenCaptureKit
//  dependency.
//

import CoreGraphics
import Foundation

struct MappedPointTarget: Equatable {
    /// Global AppKit screen coordinate (bottom-left origin) where the
    /// overlay cursor should land.
    let globalLocation: CGPoint
    /// AppKit frame of the display containing the target — handy for
    /// picking which per-screen overlay window to animate.
    let displayFrame: CGRect
    /// 1-based screen index of the resolved display (matches the
    /// `:screenN` suffix in the tag grammar).
    let screenNumber: Int
    /// Optional element label pass-through so the caller can render it
    /// in the speech bubble without re-threading the tag.
    let label: String?
}

enum PointCoordinateMapper {
    /// Resolves a parsed POINT tag against a capture manifest. Returns
    /// nil when:
    ///   - the tag is nil (no pointing intended), or
    ///   - the tag names a screen number the manifest doesn't have
    ///     (e.g. Claude hallucinated `:screen3` on a 2-display setup).
    ///
    /// When the tag omits `:screenN`, defaults to the cursor screen —
    /// this matches upstream Clicky's expectation that ":screen1"
    /// (always the cursor screen after our sort) is the silent default.
    static func map(point: PointTag?, manifest: CaptureManifest) -> MappedPointTarget? {
        guard let point else { return nil }
        return map(
            x: point.x,
            y: point.y,
            screenNumber: point.screen,
            label: point.label,
            manifest: manifest
        )
    }

    /// Lower-level overload used directly by XCTest. Picks the target
    /// screen, runs the px → point → AppKit-global pipeline, returns
    /// the mapped target or nil.
    static func map(
        x: Double,
        y: Double,
        screenNumber: Int?,
        label: String?,
        manifest: CaptureManifest
    ) -> MappedPointTarget? {
        let targetScreen: CapturedScreen
        if let requested = screenNumber {
            guard let found = manifest.screens.first(where: { $0.screenNumber == requested }) else {
                return nil
            }
            targetScreen = found
        } else if let cursor = manifest.cursorScreen {
            targetScreen = cursor
        } else if let first = manifest.screens.first {
            targetScreen = first
        } else {
            return nil
        }

        let screenshotWidth = CGFloat(targetScreen.widthPx)
        let screenshotHeight = CGFloat(targetScreen.heightPx)
        guard screenshotWidth > 0, screenshotHeight > 0 else { return nil }

        let displayWidth = targetScreen.displayFrame.width
        let displayHeight = targetScreen.displayFrame.height

        // 1. clamp to screenshot bounds
        let clampedX = max(0, min(CGFloat(x), screenshotWidth))
        let clampedY = max(0, min(CGFloat(y), screenshotHeight))

        // 2. scale px → display-local points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // 3. Y-flip (screenshot top-left → AppKit bottom-left)
        let appKitLocalY = displayHeight - displayLocalY

        // 4. translate by the display's global origin
        let globalLocation = CGPoint(
            x: displayLocalX + targetScreen.displayFrame.origin.x,
            y: appKitLocalY + targetScreen.displayFrame.origin.y
        )

        return MappedPointTarget(
            globalLocation: globalLocation,
            displayFrame: targetScreen.displayFrame,
            screenNumber: targetScreen.screenNumber,
            label: label
        )
    }
}
