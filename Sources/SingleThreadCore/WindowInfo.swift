import CoreGraphics

/// One on-screen window of a supported app, as the scanner sees it.
public struct WindowInfo: Equatable, Sendable {
    /// CoreGraphics window number (`CGWindowID`).
    public var id: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    /// Window title, from Accessibility (or CoreGraphics with Screen Recording).
    public var title: String?
    /// File path the window represents (AXDocument). Terminals that receive the
    /// shell's working directory (OSC 7) report it here.
    public var documentPath: String?
    /// Frame in CoreGraphics global space (top-left origin, y down).
    public var frame: CGRect
    /// Terminal devices shown in this window's tabs, when the terminal reports them.
    public var ttys: [String]

    public init(
        id: UInt32,
        pid: Int32,
        bundleID: String?,
        appName: String,
        title: String? = nil,
        documentPath: String? = nil,
        frame: CGRect,
        ttys: [String] = []
    ) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.documentPath = documentPath
        self.frame = frame
        self.ttys = ttys
    }
}
