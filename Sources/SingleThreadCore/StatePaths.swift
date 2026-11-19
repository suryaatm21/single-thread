import Foundation

/// Where hooks write session state and the app reads it. The hook script
/// computes the same default; keep the two in sync.
public enum StatePaths {
    public static let environmentKey = "SINGLE_THREAD_STATE_DIR"

    public static func sessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/single-thread/sessions", isDirectory: true)
    }
}
