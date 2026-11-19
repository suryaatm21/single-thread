import AppKit
import SingleThreadCore

/// Keeps one overlay window per planned spec, positioned and stacked directly
/// above its target window.
final class OverlayController {
    private var overlays: [UInt32: OverlayWindow] = [:]
    /// Consecutive passes in which an overlay was missing from the screen.
    private var misses: [UInt32: Int] = [:]

    var count: Int { overlays.count }

    /// One-line state of each overlay, for the debug log.
    var debugDescription: String {
        overlays.sorted { $0.key < $1.key }.map { id, w in
            "\(id)->\(w.windowNumber)(visible=\(w.isVisible) activeSpace=\(w.isOnActiveSpace) alpha=\(w.alphaValue))"
        }.joined(separator: " ")
    }

    /// - Parameters:
    ///   - specs: overlays that should exist now.
    ///   - zOrder: every normal-level on-screen window ID, front to back, from
    ///     the same scan; used to detect overlays that slipped out of place.
    func apply(_ specs: [OverlaySpec], zOrder: [UInt32]) {
        let wanted = Set(specs.map(\.windowID))
        for (id, _) in overlays where !wanted.contains(id) {
            discard(id)
        }

        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        var position: [UInt32: Int] = [:]
        for (index, id) in zOrder.enumerated() { position[id] = index }

        for spec in specs {
            // An overlay ordered in while its target app was still launching
            // can end up "visible" to AppKit yet absent from the screen, and
            // re-ordering does not bring it back. Replace it after a few misses.
            if let existing = overlays[spec.windowID], position[spec.windowID] != nil {
                if position[UInt32(existing.windowNumber)] == nil {
                    misses[spec.windowID, default: 0] += 1
                    if misses[spec.windowID]! >= 3 { discard(spec.windowID) }
                } else {
                    misses[spec.windowID] = nil
                }
            }
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

    private func discard(_ id: UInt32) {
        overlays[id]?.orderOut(nil)
        overlays[id]?.close()
        overlays[id] = nil
        misses[id] = nil
    }
}
