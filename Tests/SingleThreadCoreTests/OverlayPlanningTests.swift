import CoreGraphics
import Foundation
import Testing
@testable import SingleThreadCore

@Suite("Focus, labels and overlay planning")
struct OverlayPlanningTests {
    static func window(_ id: UInt32, pid: Int32, bundle: String = "com.apple.Terminal", app: String = "Terminal",
                       title: String? = nil, doc: String? = nil, size: CGSize = CGSize(width: 800, height: 600)) -> WindowInfo {
        WindowInfo(id: id, pid: pid, bundleID: bundle, appName: app, title: title, documentPath: doc,
                   frame: CGRect(origin: CGPoint(x: Int(id) * 10, y: 50), size: size))
    }

    static func session(_ id: String, activity: AgentActivity, cwd: String = "/w/api", tool: String? = nil) -> AgentSession {
        AgentSession(sessionID: id, agent: .claudeCode, event: "x", activity: activity, cwd: cwd,
                     toolName: tool, updatedAt: Date(timeIntervalSince1970: 1))
    }

    // MARK: Focus

    @Test("The frontmost window of the active app stays clear")
    func focusFrontmost() {
        let windows = [Self.window(5, pid: 2), Self.window(7, pid: 1), Self.window(9, pid: 1)]
        #expect(FocusResolver.clearWindowID(frontToBack: windows, frontmostPID: 1, previousClear: 5, keepLastAgentWindowClear: true) == 7)
    }

    @Test("With another app in front, the last agent window stays clear if asked")
    func focusKeepLast() {
        let windows = [Self.window(5, pid: 2), Self.window(7, pid: 1)]
        #expect(FocusResolver.clearWindowID(frontToBack: windows, frontmostPID: 99, previousClear: 7, keepLastAgentWindowClear: true) == 7)
        #expect(FocusResolver.clearWindowID(frontToBack: windows, frontmostPID: 99, previousClear: 7, keepLastAgentWindowClear: false) == nil)
        // A previous window that has since closed is not kept.
        #expect(FocusResolver.clearWindowID(frontToBack: windows, frontmostPID: 99, previousClear: 42, keepLastAgentWindowClear: true) == nil)
    }

    @Test("The clear window counts as looked at only while its app is frontmost")
    func lookedAt() {
        let windows = [Self.window(5, pid: 2), Self.window(7, pid: 1)]
        #expect(FocusResolver.lookedAtWindowID(clearWindowID: 7, frontToBack: windows, frontmostPID: 1) == 7)
        // Kept clear while a browser (pid 99) has focus: not looked at.
        #expect(FocusResolver.lookedAtWindowID(clearWindowID: 7, frontToBack: windows, frontmostPID: 99) == nil)
        #expect(FocusResolver.lookedAtWindowID(clearWindowID: nil, frontToBack: windows, frontmostPID: 1) == nil)
        #expect(FocusResolver.lookedAtWindowID(clearWindowID: 7, frontToBack: windows, frontmostPID: nil) == nil)
    }

    @Test("A turn that finishes while you are in the browser is flagged on the kept-clear window")
    func keptClearWindowGetsFlagged() {
        let terminal = Self.window(7, pid: 1)
        let browserPID: Int32 = 99
        let clear = FocusResolver.clearWindowID(frontToBack: [terminal], frontmostPID: browserPID,
                                                previousClear: 7, keepLastAgentWindowClear: true)
        #expect(clear == 7)
        let lookedAt = FocusResolver.lookedAtWindowID(clearWindowID: clear, frontToBack: [terminal], frontmostPID: browserPID)
        let finished = Self.session("s", activity: .finished)
        var tracker = AttentionTracker()
        let flagged = tracker.update(sessions: [finished], focusedSessionIDs: lookedAt == 7 ? [finished.id] : [])
        #expect(flagged == [finished.id])

        let specs = OverlayPlanner.plan(windows: [terminal], clearWindowID: clear, preferences: Preferences(),
                                        sessionsByWindow: [7: finished], attentionSessionIDs: flagged)
        // Border only: the window stays readable.
        #expect(specs == [OverlaySpec(windowID: 7, frame: terminal.frame, style: .borderOnly, label: nil, needsAttention: true)])
    }

    // MARK: Planning

    @Test("Every supported window except the clear one gets an overlay")
    func planCoversUnfocused() {
        let windows = [
            Self.window(1, pid: 1),
            Self.window(2, pid: 1),
            Self.window(3, pid: 2, bundle: "com.google.Chrome", app: "Chrome"),
            Self.window(4, pid: 3, size: CGSize(width: 60, height: 40)),
        ]
        let specs = OverlayPlanner.plan(windows: windows, clearWindowID: 1, preferences: Preferences(),
                                        sessionsByWindow: [:], attentionSessionIDs: [])
        #expect(specs.map(\.windowID) == [2])
        #expect(specs.first?.frame == windows[1].frame)
    }

    @Test("Turning the overlay off removes every overlay")
    func planDisabled() {
        var prefs = Preferences()
        prefs.enabled = false
        let specs = OverlayPlanner.plan(windows: [Self.window(1, pid: 1), Self.window(2, pid: 1)], clearWindowID: 1,
                                        preferences: prefs, sessionsByWindow: [:], attentionSessionIDs: [])
        #expect(specs.isEmpty)
    }

    @Test("Labels follow the mode, but a needs-you flag shows in every mode", arguments: OverlayMode.allCases)
    func planLabels(mode: OverlayMode) {
        var prefs = Preferences()
        prefs.mode = mode
        let windows = [Self.window(1, pid: 1), Self.window(2, pid: 1), Self.window(3, pid: 1)]
        let waiting = Self.session("w", activity: .finished)
        let specs = OverlayPlanner.plan(windows: windows, clearWindowID: 1, preferences: prefs,
                                        sessionsByWindow: [3: waiting], attentionSessionIDs: [waiting.id])
        let plain = specs.first { $0.windowID == 2 }
        let flagged = specs.first { $0.windowID == 3 }
        #expect(plain?.style == mode.style)
        #expect((plain?.label != nil) == mode.style.showLabel)
        #expect(flagged?.needsAttention == true)
        #expect(flagged?.label?.status == "Needs you · turn finished")
    }

    // MARK: Labels

    @Test("Window titles are cleaned of spinners, sizes and shell names", arguments: [
        ("✳ Fix flaky test — api-server — claude — 120×40", "Terminal", "Fix flaky test — api-server"),
        ("user — -zsh — 80x24", "Terminal", "user"),
        ("main.swift - web-app - Visual Studio Code", "Visual Studio Code", "main.swift — web-app"),
        ("Claude", "Claude", nil),
        ("", "Terminal", nil),
    ] as [(String, String, String?)])
    func cleanTitles(raw: String, app: String, expected: String?) {
        #expect(LabelFormatter.cleanTitle(raw, appName: app) == expected)
    }

    @Test("Label uses the session's project name and agent status")
    func labelWithSession() {
        let window = Self.window(1, pid: 1, title: "✳ Refactor matcher — claude — 100×30")
        let label = LabelFormatter.label(for: window, session: Self.session("s", activity: .working, cwd: "/w/api-server"),
                                         needsAttention: false)
        #expect(label.title == "api-server")
        #expect(label.subtitle == "Terminal · Refactor matcher")
        #expect(label.status == "Claude Code · working")
    }

    @Test("Without a session the label falls back to directory, then title, then app")
    func labelFallbacks() {
        let withDoc = Self.window(1, pid: 1, title: "zsh", doc: "file:///w/web-app/")
        #expect(LabelFormatter.label(for: withDoc, session: nil, needsAttention: false).title == "web-app")
        let titled = Self.window(2, pid: 1, title: "✶ Build release")
        #expect(LabelFormatter.label(for: titled, session: nil, needsAttention: false).title == "Build release")
        let bare = Self.window(3, pid: 1, bundle: "com.anthropic.claudefordesktop", app: "Claude", title: "Claude")
        let label = LabelFormatter.label(for: bare, session: nil, needsAttention: false)
        #expect(label.title == "Claude")
        #expect(label.subtitle == nil)
        #expect(label.status == nil)
    }

    @Test("Long titles are truncated")
    func truncation() {
        let long = String(repeating: "a", count: 200)
        let cleaned = LabelFormatter.cleanTitle(long, appName: "Terminal")
        #expect(cleaned?.count == LabelFormatter.maxLength)
        #expect(cleaned?.hasSuffix("…") == true)
    }

    // MARK: Attention

    @Test("A waiting session is flagged until its window is focused")
    func attentionAcknowledge() {
        var tracker = AttentionTracker()
        let waiting = Self.session("a", activity: .needsPermission)
        #expect(tracker.update(sessions: [waiting], focusedSessionIDs: []) == [waiting.id])
        // The developer looks at it.
        #expect(tracker.update(sessions: [waiting], focusedSessionIDs: [waiting.id]).isEmpty)
        // They move on without answering: still acknowledged.
        #expect(tracker.update(sessions: [waiting], focusedSessionIDs: []).isEmpty)
    }

    @Test("A new kind of wait flags the session again")
    func attentionNewState() {
        var tracker = AttentionTracker()
        var session = Self.session("a", activity: .needsPermission)
        _ = tracker.update(sessions: [session], focusedSessionIDs: [session.id])
        session.activity = .finished
        #expect(tracker.update(sessions: [session], focusedSessionIDs: []) == [session.id])
    }

    @Test("Going back to work resets the acknowledgement")
    func attentionWorkingResets() {
        var tracker = AttentionTracker()
        var session = Self.session("a", activity: .finished)
        _ = tracker.update(sessions: [session], focusedSessionIDs: [session.id])
        session.activity = .working
        #expect(tracker.update(sessions: [session], focusedSessionIDs: []).isEmpty)
        session.activity = .finished
        #expect(tracker.update(sessions: [session], focusedSessionIDs: []) == [session.id])
    }

    @Test("Working and ready sessions are never flagged")
    func attentionQuiet() {
        var tracker = AttentionTracker()
        let sessions = [Self.session("a", activity: .working), Self.session("b", activity: .ready)]
        #expect(tracker.update(sessions: sessions, focusedSessionIDs: []).isEmpty)
    }
}
