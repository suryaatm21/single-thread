import Foundation

/// Parses the per-session state files written by `hooks/single-thread-hook`.
///
/// File format (version 1), one JSON object per session, rewritten atomically
/// on every hook event:
///
///     {"v":1,"agent":"claude-code","event":"PermissionRequest","ts":1794906153,
///      "session_id":"…","cwd":"/path/to/project","tty":"ttys003","pid":4242,
///      "host_bundle_id":"com.apple.Terminal","term_program":"Apple_Terminal",
///      "tmux":false,"notification_type":"","tool_name":"Bash","message":""}
public enum SessionStateParser {
    public enum ParseError: Error, Equatable {
        case invalidJSON
        case missingField(String)
        case unsupportedVersion(Int)
    }

    struct RawState: Decodable {
        var v: Int?
        var agent: String?
        var event: String?
        var ts: Double?
        var session_id: String?
        var cwd: String?
        var tty: String?
        var pid: Int32?
        var host_bundle_id: String?
        var term_program: String?
        var tmux: Bool?
        var notification_type: String?
        var tool_name: String?
        var message: String?
    }

    /// Returns the session described by `data`, or nil when the event carries
    /// no state change (for example an `auth_success` notification).
    public static func parse(_ data: Data) throws -> AgentSession? {
        let raw: RawState
        do {
            raw = try JSONDecoder().decode(RawState.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }
        if let version = raw.v, version != 1 {
            throw ParseError.unsupportedVersion(version)
        }
        guard let sessionID = raw.session_id.nonEmpty else { throw ParseError.missingField("session_id") }
        guard let event = raw.event.nonEmpty else { throw ParseError.missingField("event") }
        guard let ts = raw.ts else { throw ParseError.missingField("ts") }

        let tool = raw.tool_name.nonEmpty
        guard let activity = activity(forEvent: event, notificationType: raw.notification_type.nonEmpty, toolName: tool) else {
            return nil
        }
        return AgentSession(
            sessionID: sessionID,
            agent: AgentKind(rawValue: raw.agent ?? "") ?? .other,
            event: event,
            activity: activity,
            cwd: raw.cwd.nonEmpty,
            tty: normalizeTTY(raw.tty),
            pid: raw.pid.flatMap { $0 > 0 ? $0 : nil },
            hostBundleID: raw.host_bundle_id.nonEmpty,
            termProgram: raw.term_program.nonEmpty,
            insideTmux: raw.tmux ?? false,
            toolName: tool,
            message: raw.message.nonEmpty,
            updatedAt: Date(timeIntervalSince1970: ts)
        )
    }

    /// Maps a hook event to an activity. Event names are matched without case
    /// so Claude Code (`Stop`) and Copilot CLI (`agentStop`) spellings both work.
    /// Returns nil for events that say nothing about whether the agent needs you.
    public static func activity(forEvent event: String, notificationType: String?, toolName: String?) -> AgentActivity? {
        switch event.lowercased() {
        case "sessionstart":
            return .ready
        case "userpromptsubmit", "userpromptsubmitted", "posttooluse", "posttoolusefailure":
            return .working
        case "pretooluse", "permissionrequest":
            switch toolName {
            case "AskUserQuestion", "ask_user": return .needsAnswer
            case "ExitPlanMode", "exit_plan_mode": return .planReview
            default:
                // PreToolUse is only installed for question/plan tools; for any
                // other tool it means the agent is running, not blocked.
                return event.lowercased() == "permissionrequest" ? .needsPermission : .working
            }
        case "notification":
            switch notificationType {
            case "permission_prompt": return .needsPermission
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsAnswer
            case "idle_prompt": return .finished
            default: return nil
            }
        case "stop", "agentstop", "stopfailure":
            return .finished
        case "sessionend":
            return .ended
        default:
            return nil
        }
    }

    /// "/dev/ttys003" and "ttys003" both become "ttys003"; "??" means none.
    public static func normalizeTTY(_ value: String?) -> String? {
        guard var tty = value?.trimmingCharacters(in: .whitespaces), !tty.isEmpty, tty != "??" else { return nil }
        if tty.hasPrefix("/dev/") { tty.removeFirst("/dev/".count) }
        return tty.isEmpty ? nil : tty
    }
}

/// Turns the files in the state directory into the live session list.
public enum SessionStateLoader {
    /// - Parameters:
    ///   - files: raw contents of each `*.json` state file.
    ///   - maxAgeWithoutPID: sessions with no recorded PID expire after this long.
    ///   - isAlive: liveness check for a PID; sessions whose agent exited are dropped.
    /// - Returns: live sessions, newest first, one per session id.
    public static func sessions(
        from files: [Data],
        now: Date,
        maxAgeWithoutPID: TimeInterval = 12 * 60 * 60,
        isAlive: (Int32) -> Bool
    ) -> [AgentSession] {
        var newest: [String: AgentSession] = [:]
        for data in files {
            // `try?` flattens "malformed" and "no state change" into nil.
            guard let session = try? SessionStateParser.parse(data), session.activity != .ended else { continue }
            if let pid = session.pid {
                if !isAlive(pid) { continue }
            } else if now.timeIntervalSince(session.updatedAt) > maxAgeWithoutPID {
                continue
            }
            if let existing = newest[session.id], existing.updatedAt > session.updatedAt { continue }
            newest[session.id] = session
        }
        return newest.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
