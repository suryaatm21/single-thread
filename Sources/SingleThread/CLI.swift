import Foundation
import SingleThreadCore

/// Finds the hook script: next to the app inside its bundle, or in the
/// repository checkout when run with `swift run` from the package root.
enum HookScriptLocator {
    static func locate(override: String? = nil) -> String? {
        var candidates: [String] = []
        if let override { candidates.append(override) }
        if let bundled = Bundle.main.url(forResource: "single-thread-hook", withExtension: nil) {
            candidates.append(bundled.path)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/hooks/single-thread-hook")
        for path in candidates {
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            if FileManager.default.isExecutableFile(atPath: absolute) { return absolute }
        }
        return nil
    }
}

/// Command-line subcommands. Returns an exit code, or nil to launch the app.
enum CLI {
    static let usage = """
    single-thread: dims, blurs and labels the agent windows you are not working in.

    Usage:
      SingleThread                                  Run the menu-bar app.
      SingleThread install-hooks claude --print     Print Claude Code hook settings.
      SingleThread install-hooks claude --settings <path>
                                                    Merge the hooks into that settings file,
                                                    e.g. <project>/.claude/settings.local.json.
      SingleThread uninstall-hooks claude --settings <path>
                                                    Remove only single-thread's hooks from it.
      SingleThread install-hooks copilot --print    Print a Copilot CLI hooks file.
      SingleThread install-hooks copilot --hooks-file <path>
                                                    Write it, e.g. ~/.copilot/hooks/single-thread.json
                                                    or <repo>/.github/hooks/single-thread.json.
      SingleThread sessions                         List sessions the hooks have reported.
      SingleThread status                           Show permission status.

    Options:
      --hook-script <path>   Hook script to reference (default: the bundled copy,
                             or ./hooks/single-thread-hook).

    Nothing is written unless you pass an explicit --settings or --hooks-file path.
    """

    static func run(_ arguments: [String]) -> Int32? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "-h", "--help", "help":
            print(usage)
            return 0
        case "install-hooks":
            return installHooks(rest, uninstall: false)
        case "uninstall-hooks":
            return installHooks(rest, uninstall: true)
        case "sessions":
            return listSessions()
        case "status":
            print(PermissionStatus.report())
            return 0
        default:
            // Launch Services may pass flags such as -psn_…; ignore them.
            if command.hasPrefix("-") { return nil }
            printError("unknown command: \(command)\n\n\(usage)")
            return 64
        }
    }

    private static func installHooks(_ args: [String], uninstall: Bool) -> Int32 {
        guard let agent = args.first, ["claude", "copilot"].contains(agent) else {
            printError("expected 'claude' or 'copilot'\n\n\(usage)")
            return 64
        }
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 1
        while index < args.count {
            let arg = args[index]
            if ["--settings", "--hooks-file", "--hook-script"].contains(arg), index + 1 < args.count {
                options[arg] = args[index + 1]
                index += 2
            } else {
                flags.insert(arg)
                index += 1
            }
        }
        if let unknown = flags.subtracting(["--print"]).first {
            printError("unknown option: \(unknown)")
            return 64
        }

        if uninstall {
            guard agent == "claude", let path = options["--settings"] else {
                printError("uninstall-hooks needs: claude --settings <path> (for Copilot, delete the hooks file)")
                return 64
            }
            return updateSettingsFile(path: path) { HookConfig.removeClaudeHooks(from: $0) }
        }

        guard let script = HookScriptLocator.locate(override: options["--hook-script"]) else {
            printError("cannot find an executable hook script; pass --hook-script <path>")
            return 66
        }

        switch agent {
        case "claude":
            if let path = options["--settings"] {
                return updateSettingsFile(path: path) { HookConfig.mergeClaudeHooks(into: $0, scriptPath: script) }
            }
            return printJSON(["hooks": HookConfig.claudeHooks(scriptPath: script)])
        default:
            let file = HookConfig.copilotHooksFile(scriptPath: script)
            if let path = options["--hooks-file"] {
                do {
                    let url = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try HookConfig.jsonData(file).write(to: url, options: .atomic)
                    print("Wrote Copilot CLI hooks to \(url.path)")
                    return 0
                } catch {
                    printError("could not write \(path): \(error.localizedDescription)")
                    return 73
                }
            }
            return printJSON(file)
        }
    }

    /// Reads a settings file (or starts empty), transforms it, keeps a
    /// `.bak` copy of the original, and writes the result atomically.
    private static func updateSettingsFile(path: String, transform: ([String: Any]) -> [String: Any]) -> Int32 {
        let url = URL(fileURLWithPath: path)
        var settings: [String: Any] = [:]
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            do {
                let data = try Data(contentsOf: url)
                if !data.isEmpty {
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        printError("\(path) is not a JSON object; leaving it untouched")
                        return 65
                    }
                    settings = object
                }
            } catch {
                printError("could not read \(path) as JSON (\(error.localizedDescription)); leaving it untouched")
                return 65
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if exists {
                let backup = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: url, to: backup)
            }
            try HookConfig.jsonData(transform(settings)).write(to: url, options: .atomic)
            print("Updated \(url.path)\(exists ? " (previous version saved as .bak)" : "")")
            return 0
        } catch {
            printError("could not write \(path): \(error.localizedDescription)")
            return 73
        }
    }

    private static func printJSON(_ object: Any) -> Int32 {
        guard let data = try? HookConfig.jsonData(object), let text = String(data: data, encoding: .utf8) else { return 70 }
        print(text, terminator: "")
        return 0
    }

    private static func listSessions() -> Int32 {
        let store = SessionStore()
        store.reload()
        print("State directory: \(store.directory.path)")
        if store.sessions.isEmpty {
            print("No live sessions.")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        for session in store.sessions {
            let place = [session.cwd, session.tty, session.hostBundleID].compactMap { $0 }.joined(separator: "  ")
            print("\(session.agent.displayName)  \(session.statusText)  \(formatter.string(from: session.updatedAt))  \(place)")
        }
        return 0
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data(("single-thread: " + message + "\n").utf8))
    }
}
