import Foundation
import Testing
@testable import SingleThreadCore

@Suite("Session state files")
struct SessionStateTests {
    static func file(
        agent: String = "claude-code",
        event: String,
        ts: Double = 1_800_000_000,
        sessionID: String = "s-1",
        cwd: String = "/work/api-server",
        tty: String = "ttys003",
        pid: Int = 4242,
        host: String = "com.apple.Terminal",
        tmux: Bool = false,
        notificationType: String = "",
        tool: String = "",
        message: String = ""
    ) -> Data {
        let object: [String: Any] = [
            "v": 1, "agent": agent, "event": event, "ts": ts, "session_id": sessionID, "cwd": cwd,
            "tty": tty, "pid": pid, "host_bundle_id": host, "term_program": "Apple_Terminal", "tmux": tmux,
            "notification_type": notificationType, "tool_name": tool, "message": message,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("A full state file parses into a session")
    func parsesFullFile() throws {
        let session = try #require(try SessionStateParser.parse(Self.file(event: "PermissionRequest", tool: "Bash")))
        #expect(session.id == "claude-code:s-1")
        #expect(session.agent == .claudeCode)
        #expect(session.activity == .needsPermission)
        #expect(session.statusText == "needs permission: Bash")
        #expect(session.cwdName == "api-server")
        #expect(session.tty == "ttys003")
        #expect(session.pid == 4242)
        #expect(session.hostBundleID == "com.apple.Terminal")
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Claude Code events map to activities", arguments: [
        ("SessionStart", "", "", AgentActivity.ready),
        ("UserPromptSubmit", "", "", .working),
        ("PostToolUse", "", "Bash", .working),
        ("PermissionRequest", "", "Edit", .needsPermission),
        ("PermissionRequest", "", "ExitPlanMode", .planReview),
        ("PreToolUse", "", "ExitPlanMode", .planReview),
        ("PreToolUse", "", "AskUserQuestion", .needsAnswer),
        ("PreToolUse", "", "Bash", .working),
        ("Notification", "permission_prompt", "", .needsPermission),
        ("Notification", "elicitation_dialog", "", .needsAnswer),
        ("Notification", "idle_prompt", "", .finished),
        ("Stop", "", "", .finished),
    ])
    func claudeEvents(event: String, notification: String, tool: String, expected: AgentActivity) throws {
        let session = try SessionStateParser.parse(Self.file(event: event, notificationType: notification, tool: tool))
        #expect(session?.activity == expected)
    }

    @Test("Copilot CLI event spellings map too", arguments: [
        ("sessionStart", "", AgentActivity.ready),
        ("userPromptSubmitted", "", .working),
        ("postToolUse", "", .working),
        ("notification", "permission_prompt", .needsPermission),
        ("notification", "elicitation_dialog", .needsAnswer),
        ("agentStop", "", .finished),
    ])
    func copilotEvents(event: String, notification: String, expected: AgentActivity) throws {
        let session = try SessionStateParser.parse(Self.file(agent: "copilot-cli", event: event, notificationType: notification))
        #expect(session?.agent == .copilotCLI)
        #expect(session?.activity == expected)
    }

    @Test("Notifications that are not about the user are ignored")
    func ignoredNotifications() throws {
        #expect(try SessionStateParser.parse(Self.file(event: "Notification", notificationType: "auth_success")) == nil)
        #expect(try SessionStateParser.parse(Self.file(event: "notification", notificationType: "shell_completed")) == nil)
        #expect(try SessionStateParser.parse(Self.file(event: "SomethingNew")) == nil)
    }

    @Test("Needs-input covers permission, question, plan and finished turn")
    func needsInput() {
        let needs: [AgentActivity] = [.needsPermission, .needsAnswer, .planReview, .finished]
        let not: [AgentActivity] = [.ready, .working, .ended]
        #expect(needs.allSatisfy { $0.needsInput })
        #expect(!not.contains { $0.needsInput })
    }

    @Test("Malformed files throw instead of producing a session")
    func malformed() {
        #expect(throws: SessionStateParser.ParseError.invalidJSON) {
            try SessionStateParser.parse(Data("{not json".utf8))
        }
        #expect(throws: SessionStateParser.ParseError.missingField("session_id")) {
            try SessionStateParser.parse(Data(#"{"v":1,"event":"Stop","ts":1}"#.utf8))
        }
        #expect(throws: SessionStateParser.ParseError.unsupportedVersion(2)) {
            try SessionStateParser.parse(Data(#"{"v":2,"session_id":"a","event":"Stop","ts":1}"#.utf8))
        }
    }

    @Test("tty values are normalized")
    func ttyNormalization() {
        #expect(SessionStateParser.normalizeTTY("/dev/ttys012") == "ttys012")
        #expect(SessionStateParser.normalizeTTY("ttys012") == "ttys012")
        #expect(SessionStateParser.normalizeTTY("??") == nil)
        #expect(SessionStateParser.normalizeTTY("") == nil)
        #expect(SessionStateParser.normalizeTTY(nil) == nil)
    }

    @Test("Loader drops dead, stale, ended and duplicate sessions")
    func loader() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = [
            Self.file(event: "Stop", ts: 1_800_000_000 - 10, sessionID: "alive", pid: 100),
            Self.file(event: "Stop", ts: 1_800_000_000 - 10, sessionID: "dead", pid: 200),
            Self.file(event: "Stop", ts: 1_800_000_000 - 20 * 3600, sessionID: "stale-no-pid", pid: 0),
            Self.file(event: "Stop", ts: 1_800_000_000 - 60, sessionID: "fresh-no-pid", pid: 0),
            Self.file(event: "UserPromptSubmit", ts: 1_800_000_000 - 30, sessionID: "alive", pid: 100),
            Data("garbage".utf8),
        ]
        let sessions = SessionStateLoader.sessions(from: files, now: now, isAlive: { $0 == 100 })
        #expect(sessions.map(\.sessionID) == ["alive", "fresh-no-pid"])
        // The newer of the two "alive" files wins.
        #expect(sessions.first?.activity == .finished)
    }

    @Test("Loader ignores sessions with an ended marker")
    func loaderEndedMarker() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = [
            Self.file(event: "Notification", ts: 1_800_000_000 - 5, sessionID: "gone", pid: 0),
            Self.file(event: "Stop", ts: 1_800_000_000 - 5, sessionID: "kept", pid: 0),
        ]
        let sessions = SessionStateLoader.sessions(from: files, now: now, endedSessionIDs: ["gone"], isAlive: { _ in true })
        #expect(sessions.map(\.sessionID) == ["kept"])
    }

    @Test("State directory honours the environment override")
    func stateDirectory() {
        let custom = StatePaths.sessionsDirectory(environment: ["SINGLE_THREAD_STATE_DIR": "/tmp/st"], homeDirectory: "/Users/x")
        #expect(custom.path == "/tmp/st")
        let standard = StatePaths.sessionsDirectory(environment: [:], homeDirectory: "/Users/x")
        #expect(standard.path == "/Users/x/Library/Application Support/single-thread/sessions")
    }
}
