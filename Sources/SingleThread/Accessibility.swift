import AppKit
import ApplicationServices

/// Thin wrappers over the Accessibility C API.
enum AX {
    /// `_AXUIElementGetWindow` maps an AX window to its CoreGraphics window
    /// number. It is private but stable and used by most window managers; it is
    /// resolved at runtime so a missing symbol degrades to frame matching.
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFn: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that sends the user to the Accessibility pane.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        // A busy terminal must not freeze the menu bar.
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String, as _: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        attribute(app, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
    }

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        guard let getWindowFn else { return nil }
        var id: CGWindowID = 0
        return getWindowFn(window, &id) == .success && id != 0 ? id : nil
    }

    /// Frame in CoreGraphics global space.
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let posValue = attribute(window, kAXPositionAttribute, as: AXValue.self),
              let sizeValue = attribute(window, kAXSizeAttribute, as: AXValue.self) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func title(_ window: AXUIElement) -> String? {
        attribute(window, kAXTitleAttribute, as: String.self)
    }

    /// The file URL the window represents; terminals that track the shell's
    /// working directory (OSC 7) report it here.
    static func documentPath(_ window: AXUIElement) -> String? {
        guard let raw = attribute(window, kAXDocumentAttribute, as: String.self), !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url.path }
        return raw
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}

/// Watches one app's windows through Accessibility notifications and calls
/// `onChange` on the main run loop. Polling covers anything these miss.
final class AXAppObserver {
    let pid: pid_t
    private var observer: AXObserver?
    private let onChange: () -> Void

    private static let notifications: [String] = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification,
        kAXUIElementDestroyedNotification,
    ]

    init?(pid: pid_t, onChange: @escaping () -> Void) {
        self.pid = pid
        self.onChange = onChange
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AXAppObserver>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        let app = AX.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
