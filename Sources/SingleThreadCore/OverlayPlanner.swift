import CoreGraphics

/// Decides which window stays clear.
public enum FocusResolver {
    /// - Parameters:
    ///   - windows: supported windows in front-to-back order, as CoreGraphics lists them.
    ///   - frontmostPID: PID of the active app, if any.
    ///   - previousClear: the window left clear on the last pass.
    /// - Returns: the window to leave clear, or nil to cover every window.
    ///
    /// The focused window of the active app is the frontmost of its windows,
    /// so window order alone finds it, with or without Accessibility access.
    public static func clearWindowID(
        frontToBack windows: [WindowInfo],
        frontmostPID: Int32?,
        previousClear: UInt32?,
        keepLastAgentWindowClear: Bool
    ) -> UInt32? {
        if let frontmostPID, let focused = windows.first(where: { $0.pid == frontmostPID }) {
            return focused.id
        }
        if keepLastAgentWindowClear, let previousClear, windows.contains(where: { $0.id == previousClear }) {
            return previousClear
        }
        return nil
    }

    /// The window the developer is looking at: the clear window, but only
    /// while its app is frontmost. A window kept clear while a browser has
    /// focus is not being looked at, so its agent can still be flagged.
    public static func lookedAtWindowID(
        clearWindowID: UInt32?,
        frontToBack windows: [WindowInfo],
        frontmostPID: Int32?
    ) -> UInt32? {
        guard let clearWindowID, let frontmostPID,
              let window = windows.first(where: { $0.id == clearWindowID }),
              window.pid == frontmostPID
        else { return nil }
        return clearWindowID
    }
}

/// Everything needed to draw one overlay.
public struct OverlaySpec: Equatable, Sendable {
    public var windowID: UInt32
    /// Frame in CoreGraphics global space; the app converts it for AppKit.
    public var frame: CGRect
    public var style: OverlayStyle
    public var label: OverlayLabel?
    public var needsAttention: Bool

    public init(windowID: UInt32, frame: CGRect, style: OverlayStyle, label: OverlayLabel?, needsAttention: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.style = style
        self.label = label
        self.needsAttention = needsAttention
    }
}

public enum OverlayPlanner {
    /// Windows smaller than this are palettes or popovers, not sessions.
    public static let minimumWindowSize = CGSize(width: 120, height: 80)

    public static func plan(
        windows: [WindowInfo],
        clearWindowID: UInt32?,
        preferences: Preferences,
        sessionsByWindow: [UInt32: AgentSession],
        attentionSessionIDs: Set<String>
    ) -> [OverlaySpec] {
        guard preferences.enabled else { return [] }
        let style = preferences.mode.style
        return windows.compactMap { window in
            guard preferences.isSupported(bundleID: window.bundleID),
                  window.frame.width >= minimumWindowSize.width,
                  window.frame.height >= minimumWindowSize.height
            else { return nil }
            let session = sessionsByWindow[window.id]
            let attention = session.map { attentionSessionIDs.contains($0.id) } ?? false
            if window.id == clearWindowID {
                // The clear window stays readable. It only gets the amber
                // border, when its agent needs you while you are in another app.
                guard attention else { return nil }
                return OverlaySpec(windowID: window.id, frame: window.frame, style: .borderOnly, label: nil, needsAttention: true)
            }
            // The needs-you flag shows in every mode; otherwise the label follows the mode.
            let label = (style.showLabel || attention)
                ? LabelFormatter.label(for: window, session: session, needsAttention: attention)
                : nil
            return OverlaySpec(windowID: window.id, frame: window.frame, style: style, label: label, needsAttention: attention)
        }
    }
}

/// Tracks which sessions should be flagged as needing the developer.
///
/// A session is flagged while its agent needs input and nobody has looked at
/// it yet. Focusing its window counts as looking; the flag then stays off
/// until the agent's state changes again.
///
/// The tracker remembers which wait you looked at by its activity and the
/// hook's `wait` number, so a new wait of the same kind is flagged even when
/// the app never read the working state in between.
public struct AttentionTracker: Sendable {
    public struct Acknowledgement: Equatable, Sendable {
        public var activity: AgentActivity
        public var wait: Int?
    }

    public private(set) var acknowledged: [String: Acknowledgement] = [:]

    public init() {}

    /// - Parameter focusedSessionIDs: sessions whose window the developer is
    ///   looking at (see `FocusResolver.lookedAtWindowID`).
    /// - Returns: IDs of sessions to flag.
    public mutating func update(sessions: [AgentSession], focusedSessionIDs: Set<String>) -> Set<String> {
        var flagged = Set<String>()
        for session in sessions {
            if !session.activity.needsInput {
                acknowledged[session.id] = nil
            } else if focusedSessionIDs.contains(session.id) {
                acknowledged[session.id] = Acknowledgement(activity: session.activity, wait: session.wait)
            } else if acknowledged[session.id] != Acknowledgement(activity: session.activity, wait: session.wait) {
                flagged.insert(session.id)
            }
        }
        let live = Set(sessions.map(\.id))
        acknowledged = acknowledged.filter { live.contains($0.key) }
        return flagged
    }
}
