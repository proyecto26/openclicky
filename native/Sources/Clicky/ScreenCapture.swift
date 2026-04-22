//
//  ScreenCapture.swift
//  ScreenCaptureKit wrappers for single- and multi-display snapshots.
//
//  Two entry points:
//    - capturePrimaryDisplay() — legacy single-screen flow used by the
//      typed "Test Claude" path when no POINT mapping is needed.
//    - captureAllDisplays() — multi-screen flow powering v0.3 POINT
//      animations. Returns a manifest with per-display metadata so the
//      POINT coordinate mapper can resolve screenN → AppKit global coords.
//
//  Display indexing: sorted so the cursor's display is always index 0.
//  This matches upstream Clicky's behaviour and keeps ":screen1" (the
//  default when Claude omits the suffix) semantically equal to "the
//  screen the user is looking at".
//

import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: Error, CustomStringConvertible {
    case noDisplaysAvailable
    case captureFailed(underlying: Error)
    case encodingFailed

    var description: String {
        switch self {
        case .noDisplaysAvailable:
            return "No displays available to capture. Is a monitor connected?"
        case .captureFailed(let underlying):
            return "Screen capture failed: \(underlying.localizedDescription). Grant Screen Recording in System Settings → Privacy & Security."
        case .encodingFailed:
            return "Failed to encode captured frame as JPEG."
        }
    }
}

/// Single captured frame (legacy primary-display entry point).
struct CapturedFrame {
    let jpegData: Data
    let widthPx: Int
    let heightPx: Int
    let label: String
}

/// Per-display snapshot with all the metadata needed to map a POINT
/// tag's screenshot-pixel coords back to a global AppKit CGPoint.
struct CapturedScreen {
    /// 1-based display index matching the `:screenN` suffix Claude
    /// emits (1 = cursor's screen).
    let screenNumber: Int
    /// Shown to Claude in the prompt so it knows which screen is which.
    let label: String
    /// JPEG bytes for the Claude vision payload.
    let jpegData: Data
    /// Screenshot resolution — Claude's POINT coords are in this space.
    let widthPx: Int
    let heightPx: Int
    /// Display geometry in AppKit coordinates (bottom-left origin).
    /// Used by the POINT coordinate mapper to convert px → display points
    /// → global AppKit coords.
    let displayFrame: CGRect
    /// Convenience: true when the user's cursor was on this display at
    /// capture time.
    let isCursorScreen: Bool
}

struct CaptureManifest {
    let screens: [CapturedScreen]
    let capturedAt: Date

    var cursorScreen: CapturedScreen? { screens.first(where: \.isCursorScreen) }
}

struct ScreenCapture {
    // MARK: - Single-display (legacy)

    /// Captures the primary display and returns a JPEG + dimensions.
    static func capturePrimaryDisplay(maxWidth: Int = 1280) async throws -> CapturedFrame {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenCaptureError.captureFailed(underlying: error)
        }
        guard let display = content.displays.first else {
            throw ScreenCaptureError.noDisplaysAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let (targetW, targetH) = scaledSize(nativeWidth: Int(display.width), nativeHeight: Int(display.height), maxWidth: maxWidth)
        config.width = targetW
        config.height = targetH
        config.capturesAudio = false
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenCaptureError.captureFailed(underlying: error)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ScreenCaptureError.encodingFailed
        }

        return CapturedFrame(
            jpegData: jpegData,
            widthPx: cgImage.width,
            heightPx: cgImage.height,
            label: "screen1 (primary focus, \(cgImage.width)x\(cgImage.height))"
        )
    }

    // MARK: - Multi-display (v0.3 overlay path)

    /// Captures every connected display. Excludes Clicky's own windows
    /// from the capture so the panel never appears in its own
    /// screenshots. Displays are returned sorted with the cursor's
    /// screen as index 0 so ":screen1" always resolves to primary focus.
    static func captureAllDisplays(maxWidth: Int = 1280) async throws -> CaptureManifest {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.captureFailed(underlying: error)
        }
        guard !content.displays.isEmpty else {
            throw ScreenCaptureError.noDisplaysAvailable
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude our own windows so overlays / panels don't show up in
        // the screenshots Claude sees.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleID
        }

        // NSEvent.mouseLocation + NSScreen.frame are in AppKit
        // coordinates (bottom-left origin); SCDisplay.frame uses Core
        // Graphics coordinates (top-left origin). On multi-display
        // setups these differ for secondary screens. Build an AppKit
        // frame for each display up front so all downstream math lives
        // in a single coordinate system.
        var appKitFrameByDisplayID: [CGDirectDisplayID: CGRect] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                appKitFrameByDisplayID[screenNumber] = screen.frame
            }
        }

        let sortedDisplays = content.displays.sorted { a, b in
            let frameA = appKitFrameByDisplayID[a.displayID] ?? CGRect(origin: a.frame.origin, size: CGSize(width: CGFloat(a.width), height: CGFloat(a.height)))
            let frameB = appKitFrameByDisplayID[b.displayID] ?? CGRect(origin: b.frame.origin, size: CGSize(width: CGFloat(b.width), height: CGFloat(b.height)))
            let aHasCursor = frameA.contains(mouseLocation)
            let bHasCursor = frameB.contains(mouseLocation)
            if aHasCursor != bHasCursor { return aHasCursor }
            return false
        }

        var screens: [CapturedScreen] = []
        for (zeroBasedIndex, display) in sortedDisplays.enumerated() {
            let screenNumber = zeroBasedIndex + 1
            let displayFrame = appKitFrameByDisplayID[display.displayID]
                ?? CGRect(origin: display.frame.origin, size: CGSize(width: CGFloat(display.width), height: CGFloat(display.height)))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)
            let config = SCStreamConfiguration()
            let (targetW, targetH) = scaledSize(nativeWidth: Int(display.width), nativeHeight: Int(display.height), maxWidth: maxWidth)
            config.width = targetW
            config.height = targetH
            config.capturesAudio = false
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let cgImage: CGImage
            do {
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                throw ScreenCaptureError.captureFailed(underlying: error)
            }

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                throw ScreenCaptureError.encodingFailed
            }

            let label: String
            if sortedDisplays.count == 1 {
                label = "screen1 (primary focus, \(cgImage.width)x\(cgImage.height))"
            } else if isCursorScreen {
                label = "screen\(screenNumber) of \(sortedDisplays.count) — primary focus (\(cgImage.width)x\(cgImage.height))"
            } else {
                label = "screen\(screenNumber) of \(sortedDisplays.count) — secondary (\(cgImage.width)x\(cgImage.height))"
            }

            screens.append(CapturedScreen(
                screenNumber: screenNumber,
                label: label,
                jpegData: jpegData,
                widthPx: cgImage.width,
                heightPx: cgImage.height,
                displayFrame: displayFrame,
                isCursorScreen: isCursorScreen
            ))
        }

        return CaptureManifest(screens: screens, capturedAt: Date())
    }

    // MARK: - Helpers

    /// Internal (not private) so XCTest can exercise the scaling math
    /// without needing Screen Recording permission for an actual capture.
    static func scaledSize(nativeWidth: Int, nativeHeight: Int, maxWidth: Int) -> (Int, Int) {
        guard nativeWidth > maxWidth else {
            return (nativeWidth, nativeHeight)
        }
        let scale = Double(maxWidth) / Double(nativeWidth)
        let scaledHeight = Int(Double(nativeHeight) * scale)
        return (maxWidth, scaledHeight)
    }
}
