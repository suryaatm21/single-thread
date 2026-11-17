import Foundation

/// Best-effort mapping from agent sessions to the windows they run in.
///
/// A hook only knows its own process: working directory, controlling tty, and
/// the GUI app that launched its shell. A window only knows its title and, for
/// some terminals, the shell's working directory. The matcher scores every
/// session/window pair on that overlap and assigns greedily, best score first,
/// so each window gets at most one session and each session at most one window.
public enum SessionMatcher {
    public struct Result: Equatable, Sendable {
        public var sessionsByWindow: [UInt32: AgentSession]
        public var unmatched: [AgentSession]
    }

    /// Pairs scoring below this are not trusted.
    public static let minimumScore = 100

    public enum Weight {
        public static let ttyMatch = 1000
        public static let documentEqualsCwd = 300
        public static let titleContainsCwdPath = 200
        public static let documentRelatedToCwd = 120
        public static let titleContainsCwdName = 120
        public static let onlyWindowOfHostApp = 60
        public static let hostAppMatch = 50
    }

    public static func match(
        sessions: [AgentSession],
        windows: [WindowInfo],
        homeDirectory: String = NSHomeDirectory()
    ) -> Result {
        var windowCountByBundle: [String: Int] = [:]
        for window in windows {
            if let bundleID = window.bundleID { windowCountByBundle[bundleID, default: 0] += 1 }
        }

        struct Candidate {
            var score: Int
            var session: AgentSession
            var window: WindowInfo
        }
        var candidates: [Candidate] = []
        for session in sessions {
            for window in windows {
                let s = score(
                    session: session,
                    window: window,
                    windowsOfSameApp: window.bundleID.flatMap { windowCountByBundle[$0] } ?? 0,
                    homeDirectory: homeDirectory
                )
                if s >= minimumScore { candidates.append(Candidate(score: s, session: session, window: window)) }
            }
        }
        // Highest score first; on ties prefer the most recently active session.
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.session.updatedAt > $1.session.updatedAt
        }

        var byWindow: [UInt32: AgentSession] = [:]
        var usedSessions = Set<String>()
        for candidate in candidates {
            guard byWindow[candidate.window.id] == nil, !usedSessions.contains(candidate.session.id) else { continue }
            byWindow[candidate.window.id] = candidate.session
            usedSessions.insert(candidate.session.id)
        }
        let unmatched = sessions.filter { !usedSessions.contains($0.id) }
        return Result(sessionsByWindow: byWindow, unmatched: unmatched)
    }

    /// Scores how likely `session` runs inside `window`. Zero rules the pair out.
    public static func score(
        session: AgentSession,
        window: WindowInfo,
        windowsOfSameApp: Int,
        homeDirectory: String = NSHomeDirectory()
    ) -> Int {
        var total = 0

        // The launching app is reliable unless tmux sits in between: the tmux
        // server keeps the environment of whatever app started it first.
        if let host = session.hostBundleID, !session.insideTmux {
            guard host == window.bundleID else { return 0 }
            total += Weight.hostAppMatch
            if windowsOfSameApp == 1 { total += Weight.onlyWindowOfHostApp }
        }

        if let tty = session.tty, window.ttys.contains(tty) {
            total += Weight.ttyMatch
        }

        if let cwd = session.cwd.map(normalizePath), !cwd.isEmpty {
            if let doc = window.documentPath.map(normalizePath), !doc.isEmpty {
                if doc == cwd {
                    total += Weight.documentEqualsCwd
                } else if isAncestor(doc, of: cwd) || isAncestor(cwd, of: doc) {
                    total += Weight.documentRelatedToCwd
                }
            }
            if let title = window.title, !title.isEmpty {
                let home = normalizePath(homeDirectory)
                let tildePath = cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : nil
                if title.contains(cwd) || (tildePath.map { title.contains($0) } ?? false) {
                    total += Weight.titleContainsCwdPath
                } else if let name = session.cwdName, containsWord(title, name) {
                    total += Weight.titleContainsCwdName
                }
            }
        }
        return total
    }

    /// Strips a `file://` scheme and trailing slashes.
    public static func normalizePath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("file://") {
            p.removeFirst("file://".count)
            p = p.removingPercentEncoding ?? p
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        guard ancestor != "/" else { return false }
        return path.hasPrefix(ancestor + "/")
    }

    /// True when `word` appears in `text` with no name-like characters
    /// (letters, digits, `-`, `_`, `.`) directly before or after it, so
    /// "api" does not match inside "api-server".
    public static func containsWord(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." }
        var searchStart = text.startIndex
        while let range = text.range(of: word, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex || !isNameChar(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex || !isNameChar(text[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
