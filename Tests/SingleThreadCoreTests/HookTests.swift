import Foundation
import Testing
@testable import SingleThreadCore

@Suite("Hook configuration")
struct HookConfigTests {
    let script = "/opt/single thread/hooks/single-thread-hook"

    @Test("Commands quote the script path for the shell")
    func quoting() {
        #expect(HookConfig.shellQuote("/a b/c") == "'/a b/c'")
        #expect(HookConfig.shellQuote("it's") == #"'it'\''s'"#)
        #expect(HookConfig.command(scriptPath: script, agent: "claude-code", event: "Stop")
            == "'/opt/single thread/hooks/single-thread-hook' claude-code Stop")
    }

    @Test("Claude hooks cover every needs-input event")
    func claudeHooks() throws {
        let hooks = HookConfig.claudeHooks(scriptPath: script)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                      "Notification", "Stop", "SessionEnd"] {
            #expect(hooks[event] != nil, "missing \(event)")
        }
        let pre = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(pre["matcher"] as? String == "AskUserQuestion|ExitPlanMode")
        let handler = try #require((pre["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        #expect((handler["command"] as? String)?.hasSuffix("claude-code PreToolUse") == true)
    }

    @Test("Merging keeps unrelated settings and other hooks, and is idempotent")
    func mergeIdempotent() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
            ],
        ]
        let once = HookConfig.mergeClaudeHooks(into: existing, scriptPath: script)
        let twice = HookConfig.mergeClaudeHooks(into: once, scriptPath: script)
        #expect(once["model"] as? String == "opus")
        let stopGroups = try #require((twice["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 2)
        let commands = stopGroups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.contains("say done"))
        #expect(commands.filter { $0.contains(HookConfig.marker) }.count == 1)
        #expect(try HookConfig.jsonData(once) == HookConfig.jsonData(twice))
    }

    @Test("Removing takes out only our hooks")
    func remove() throws {
        let existing: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let merged = HookConfig.mergeClaudeHooks(into: existing, scriptPath: script)
        let removed = HookConfig.removeClaudeHooks(from: merged)
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["Stop"])
        #expect(try HookConfig.jsonData(removed) == HookConfig.jsonData(existing))
        // Removing from settings that only had our hooks drops the key entirely.
        let ours = HookConfig.mergeClaudeHooks(into: [:], scriptPath: script)
        #expect(HookConfig.removeClaudeHooks(from: ours).isEmpty)
    }

    @Test("Copilot hooks file uses the documented shape")
    func copilotFile() throws {
        let file = HookConfig.copilotHooksFile(scriptPath: script)
        #expect(file["version"] as? Int == 1)
        let hooks = try #require(file["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookConfig.copilotEvents))
        let stop = try #require((hooks["agentStop"] as? [[String: Any]])?.first)
        #expect(stop["type"] as? String == "command")
        #expect((stop["bash"] as? String)?.hasSuffix("copilot-cli agentStop") == true)
        #expect(stop["timeoutSec"] as? Int == HookConfig.timeoutSeconds)
    }
}

/// Runs the real hook script with sample payloads and parses what it writes.
@Suite("Hook script end to end")
struct HookScriptTests {
    static let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/single-thread-hook")

    struct Run {
        var stdout: String
        var status: Int32
        var files: [URL]
    }

    func runHook(args: [String], payload: String, stateDir: URL, extraEnv: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.scriptURL.path] + args
        var env = ProcessInfo.processInfo.environment
        env["SINGLE_THREAD_STATE_DIR"] = stateDir.path
        env["COPILOT_HOOK_DEPTH"] = nil
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let files = (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil)) ?? []
        return Run(stdout: stdout, status: process.terminationStatus, files: files)
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("st-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A permission request is recorded, silently, under a safe file name")
    func permissionRequest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = #"{"session_id":"abc/../1 2","cwd":"/w/my \"quoted\" proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        let run = try runHook(args: ["claude-code", "PermissionRequest"], payload: payload, stateDir: dir)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.files.map(\.lastPathComponent) == ["claude-code-abc..12.json"])
        let data = try Data(contentsOf: try #require(run.files.first))
        let session = try #require(try SessionStateParser.parse(data))
        #expect(session.sessionID == "abc/../1 2")
        #expect(session.cwd == #"/w/my "quoted" proj"#)
        #expect(session.activity == .needsPermission)
        #expect(session.toolName == "Bash")
        // The tool input (the command) is not stored.
        #expect(!String(decoding: data, as: UTF8.self).contains("rm -rf"))
    }

    @Test("Irrelevant notifications leave the previous state alone")
    func ignoredNotification() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runHook(args: ["claude-code", "Stop"], payload: #"{"session_id":"s1","cwd":"/w"}"#, stateDir: dir)
        _ = try runHook(args: ["claude-code", "Notification"],
                        payload: #"{"session_id":"s1","notification_type":"auth_success","message":"hi"}"#, stateDir: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("claude-code-s1.json"))
        #expect(try SessionStateParser.parse(data)?.activity == .finished)
    }

    @Test("Session end deletes the state file")
    func sessionEnd() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runHook(args: ["claude-code", "SessionStart"], payload: #"{"session_id":"s1"}"#, stateDir: dir)
        let run = try runHook(args: ["claude-code", "SessionEnd"], payload: #"{"session_id":"s1","reason":"other"}"#, stateDir: dir)
        #expect(run.files.isEmpty)
    }

    @Test("Copilot payloads (camelCase) and its hook environment are recognised")
    func copilot() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = try runHook(args: ["claude-code", "notification"],
                              payload: #"{"sessionId":"cp-9","cwd":"/w/app","notification_type":"elicitation_dialog","message":"Pick one"}"#,
                              stateDir: dir, extraEnv: ["COPILOT_HOOK_DEPTH": "1"])
        let file = try #require(run.files.first)
        #expect(file.lastPathComponent == "copilot-cli-cp-9.json")
        let session = try #require(try SessionStateParser.parse(Data(contentsOf: file)))
        #expect(session.agent == .copilotCLI)
        #expect(session.activity == .needsAnswer)
        #expect(session.message == "Pick one")
    }

    @Test("Empty or id-less payloads write nothing")
    func emptyPayload() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try runHook(args: ["claude-code", "Stop"], payload: "", stateDir: dir).files.isEmpty)
        #expect(try runHook(args: ["claude-code", "Stop"], payload: #"{"cwd":"/w"}"#, stateDir: dir).files.isEmpty)
    }
}
