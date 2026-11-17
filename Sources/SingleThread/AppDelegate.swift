import AppKit
import SingleThreadCore

/// Menu-bar UI: on/off, mode, sessions, permissions.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var engine: FocusEngine!
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stored = defaults.dictionaryRepresentation()
        let preferences = Preferences(
            stored: stored,
            environmentApps: ProcessInfo.processInfo.environment["SINGLE_THREAD_APPS"]
        )
        engine = FocusEngine(preferences: preferences, sessionStore: SessionStore())
        engine.onSnapshot = { [weak self] _ in self?.updateStatusButton() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()

        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    // MARK: Status button

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let enabled = engine.preferences.enabled
        let symbol = enabled ? "rectangle.on.rectangle.angled.fill" : "rectangle.on.rectangle.angled"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "single-thread")
        button.image?.isTemplate = true
        let waiting = engine.snapshot.flagged.count
        if waiting > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(waiting)",
                attributes: [.foregroundColor: OverlayContentView.amber, .font: NSFont.menuBarFont(ofSize: 0)]
            )
        } else {
            button.title = ""
        }
        button.toolTip = AX.isTrusted ? "single-thread" : "single-thread: Accessibility permission needed"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = engine.preferences
        let snapshot = engine.snapshot

        let toggle = item(prefs.enabled ? "Focus overlay: On" : "Focus overlay: Off", #selector(toggleEnabled))
        toggle.state = prefs.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        menu.addItem(header("Mode"))
        for mode in OverlayMode.allCases {
            let modeItem = item(mode.menuTitle, #selector(selectMode(_:)))
            modeItem.representedObject = mode.rawValue
            modeItem.state = prefs.mode == mode ? .on : .off
            modeItem.indentationLevel = 1
            menu.addItem(modeItem)
        }
        let keep = item("Keep last agent window clear when another app is in front", #selector(toggleKeepLast))
        keep.state = prefs.keepLastAgentWindowClear ? .on : .off
        menu.addItem(keep)
        menu.addItem(.separator())

        menu.addItem(header("Agent sessions"))
        if snapshot.sessions.isEmpty {
            let none = item("No sessions reporting. Install the hooks (see README).", nil)
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)
        }
        for session in snapshot.sessions {
            let flagged = snapshot.flagged.contains(session.id)
            let place = snapshot.windowBySession[session.id] == nil ? " (window not identified)" : ""
            let name = session.cwdName ?? session.sessionID
            let text = "\(flagged ? "● " : "")\(name): \(session.agent.displayName), \(session.statusText)\(place)"
            let sessionItem = item(text, #selector(focusSession(_:)))
            sessionItem.representedObject = session.id
            sessionItem.indentationLevel = 1
            if flagged {
                sessionItem.attributedTitle = NSAttributedString(
                    string: text, attributes: [.foregroundColor: OverlayContentView.amber]
                )
            }
            menu.addItem(sessionItem)
        }
        menu.addItem(.separator())

        menu.addItem(header("Permissions"))
        for status in PermissionStatus.current() {
            let statusItem = item(status.menuText, status.action == nil ? nil : #selector(runPermissionAction(_:)))
            statusItem.representedObject = status.action?.rawValue
            statusItem.isEnabled = status.action != nil
            statusItem.indentationLevel = 1
            menu.addItem(statusItem)
        }
        menu.addItem(.separator())

        menu.addItem(item("Copy Claude Code hook config", #selector(copyClaudeHooks)))
        menu.addItem(item("Open session state folder", #selector(openStateFolder)))
        menu.addItem(.separator())
        let quit = item("Quit single-thread", #selector(NSApplication.terminate(_:)))
        quit.keyEquivalent = "q"
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func header(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    // MARK: Actions

    private func save() {
        for (key, value) in engine.preferences.storedValues {
            defaults.set(value, forKey: key)
        }
        updateStatusButton()
    }

    @objc private func toggleEnabled() {
        engine.preferences.enabled.toggle()
        save()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = OverlayMode(rawValue: raw) else { return }
        engine.preferences.mode = mode
        save()
    }

    @objc private func toggleKeepLast() {
        engine.preferences.keepLastAgentWindowClear.toggle()
        save()
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        engine.focus(sessionID: id)
    }

    @objc private func runPermissionAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = PermissionStatus.Action(rawValue: raw) else { return }
        action.perform()
    }

    @objc private func copyClaudeHooks() {
        guard let script = HookScriptLocator.locate(),
              let data = try? HookConfig.jsonData(["hooks": HookConfig.claudeHooks(scriptPath: script)]),
              let text = String(data: data, encoding: .utf8) else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openStateFolder() {
        let dir = engine.sessionStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
