import Foundation

/// How unfocused windows are treated.
public enum OverlayMode: String, CaseIterable, Codable, Sendable {
    case dim
    case dimBlur
    case dimBlurLabel

    public var menuTitle: String {
        switch self {
        case .dim: return "Dim only"
        case .dimBlur: return "Dim + blur"
        case .dimBlurLabel: return "Dim + blur + label"
        }
    }

    /// The visual recipe for this mode.
    public var style: OverlayStyle {
        switch self {
        // Without blur, a heavier dim is the only thing pushing text back.
        case .dim: return OverlayStyle(dimAlpha: 0.55, blur: false, showLabel: false)
        case .dimBlur: return OverlayStyle(dimAlpha: 0.25, blur: true, showLabel: false)
        case .dimBlurLabel: return OverlayStyle(dimAlpha: 0.25, blur: true, showLabel: true)
        }
    }

    /// The next mode in menu order, wrapping around.
    public var next: OverlayMode {
        let all = OverlayMode.allCases
        let index = all.firstIndex(of: self)!
        return all[(index + 1) % all.count]
    }
}

public struct OverlayStyle: Equatable, Sendable {
    public var dimAlpha: Double
    public var blur: Bool
    public var showLabel: Bool

    public init(dimAlpha: Double, blur: Bool, showLabel: Bool) {
        self.dimAlpha = dimAlpha
        self.blur = blur
        self.showLabel = showLabel
    }
}

/// A terminal or agent app whose windows get overlays.
public struct SupportedApp: Equatable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public static let defaults: [SupportedApp] = [
        SupportedApp(bundleID: "com.apple.Terminal", name: "Terminal"),
        SupportedApp(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        SupportedApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        SupportedApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        SupportedApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        SupportedApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
    ]
}

/// User-facing settings. Persisted as a flat dictionary so the app can store it
/// in `UserDefaults` and users can override keys with `defaults write`.
public struct Preferences: Equatable, Sendable {
    public var enabled: Bool
    public var mode: OverlayMode
    public var supportedBundleIDs: [String]
    /// When a non-supported app (a browser, say) is frontmost, keep the most
    /// recently focused agent window clear instead of covering every window.
    public var keepLastAgentWindowClear: Bool

    public init(
        enabled: Bool = true,
        mode: OverlayMode = .dimBlurLabel,
        supportedBundleIDs: [String] = SupportedApp.defaults.map(\.bundleID),
        keepLastAgentWindowClear: Bool = true
    ) {
        self.enabled = enabled
        self.mode = mode
        self.supportedBundleIDs = supportedBundleIDs
        self.keepLastAgentWindowClear = keepLastAgentWindowClear
    }

    public enum Key {
        public static let enabled = "enabled"
        public static let mode = "mode"
        public static let supportedApps = "supportedApps"
        public static let keepLastAgentWindowClear = "keepLastAgentWindowClear"
    }

    /// Builds preferences from stored values, falling back to defaults for
    /// anything missing or malformed. `environmentApps` (a comma-separated
    /// bundle ID list, from `SINGLE_THREAD_APPS`) wins over the stored list.
    public init(stored: [String: Any], environmentApps: String? = nil) {
        let fallback = Preferences()
        enabled = stored[Key.enabled] as? Bool ?? fallback.enabled
        mode = (stored[Key.mode] as? String).flatMap(OverlayMode.init(rawValue:)) ?? fallback.mode
        keepLastAgentWindowClear = stored[Key.keepLastAgentWindowClear] as? Bool ?? fallback.keepLastAgentWindowClear

        let parsedEnv = environmentApps?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let parsedEnv, !parsedEnv.isEmpty {
            supportedBundleIDs = parsedEnv
        } else if let list = stored[Key.supportedApps] as? [String], !list.isEmpty {
            supportedBundleIDs = list
        } else {
            supportedBundleIDs = fallback.supportedBundleIDs
        }
    }

    /// The values the menu can change. The supported-app list is only written
    /// by the user (via `defaults write`), so it is not round-tripped here.
    public var storedValues: [String: Any] {
        [
            Key.enabled: enabled,
            Key.mode: mode.rawValue,
            Key.keepLastAgentWindowClear: keepLastAgentWindowClear,
        ]
    }

    public func isSupported(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supportedBundleIDs.contains(bundleID)
    }
}
