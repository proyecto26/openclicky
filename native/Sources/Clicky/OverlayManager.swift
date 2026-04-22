//
//  OverlayManager.swift
//  Owns the per-display OverlayWindow pool and publishes the current
//  POINT target so BlueCursorView instances can animate. Created once
//  in ClickyViewModel.init and kept for the app lifetime.
//
//  Key behaviours:
//    - Creates / destroys overlay windows as displays connect and
//      disconnect (NSApplication.didChangeScreenParameters).
//    - Only one target at a time — activeTarget is @Published so every
//      BlueCursorView can observe changes reactively.
//    - clearTargetIfMatches avoids race conditions when a second POINT
//      lands while the previous cursor is still flying back.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import os

@MainActor
final class OverlayManager: ObservableObject {
    /// Current POINT target being visualised. Nil when no animation
    /// in progress. Published so every BlueCursorView can observe and
    /// decide whether to show/hide based on screenFrame match.
    @Published private(set) var activeTarget: BlueCursorTarget?

    private let logger = Logger(subsystem: "com.proyecto26.clicky", category: "OverlayManager")
    private var windows: [OverlayWindow] = []
    private var screenParameterObserver: NSObjectProtocol?

    init() {
        installScreenParameterObserver()
        rebuildWindowsForCurrentScreens()
    }

    deinit {
        if let observer = screenParameterObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Drive the blue cursor to `target`. Replaces any in-flight
    /// animation. The BlueCursorView for the matching display picks
    /// it up via Combine and starts the flight.
    func flyTo(_ target: BlueCursorTarget) {
        logger.info("Flying to target on screen frame \(String(describing: target.displayFrame), privacy: .public)")
        ensureWindowsVisible()
        activeTarget = target
    }

    /// Called by a BlueCursorView when it finishes its fly-back-to-
    /// cursor animation. We only clear if the current activeTarget
    /// is the one that just finished, so a newly-dispatched target
    /// doesn't get overwritten.
    func clearTargetIfMatches(target screenFrame: CGRect) {
        guard let active = activeTarget, active.displayFrame == screenFrame else { return }
        activeTarget = nil
        // Leave windows on screen; they're transparent and cheap to
        // keep mounted. They hide visually when opacity drops to 0.
    }

    // MARK: - Private

    private func installScreenParameterObserver() {
        screenParameterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildWindowsForCurrentScreens()
            }
        }
    }

    private func rebuildWindowsForCurrentScreens() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = NSScreen.screens.map { screen in
            let view = BlueCursorView(screenFrame: screen.frame, manager: self)
            return OverlayWindow(screen: screen, rootView: AnyView(view))
        }
        logger.info("Rebuilt \(self.windows.count, privacy: .public) overlay window(s) for \(NSScreen.screens.count, privacy: .public) display(s)")
    }

    private func ensureWindowsVisible() {
        for window in windows where !window.isVisible {
            window.orderFrontRegardless()
        }
    }
}
