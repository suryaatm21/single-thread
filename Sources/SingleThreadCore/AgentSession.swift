import Foundation

public enum AgentKind: String, Sendable {
    case claudeCode = "claude-code"
    case copilotCLI = "copilot-cli"
    case other

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .copilotCLI: return "Copilot CLI"
        case .other: return "Agent"
        }
    }
}

/// What an agent session is doing, as far as its hooks have told us.
public enum AgentActivity: String, Sendable {
    case ready
    case working
    case needsPermission
    case needsAnswer
    case planReview
    case finished
    case ended

    /// True when the agent is blocked on the developer: a permission prompt,
    /// a question, a plan waiting for approval, or a finished turn.
    public var needsInput: Bool {
        switch self {
        case .needsPermission, .needsAnswer, .planReview, .finished: return true
        case .ready, .working, .ended: return false
        }
    }
}

/// One agent session, built from the newest state file its hooks wrote.
public struct AgentSession: Equatable, Sendable {
    /// Unique across agents: "<agent>:<session id>".
    public var id: String { "\(agent.rawValue):\(sessionID)" }
    public var sessionID: String
    public var agent: AgentKind
    public var event: String
    public var activity: AgentActivity
    public var cwd: String?
    /// Controlling terminal of the agent process, e.g. "ttys003".
    public var tty: String?
    /// PID of the agent process, used to drop sessions whose agent has exited.
    public var pid: Int32?
    /// Bundle ID of the GUI app that launched the agent's shell
    /// (`__CFBundleIdentifier`), e.g. "com.apple.Terminal".
    public var hostBundleID: String?
    public var termProgram: String?
    public var insideTmux: Bool
    public var toolName: String?
    public var message: String?
    /// Which wait this state belongs to. The hook bumps it on every event except
    /// a Notification, which repeats the wait already reported. Nil in files
    /// written before the hook recorded it.
    public var wait: Int?
    public var updatedAt: Date

    public init(
        sessionID: String,
        agent: AgentKind,
        event: String,
        activity: AgentActivity,
        cwd: String? = nil,
        tty: String? = nil,
        pid: Int32? = nil,
        hostBundleID: String? = nil,
        termProgram: String? = nil,
        insideTmux: Bool = false,
        toolName: String? = nil,
        message: String? = nil,
        wait: Int? = nil,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.event = event
        self.activity = activity
        self.cwd = cwd
        self.tty = tty
        self.pid = pid
        self.hostBundleID = hostBundleID
        self.termProgram = termProgram
        self.insideTmux = insideTmux
        self.toolName = toolName
        self.message = message
        self.wait = wait
        self.updatedAt = updatedAt
    }

    /// Last path component of the working directory, e.g. "api-server".
    public var cwdName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Short human status, e.g. "needs permission: Bash".
    public var statusText: String {
        switch activity {
        case .ready: return "ready"
        case .working: return "working"
        case .needsPermission:
            if let toolName, !toolName.isEmpty { return "needs permission: \(toolName)" }
            return "needs permission"
        case .needsAnswer: return "has a question for you"
        case .planReview: return "plan ready for review"
        case .finished: return "turn finished"
        case .ended: return "session ended"
        }
    }
}
