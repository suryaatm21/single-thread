import Foundation

/// The text drawn in the middle of an overlay.
public struct OverlayLabel: Equatable, Sendable {
    /// Large line: the session name.
    public var title: String
    /// Small line under it: app name and the window title.
    public var subtitle: String?
    /// Agent status, e.g. "Claude Code · working" or "Needs you · turn finished".
    public var status: String?

    public init(title: String, subtitle: String? = nil, status: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }
}

public enum LabelFormatter {
    static let maxLength = 60

    /// Window-title components that carry no session identity.
    static let noiseComponents: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "login", "node", "tmux",
        "terminal", "iterm2", "ghostty", "warp", "visual studio code", "code", "claude",
    ]

    /// Cleans a raw window title into something worth showing, or nil when
    /// nothing meaningful is left.
    ///
    /// "✳ Fix flaky test — api-server — claude — 120×40" → "Fix flaky test — api-server"
    public static func cleanTitle(_ raw: String?, appName: String) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let separators = [" — ", " – ", " - "]
        var parts = [raw]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let app = appName.lowercased()
        let kept = parts
            .map(stripLeadingDecoration)
            .filter { part in
                guard !part.isEmpty else { return false }
                let lower = part.lowercased()
                if lower == app || noiseComponents.contains(lower) { return false }
                if isDimensions(part) { return false }
                return true
            }
        guard !kept.isEmpty else { return nil }
        return truncate(kept.joined(separator: " — "))
    }

    /// Builds the overlay label for a window and the session matched to it.
    public static func label(for window: WindowInfo, session: AgentSession?, needsAttention: Bool) -> OverlayLabel {
        let cleaned = cleanTitle(window.title, appName: window.appName)
        let documentName = window.documentPath
            .map(SessionMatcher.normalizePath)
            .map { ($0 as NSString).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }

        let title = truncate(session?.cwdName ?? documentName ?? cleaned ?? window.appName)

        var subtitleParts = [window.appName]
        if let cleaned, cleaned != title { subtitleParts.append(cleaned) }
        let subtitle = subtitleParts.joined(separator: " · ")

        var status: String?
        if let session {
            status = needsAttention
                ? "Needs you · \(session.statusText)"
                : "\(session.agent.displayName) · \(session.statusText)"
        }
        return OverlayLabel(title: title, subtitle: subtitle == title ? nil : subtitle, status: status)
    }

    /// Drops spinner glyphs, bullets, and whitespace that agents prefix titles with.
    static func stripLeadingDecoration(_ text: String) -> String {
        var scalars = Substring.UnicodeScalarView(text.unicodeScalars)
        while let first = scalars.first {
            let keep = CharacterSet.alphanumerics.contains(first)
                || "~/.([{\"'@#".unicodeScalars.contains(first)
            if keep { break }
            scalars.removeFirst()
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    static func isDimensions(_ text: String) -> Bool {
        let pieces = text.split(whereSeparator: { $0 == "×" || $0 == "x" })
        return pieces.count == 2 && pieces.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    static func truncate(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }
}
