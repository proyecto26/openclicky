//
//  OverlayWindow.swift
//  One transparent full-screen NSWindow per connected display. Hosts
//  the SwiftUI BlueCursorView. The window itself is click-through and
//  non-activating so the user's frontmost app keeps focus; OverlayManager
//  drives show/hide and the published target coordinate.
//
//  Not based on NSPanel like the menu-bar panel — a plain borderless
//  NSWindow with .screenSaver level sits above most macOS UI including
//  submenus and tooltips, which is what you want for a "point at this
//  thing" overlay.
//

import AppKit
import SwiftUI

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, rootView: AnyView) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = hostingView

        setFrame(screen.frame, display: true)
        setFrameOrigin(screen.frame.origin)
    }

    // Overlay never accepts focus; keep the frontmost app key.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
