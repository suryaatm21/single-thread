import AppKit
import SingleThreadCore

/// Lists on-screen windows of supported apps.
///
/// CoreGraphics is the source of truth for which windows exist, where they are,
/// and their front-to-back order; it needs no permission. Accessibility, when
/// granted, adds titles and working directories, refreshed at most once a
/// second or right after an Accessibility notification.
final class WindowScanner {
    struct Scan {
        /// Supported windows, front to back.
        var windows: [WindowInfo]
        /// Every normal-level on-screen window (ours included), front to back.
        var zOrder: [UInt32]
    }

    private struct AXDetails {
        var title: String?
        var documentPath: String?
        var element: AXUIElement
    }

    private let ownPID = getpid()
    private var axDetails: [UInt32: AXDetails] = [:]
    private var lastAXRefresh = Date.distantPast
    private var axDirty = true
    private var appNames: [pid_t: (bundleID: String?, name: String)] = [:]

    /// Ask for fresh Accessibility details on the next scan.
    func invalidateAccessibility() { axDirty = true }

    func scan(preferences: Preferences) -> Scan {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return Scan(windows: [], zOrder: [])
        }
        var windows: [WindowInfo] = []
        var zOrder: [UInt32] = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            zOrder.append(number)
            guard pid != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            let app = appInfo(pid: pid, ownerName: entry[kCGWindowOwnerName as String] as? String)
            guard preferences.isSupported(bundleID: app.bundleID) else { continue }
            windows.append(WindowInfo(
                id: number,
                pid: pid,
                bundleID: app.bundleID,
                appName: app.name,
                // Present only with Screen Recording access; Accessibility overrides it below.
                title: (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 },
                frame: bounds
            ))
        }

        if AX.isTrusted {
            let knownIDs = Set(axDetails.keys)
            let hasNewWindow = windows.contains { !knownIDs.contains($0.id) }
            if axDirty || hasNewWindow || Date().timeIntervalSince(lastAXRefresh) > 1.0 {
                refreshAccessibility(for: windows)
            }
            for index in windows.indices {
                guard let details = axDetails[windows[index].id] else { continue }
                if let title = details.title, !title.isEmpty { windows[index].title = title }
                windows[index].documentPath = details.documentPath
            }
        }
        return Scan(windows: windows, zOrder: zOrder)
    }

    /// The AX element for a window, if Accessibility knows it.
    func axElement(for windowID: UInt32) -> AXUIElement? {
        axDetails[windowID]?.element
    }

    private func refreshAccessibility(for windows: [WindowInfo]) {
        axDirty = false
        lastAXRefresh = Date()
        var fresh: [UInt32: AXDetails] = [:]
        let byPID = Dictionary(grouping: windows, by: \.pid)
        for (pid, cgWindows) in byPID {
            let app = AX.application(pid)
            for element in AX.windows(of: app) {
                let id = AX.windowID(element) ?? frameMatch(element, among: cgWindows)
                guard let id else { continue }
                fresh[id] = AXDetails(title: AX.title(element), documentPath: AX.documentPath(element), element: element)
            }
        }
        axDetails = fresh
    }

    /// Fallback when the window-number lookup is unavailable: the CG window
    /// with the same frame.
    private func frameMatch(_ element: AXUIElement, among windows: [WindowInfo]) -> UInt32? {
        guard let frame = AX.frame(element) else { return nil }
        let matches = windows.filter { ScreenGeometry.approximatelyEqual($0.frame, frame) }
        return matches.count == 1 ? matches[0].id : nil
    }

    private func appInfo(pid: pid_t, ownerName: String?) -> (bundleID: String?, name: String) {
        if let cached = appNames[pid] { return cached }
        let running = NSRunningApplication(processIdentifier: pid)
        let info = (bundleID: running?.bundleIdentifier, name: running?.localizedName ?? ownerName ?? "App")
        appNames[pid] = info
        return info
    }

    /// Forget cached app names for processes that exited.
    func forgetApp(pid: pid_t) {
        appNames[pid] = nil
    }
}
