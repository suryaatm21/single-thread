import AppKit
import CoreGraphics

/// One line of the menu's Permissions section.
struct PermissionStatus {
    enum Action: String {
        case requestAccessibility
        case openAccessibilitySettings

        func perform() {
            switch self {
            case .requestAccessibility:
                AX.requestTrust()
            case .openAccessibilitySettings:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    var menuText: String
    var action: Action?

    /// What works and what is missing right now. The app never changes
    /// settings itself; it only opens the system prompt or pane on request.
    static func current() -> [PermissionStatus] {
        var lines: [PermissionStatus] = []
        if AX.isTrusted {
            lines.append(PermissionStatus(menuText: "Accessibility: granted", action: nil))
        } else {
            lines.append(PermissionStatus(
                menuText: "Accessibility: not granted. Overlays still work; titles and session matching are off. Grant…",
                action: .requestAccessibility
            ))
            lines.append(PermissionStatus(menuText: "Open Accessibility settings…", action: .openAccessibilitySettings))
        }
        lines.append(PermissionStatus(
            menuText: CGPreflightScreenCaptureAccess()
                ? "Screen Recording: granted (not required)"
                : "Screen Recording: not required",
            action: nil
        ))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            lines.append(PermissionStatus(
                menuText: "Reduce Transparency is on: blur shows as a solid tint",
                action: nil
            ))
        }
        return lines
    }

    /// Plain-text report for the `status` command.
    static func report() -> String {
        current().map(\.menuText).joined(separator: "\n")
    }
}
