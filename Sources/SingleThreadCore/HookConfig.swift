import Foundation

/// Builds and merges the hook configuration that points agents at
/// `single-thread-hook`. Pure functions over JSON dictionaries; the CLI does
/// the file reading and writing.
public enum HookConfig {
    /// Every command we install contains this, which is how re-installs and
    /// uninstalls find our entries without touching anyone else's.
    public static let marker = "single-thread-hook"

    /// Claude Code events we listen to, with an optional matcher.
    ///
    /// - PermissionRequest fires the moment a permission or plan-approval
    ///   dialog opens; the `permission_prompt` notification waits ~6 seconds.
    /// - PreToolUse is limited to the question and plan tools.
    /// - PostToolUse (and PostToolUseFailure) flip the session back to
    ///   working after an approval.
    /// - StopFailure ends a turn on an API error; the agent is idle either way.
    public static let claudeEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode"),
        ("PermissionRequest", nil),
        ("PostToolUse", nil),
        ("PostToolUseFailure", nil),
        ("Notification", nil),
        ("Stop", nil),
        ("StopFailure", nil),
        ("SessionEnd", nil),
    ]

    /// Copilot CLI events (camelCase names from its hooks reference).
    /// `preToolUse` and `permissionRequest` are left out on purpose:
    /// Copilot's `permissionRequest` fires before its permission rules run,
    /// including for requests that never reach the user.
    public static let copilotEvents = [
        "sessionStart", "userPromptSubmitted", "postToolUse", "postToolUseFailure", "notification", "agentStop",
        "sessionEnd",
    ]
    public static let copilotEventsLeftOut: Set<String> = ["preToolUse", "permissionRequest"]

    public static let timeoutSeconds = 5

    /// Wraps `value` in single quotes for a POSIX shell.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(scriptPath: String, agent: String, event: String) -> String {
        "\(shellQuote(scriptPath)) \(agent) \(event)"
    }

    /// The value of the `hooks` key for a Claude Code settings file.
    public static func claudeHooks(scriptPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (event, matcher) in claudeEvents {
            hooks[event] = [claudeGroup(scriptPath: scriptPath, event: event, matcher: matcher)]
        }
        return hooks
    }

    static func claudeGroup(scriptPath: String, event: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": command(scriptPath: scriptPath, agent: "claude-code", event: event),
                "timeout": timeoutSeconds,
            ] as [String: Any]],
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    /// Adds our hooks to an existing Claude Code settings object, keeping every
    /// other key and every other hook. Running it twice gives the same result.
    public static func mergeClaudeHooks(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var result = removeClaudeHooks(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(claudeGroup(scriptPath: scriptPath, event: event, matcher: matcher))
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    /// Removes only our hook handlers; empty groups and events left behind are dropped.
    public static func removeClaudeHooks(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let kept = handlers.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if kept.isEmpty { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    /// A complete Copilot CLI hooks file (`~/.copilot/hooks/<name>.json` or
    /// `.github/hooks/<name>.json`). The file is ours alone, so no merge is needed.
    public static func copilotHooksFile(scriptPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in copilotEvents {
            hooks[event] = [[
                "type": "command",
                "bash": command(scriptPath: scriptPath, agent: "copilot-cli", event: event),
                "timeoutSec": timeoutSeconds,
            ] as [String: Any]]
        }
        return ["version": 1, "hooks": hooks]
    }

    /// Stable, human-readable JSON.
    public static func jsonData(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(contentsOf: [0x0A])
        return data
    }
}
