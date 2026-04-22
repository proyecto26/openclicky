//
//  BlueCursorView.swift
//  SwiftUI blue triangle cursor that flies along a quadratic Bézier
//  arc to a POINT target, holds for a moment with a label chip, then
//  flies back to the user's physical cursor position.
//
//  Scope (v0.3):
//    - Pure POINT animation. No cursor-follow, no waveform, no
//      listening/processing/speaking state — those live in the panel.
//    - One view per overlay window (one per display). The view only
//      animates when the manager publishes a target whose screenFrame
//      matches this view's screenFrame.
//
//  Animation style (ports the upstream flight):
//    - Quadratic Bézier from start (current cursor) to target; control
//      point offset upward by min(distance * 0.2, 80).
//    - Smoothstep easing: 3t² − 2t³.
//    - Rotation follows tangent so the triangle "points where it's going".
//    - Scale pulses sin(πt) with peak 1.3× at midpoint.
//    - Duration scales with distance: clamp(distance / 800, 0.6 … 1.4) s.
//

import AppKit
import SwiftUI

/// Published to the overlay by OverlayManager. Each BlueCursorView
/// decides whether it's the right one for this target by comparing
/// screenFrames.
struct BlueCursorTarget: Equatable {
    /// Global AppKit coordinate. Caller converts to view-local.
    let globalLocation: CGPoint
    /// AppKit frame of the destination display.
    let displayFrame: CGRect
    /// 1-3 word label shown in the chip on arrival.
    let label: String?
}

enum BlueCursorMode: Equatable {
    case idle
    case flyingToTarget
    case pointing
    case flyingBack
}

struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var manager: OverlayManager

    @State private var position: CGPoint = .zero
    @State private var rotation: Double = 0
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0
    @State private var mode: BlueCursorMode = .idle
    @State private var chipText: String? = nil
    @State private var animationTimer: Timer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if opacity > 0 {
                cursor
                    .position(position)
                    .animation(nil, value: position)

                if mode == .pointing, let chipText {
                    labelChip(chipText)
                        .position(
                            x: position.x,
                            y: max(24, position.y - 32)  // float above the cursor
                        )
                        .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .allowsHitTesting(false)
        .onReceive(manager.$activeTarget) { target in
            handleTargetChange(target)
        }
    }

    // MARK: - Subviews

    private var cursor: some View {
        Triangle()
            .fill(
                LinearGradient(
                    colors: [Color.blue.opacity(0.95), Color.blue.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 28, height: 28)
            .rotationEffect(.radians(rotation), anchor: .center)
            .scaleEffect(scale)
            .shadow(color: .blue.opacity(0.55), radius: 10)
            .opacity(opacity)
    }

    private func labelChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.blue.opacity(0.92))
                    .shadow(color: .blue.opacity(0.45), radius: 8, y: 2)
            )
    }

    // MARK: - State machine

    /// Called whenever OverlayManager's activeTarget changes. If the
    /// new target is on this view's screen, kick off the flight
    /// animation. If it's nil (manager cleared it), hide the overlay.
    private func handleTargetChange(_ target: BlueCursorTarget?) {
        guard let target else {
            stopAnimation()
            withAnimation(.easeOut(duration: 0.25)) { opacity = 0 }
            mode = .idle
            chipText = nil
            return
        }
        guard target.displayFrame == screenFrame else {
            // Not our display — make sure this view is hidden.
            stopAnimation()
            opacity = 0
            return
        }

        let startGlobal = NSEvent.mouseLocation
        let startView = convertGlobalToView(startGlobal)
        let endView = convertGlobalToView(target.globalLocation)

        position = startView
        rotation = 0
        scale = 1
        opacity = 1
        mode = .flyingToTarget
        chipText = nil

        animateBezier(from: startView, to: endView, duration: flightDuration(from: startView, to: endView)) {
            mode = .pointing
            chipText = target.label ?? "here"
            // Hold, then fly back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                flyBackToCursor()
            }
        }
    }

    private func flyBackToCursor() {
        guard mode == .pointing else { return }
        let start = position
        let end = convertGlobalToView(NSEvent.mouseLocation)
        chipText = nil
        mode = .flyingBack
        animateBezier(from: start, to: end, duration: flightDuration(from: start, to: end)) {
            withAnimation(.easeOut(duration: 0.2)) { opacity = 0 }
            mode = .idle
            manager.clearTargetIfMatches(target: screenFrame)
        }
    }

    // MARK: - Bezier animation

    private func animateBezier(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        onComplete: @escaping () -> Void
    ) {
        stopAnimation()

        let distance = hypot(end.x - start.x, end.y - start.y)
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Control point pulls the arc upward in screen space. In SwiftUI's
        // top-left-origin view space, "upward" means subtract from y.
        let arcHeight = min(distance * 0.2, 80)
        let control = CGPoint(x: midpoint.x, y: midpoint.y - arcHeight)

        let startDate = Date()
        // 60 Hz timer. Main-actor; fine for a single animated element.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let rawT = min(1.0, Date().timeIntervalSince(startDate) / duration)
            let t = smoothstep(rawT)

            position = quadraticBezier(t: t, start: start, control: control, end: end)
            let tangent = bezierTangent(t: t, start: start, control: control, end: end)
            rotation = atan2(tangent.y, tangent.x) + .pi / 2  // triangle "nose" points +y locally
            scale = 1 + 0.3 * sin(rawT * .pi)

            if rawT >= 1.0 {
                timer.invalidate()
                animationTimer = nil
                onComplete()
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Math helpers

    private func flightDuration(from a: CGPoint, to b: CGPoint) -> TimeInterval {
        let d = hypot(b.x - a.x, b.y - a.y)
        return min(max(TimeInterval(d / 800), 0.6), 1.4)
    }

    private func smoothstep(_ t: Double) -> Double {
        // Hermite: 3t² − 2t³. Zero-velocity endpoints, constant-velocity mid.
        return t * t * (3 - 2 * t)
    }

    private func quadraticBezier(t: Double, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
            y: u*u*start.y + 2*u*t*control.y + t*t*end.y
        )
    }

    private func bezierTangent(t: Double, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        // B'(t) = 2(1−t)(P1−P0) + 2t(P2−P1)
        let u = 1 - t
        return CGPoint(
            x: 2*u*(control.x - start.x) + 2*t*(end.x - control.x),
            y: 2*u*(control.y - start.y) + 2*t*(end.y - control.y)
        )
    }

    // MARK: - Coordinate conversion

    /// AppKit global (bottom-left origin) → SwiftUI view-local (top-left origin).
    /// Subtracts the screenFrame origin then flips the Y-axis relative to
    /// the screen height. This view is positioned at the full
    /// screen frame inside an NSHostingView, so local coords are relative
    /// to that frame.
    private func convertGlobalToView(_ globalPoint: CGPoint) -> CGPoint {
        let localX = globalPoint.x - screenFrame.origin.x
        let localY = screenFrame.height - (globalPoint.y - screenFrame.origin.y)
        return CGPoint(x: localX, y: localY)
    }
}

// MARK: - Triangle shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}
