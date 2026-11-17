import Foundation
import SingleThreadCore

/// Watches the hook state directory and keeps the live session list.
final class SessionStore {
    let directory: URL
    private(set) var sessions: [AgentSession] = []
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var lastLoad = Date.distantPast

    init(directory: URL = StatePaths.sessionsDirectory()) {
        self.directory = directory
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return } // polling via reloadIfStale still works
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Re-reads periodically so sessions whose agent exited disappear even
    /// when no hook ran.
    func reloadIfStale(maxAge: TimeInterval = 2) {
        if Date().timeIntervalSince(lastLoad) > maxAge { reload() }
    }

    func reload() {
        lastLoad = Date()
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let files = urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? Data(contentsOf: $0) }
        let loaded = SessionStateLoader.sessions(from: files, now: Date(), isAlive: Self.isAlive)
        if loaded != sessions {
            sessions = loaded
            onChange?()
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
