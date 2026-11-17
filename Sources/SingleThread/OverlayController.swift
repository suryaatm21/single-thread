import AppKit
import SingleThreadCore

/// Keeps one overlay window per planned spec, positioned and stacked directly
/// above its target window.
final class OverlayController {
    private var overlays: [UInt32: OverlayWindow] = [:]

    var count: Int { overlays.count }

    /// - Parameters:
    ///   - specs: overlays that should exist now.
    ///   - zOrder: every normal-level on-screen window ID, front to back, from
    ///     the same scan; used to detect overlays that slipped out of place.
    func apply(_ specs: [OverlaySpec], zOrder: [UInt32]) {
        let wanted = Set(specs.map(\.windowID))
        for (id, window) in overlays where !wanted.contains(id) {
            window.orderOut(nil)
            window.close()
            overlays[id] = nil
        }

        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        var position: [UInt32: Int] = [:]
        for (index, id) in zOrder.enumerated() { position[id] = index }

        for spec in specs {
            let frame = ScreenGeometry.appKitRect(fromCG: spec.frame, primaryScreenHeight: primaryHeight)
            let window: OverlayWindow
            var isNew = false
            if let existing = overlays[spec.windowID] {
                window = existing
            } else {
                window = OverlayWindow(targetID: spec.windowID)
                window.alphaValue = 0
                overlays[spec.windowID] = window
                isNew = true
            }
            window.apply(spec, appKitFrame: frame)

            // Correct when the overlay is the window immediately in front of
            // its target. Activating an app raises its windows over our
            // overlays, so this is re-checked on every pass.
            let overlayIndex = position[UInt32(window.windowNumber)]
            let targetIndex = position[spec.windowID]
            let inPlace = overlayIndex != nil && targetIndex != nil && overlayIndex! + 1 == targetIndex!
            if !inPlace || !window.isVisible {
                window.order(.above, relativeTo: Int(spec.windowID))
            }
            if isNew {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    func removeAll() {
        apply([], zOrder: [])
    }
}
