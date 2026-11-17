import AppKit
import SingleThreadCore

/// What the menu shows after each pass.
struct EngineSnapshot {
    var sessions: [AgentSession] = []
    var windowBySession: [String: UInt32] = [:]
    var flagged: Set<String> = []
    var overlayCount = 0
    var supportedWindowCount = 0
}

/// The main loop: scan windows, decide which one stays clear, match agent
/// sessions to windows, and update the overlays.
final class FocusEngine {
    var preferences: Preferences {
        didSet {
            if preferences != oldValue { refresh() }
        }
    }

    let scanner = WindowScanner()
    let sessionStore: SessionStore
    var onSnapshot: ((EngineSnapshot) -> Void)?
    private(set) var snapshot = EngineSnapshot()

    private let overlays = OverlayController()
    private var attention = AttentionTracker()
    private var lastClear: UInt32?
    private var timer: Timer?
    private var observers: [pid_t: AXAppObserver] = [:]
    private var refreshScheduled = false
    private let ownPID = getpid()

    init(preferences: Preferences, sessionStore: SessionStore) {
        self.preferences = preferences
        self.sessionStore = sessionStore
    }

    func start() {
        sessionStore.onChange = { [weak self] in self?.refresh() }
        sessionStore.start()

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == NSWorkspace.didTerminateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.observers[app.processIdentifier] = nil
                    self?.scanner.forgetApp(pid: app.processIdentifier)
                }
                self?.scheduleRefresh(accessibilityChanged: true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh(accessibilityChanged: true) }

        // Safety net for anything notifications miss (window order changes,
        // drags in apps that only report the final position, Space switches).
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Coalesces bursts of notifications into one pass on the next run-loop turn.
    func scheduleRefresh(accessibilityChanged: Bool = false) {
        if accessibilityChanged { scanner.invalidateAccessibility() }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        sessionStore.reloadIfStale()
        let scan = scanner.scan(preferences: preferences)
        updateAXObservers(for: scan.windows)

        var frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID == ownPID { frontPID = nil }
        let clear = FocusResolver.clearWindowID(
            frontToBack: scan.windows,
            frontmostPID: frontPID,
            previousClear: lastClear,
            keepLastAgentWindowClear: preferences.keepLastAgentWindowClear
        )
        if let clear { lastClear = clear }

        let sessions = sessionStore.sessions
        let match = SessionMatcher.match(sessions: sessions, windows: scan.windows)
        var focusedSessions = Set<String>()
        let lookedAt = FocusResolver.lookedAtWindowID(clearWindowID: clear, frontToBack: scan.windows, frontmostPID: frontPID)
        if let lookedAt, let session = match.sessionsByWindow[lookedAt] { focusedSessions.insert(session.id) }
        let flagged = attention.update(sessions: sessions, focusedSessionIDs: focusedSessions)

        let specs = OverlayPlanner.plan(
            windows: scan.windows,
            clearWindowID: clear,
            preferences: preferences,
            sessionsByWindow: match.sessionsByWindow,
            attentionSessionIDs: flagged
        )
        overlays.apply(specs, zOrder: scan.zOrder)

        var windowBySession: [String: UInt32] = [:]
        for (windowID, session) in match.sessionsByWindow { windowBySession[session.id] = windowID }
        let next = EngineSnapshot(
            sessions: sessions,
            windowBySession: windowBySession,
            flagged: flagged,
            overlayCount: specs.count,
            supportedWindowCount: scan.windows.count
        )
        let changed = next.sessions != snapshot.sessions || next.flagged != snapshot.flagged
            || next.windowBySession != snapshot.windowBySession || next.overlayCount != snapshot.overlayCount
            || next.supportedWindowCount != snapshot.supportedWindowCount
        snapshot = next
        if changed { onSnapshot?(next) }
        if debug { log(scan: scan, clear: clear, specs: specs, match: match, flagged: flagged) }
    }

    // MARK: Debug log (SINGLE_THREAD_DEBUG=1 → stderr, one line per change)

    private let debug = ProcessInfo.processInfo.environment["SINGLE_THREAD_DEBUG"] == "1"
    private var lastLogLine = ""

    private func log(scan: WindowScanner.Scan, clear: UInt32?, specs: [OverlaySpec],
                     match: SessionMatcher.Result, flagged: Set<String>) {
        let windows = scan.windows.map { w -> String in
            let session = match.sessionsByWindow[w.id].map { " session=\($0.cwdName ?? $0.sessionID):\($0.activity.rawValue)" } ?? ""
            let flag = match.sessionsByWindow[w.id].map { flagged.contains($0.id) ? " NEEDS-YOU" : "" } ?? ""
            return "\(w.id)[\(w.appName) title=\(w.title ?? "-") doc=\(w.documentPath ?? "-")\(session)\(flag)]"
        }
        let line = "ax=\(AX.isTrusted) clear=\(clear.map(String.init) ?? "none") overlays=\(specs.map(\.windowID)) "
            + "state=[\(overlays.debugDescription)] "
            + "unmatched=\(match.unmatched.map { $0.cwdName ?? $0.sessionID }) windows=\(windows)"
        guard line != lastLogLine else { return }
        lastLogLine = line
        FileHandle.standardError.write(Data(("[single-thread] " + line + "\n").utf8))
    }

    /// Brings a session's window to the front.
    func focus(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
        if let windowID = snapshot.windowBySession[sessionID],
           let element = scanner.axElement(for: windowID) {
            AX.raise(element)
            if let pid = pidOfWindow(windowID) {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            return
        }
        if let bundleID = session.hostBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        }
    }

    private func pidOfWindow(_ id: UInt32) -> pid_t? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]]
        return info?.first?[kCGWindowOwnerPID as String] as? pid_t
    }

    private func updateAXObservers(for windows: [WindowInfo]) {
        guard AX.isTrusted else {
            observers.removeAll()
            return
        }
        for pid in Set(windows.map(\.pid)) where observers[pid] == nil {
            observers[pid] = AXAppObserver(pid: pid) { [weak self] in
                self?.scheduleRefresh(accessibilityChanged: true)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        overlays.removeAll()
    }
}
