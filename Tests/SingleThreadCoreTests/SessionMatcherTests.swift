import CoreGraphics
import Foundation
import Testing
@testable import SingleThreadCore

@Suite("Session-to-window matching")
struct SessionMatcherTests {
    static let home = "/Users/dev"

    static func session(
        _ id: String,
        cwd: String? = nil,
        tty: String? = nil,
        host: String? = "com.apple.Terminal",
        tmux: Bool = false,
        age: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(
            sessionID: id, agent: .claudeCode, event: "Stop", activity: .finished,
            cwd: cwd, tty: tty, hostBundleID: host, insideTmux: tmux,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 - age)
        )
    }

    static func window(
        _ id: UInt32,
        bundle: String = "com.apple.Terminal",
        app: String = "Terminal",
        title: String? = nil,
        doc: String? = nil,
        ttys: [String] = []
    ) -> WindowInfo {
        WindowInfo(id: id, pid: 1, bundleID: bundle, appName: app, title: title, documentPath: doc,
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600), ttys: ttys)
    }

    func match(_ sessions: [AgentSession], _ windows: [WindowInfo]) -> SessionMatcher.Result {
        SessionMatcher.match(sessions: sessions, windows: windows, homeDirectory: Self.home)
    }

    @Test("Working directory reported by the terminal picks the right window")
    func documentMatch() {
        let sessions = [
            Self.session("a", cwd: "/Users/dev/code/api-server"),
            Self.session("b", cwd: "/Users/dev/code/web-app"),
        ]
        let windows = [
            Self.window(1, doc: "file:///Users/dev/code/web-app/"),
            Self.window(2, doc: "file:///Users/dev/code/api-server/"),
        ]
        let result = match(sessions, windows)
        #expect(result.sessionsByWindow[1]?.sessionID == "b")
        #expect(result.sessionsByWindow[2]?.sessionID == "a")
        #expect(result.unmatched.isEmpty)
    }

    @Test("A tty match beats everything else")
    func ttyMatch() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api-server", tty: "ttys007")]
        let windows = [
            Self.window(1, doc: "/Users/dev/code/api-server"),
            Self.window(2, ttys: ["ttys001", "ttys007"]),
        ]
        #expect(match(sessions, windows).sessionsByWindow[2]?.sessionID == "a")
    }

    @Test("Project name in the title matches as a whole word only")
    func titleWord() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api")]
        let windows = [
            Self.window(1, title: "api-server — claude — 120×40"),
            Self.window(2, title: "✳ Fix tests — api — claude"),
        ]
        let result = match(sessions, windows)
        #expect(result.sessionsByWindow[2]?.sessionID == "a")
        #expect(result.sessionsByWindow[1] == nil)
    }

    @Test("A tilde path in the title counts as the full path")
    func tildePath() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api")]
        let windows = [Self.window(1, title: "~/code/api"), Self.window(2, title: "~/code/other")]
        #expect(match(sessions, windows).sessionsByWindow[1]?.sessionID == "a")
    }

    @Test("A session never matches a window of a different launching app")
    func hostAppMismatch() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api", host: "com.googlecode.iterm2")]
        let windows = [Self.window(1, doc: "/Users/dev/code/api")]
        let result = match(sessions, windows)
        #expect(result.sessionsByWindow.isEmpty)
        #expect(result.unmatched.map(\.sessionID) == ["a"])
    }

    @Test("Inside tmux the launching app is ignored")
    func tmuxIgnoresHost() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api", host: "com.anthropic.claudefordesktop", tmux: true)]
        let windows = [Self.window(1, doc: "/Users/dev/code/api")]
        #expect(match(sessions, windows).sessionsByWindow[1]?.sessionID == "a")
    }

    @Test("The only window of the launching app is a match even without other clues")
    func onlyWindow() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api", host: "com.mitchellh.ghostty")]
        let windows = [
            Self.window(1, bundle: "com.mitchellh.ghostty", app: "Ghostty", title: "Claude Code"),
            Self.window(2, title: "zsh"),
            Self.window(3, title: "zsh"),
        ]
        #expect(match(sessions, windows).sessionsByWindow[1]?.sessionID == "a")
    }

    @Test("Two windows of the same app with no clues stay unmatched")
    func ambiguous() {
        let sessions = [Self.session("a", cwd: "/Users/dev/code/api")]
        let windows = [Self.window(1, title: "zsh"), Self.window(2, title: "zsh")]
        let result = match(sessions, windows)
        #expect(result.sessionsByWindow.isEmpty)
        #expect(result.unmatched.count == 1)
    }

    @Test("A session tied between two windows matches neither")
    func tiedWindows() {
        // The agent's window and a plain shell, both in the same project folder.
        let sessions = [Self.session("agent", cwd: "/Users/dev/code/api")]
        let windows = [
            Self.window(1, title: "zsh", doc: "/Users/dev/code/api"),
            Self.window(2, title: "zsh", doc: "/Users/dev/code/api"),
        ]
        let result = match(sessions, windows)
        #expect(result.sessionsByWindow.isEmpty)
        #expect(result.unmatched.map(\.sessionID) == ["agent"])
        // Order does not matter: the frontmost window does not win the tie.
        #expect(match(sessions, windows.reversed()).sessionsByWindow.isEmpty)
    }

    @Test("Extra evidence breaks a tie")
    func tieBroken() {
        let sessions = [Self.session("agent", cwd: "/Users/dev/code/api")]
        let windows = [
            Self.window(1, title: "zsh", doc: "/Users/dev/code/api"),
            Self.window(2, title: "✳ Fix tests — api — claude", doc: "/Users/dev/code/api"),
        ]
        #expect(match(sessions, windows).sessionsByWindow[2]?.sessionID == "agent")
    }

    @Test("Each window gets at most one session; the newest wins a tie")
    func oneToOne() {
        let sessions = [
            Self.session("old", cwd: "/Users/dev/code/api", age: 100),
            Self.session("new", cwd: "/Users/dev/code/api", age: 1),
        ]
        let windows = [Self.window(1, doc: "/Users/dev/code/api"), Self.window(2, title: "zsh")]
        let result = match(sessions, windows)
        #expect(result.sessionsByWindow[1]?.sessionID == "new")
        #expect(result.unmatched.map(\.sessionID) == ["old"])
    }

    @Test("Path helpers")
    func helpers() {
        #expect(SessionMatcher.normalizePath("file:///Users/dev/My%20Project/") == "/Users/dev/My Project")
        #expect(SessionMatcher.normalizePath("/") == "/")
        #expect(SessionMatcher.containsWord("work on api now", "api"))
        #expect(SessionMatcher.containsWord("API", "api"))
        #expect(!SessionMatcher.containsWord("api-server", "api"))
        #expect(!SessionMatcher.containsWord("rapid", "api"))
        #expect(SessionMatcher.containsWord("rapid · api", "api"))
    }
}
