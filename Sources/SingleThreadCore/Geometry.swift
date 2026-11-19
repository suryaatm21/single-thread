import CoreGraphics

/// Conversions between the two global coordinate spaces macOS uses.
///
/// - CoreGraphics / Accessibility space: origin at the top-left corner of the
///   primary display (the one with the menu bar), y grows downward. Window
///   bounds from `CGWindowListCopyWindowInfo` and AX positions use this.
/// - AppKit space: origin at the bottom-left corner of the primary display,
///   y grows upward. `NSWindow` frames and `NSScreen` frames use this.
///
/// Both spaces share the x axis, and every display is placed relative to the
/// primary one, so a single flip around the primary display's height converts
/// rects on any display, including displays above, below, or left of it.
public enum ScreenGeometry {
    /// Converts a CoreGraphics-space rect to an AppKit-space rect.
    public static func appKitRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts an AppKit-space rect to a CoreGraphics-space rect.
    /// The flip is its own inverse.
    public static func cgRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        appKitRect(fromCG: rect, primaryScreenHeight: primaryScreenHeight)
    }

    /// Index of the display whose frame overlaps `rect` the most, or nil when
    /// the rect is entirely off-screen. Frames must be in the same space as `rect`.
    public static func displayIndex(containingMostOf rect: CGRect, displayFrames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in displayFrames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area {
                best = (index, area)
            }
        }
        return best?.index
    }

    /// True when two rects are equal within `tolerance` points on every edge.
    /// AX and CoreGraphics can disagree by fractions of a point.
    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
