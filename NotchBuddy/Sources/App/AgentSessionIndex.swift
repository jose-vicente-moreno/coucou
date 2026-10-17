import Foundation

// MARK: - Finding the agent sessions that can be continued
//
// Claude Code and Codex both keep a transcript per session on disk, and both can
// pick one back up long after the process that wrote it has gone:
// `claude -p <text> --resume <id>` and `codex exec resume <id> <text>`. That is
// what lets the notch list the sessions that have stopped and send the next
// instruction to any of them.
//
// Reading the disk, rather than only what the hooks saw, means sessions from
// before Coucou was launched are listed too. The cost is that a session found
// this way carries no terminal identity, so when it is continued its hooks come
// back on the generic pill; `PillSessionRegistry` fills that in for the sessions
// it did see (see `merged(disk:live:)`).
//
// The volume is the real problem: one busy day leaves a few hundred Claude
// transcripts. Neither size nor turn count separates the interesting ones, but
// the FOLDER does, so the index returns one row per project folder, keeping that
// folder's most recent session.
//
// Foundation only, no app types, so `scripts/test-agent-sessions.sh` can compile
// it on its own.

enum AgentKind: String, Equatable, CaseIterable, Sendable {
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        }
    }
}

struct ResumableSession: Equatable, Sendable {
    let agent: AgentKind
    let sessionId: String
    let cwd: String
    var lastActivity: Date
    /// Terminal the session ran in, known only for sessions the hooks saw.
    var hostApp: String?
    var bundleId: String?
    /// True while a turn is in flight; such a session is not offered.
    var isWorking: Bool = false

    /// The folder's name, which is what the user recognises.
    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// One row per agent and folder.
    var groupKey: String { "\(agent.rawValue)|\(cwd)" }
}

enum AgentSessionIndex {

    // MARK: - Where the transcripts live

    static func claudeRoot(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        "\(home)/.claude/projects"
    }

    static func codexRoot(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        "\(home)/.codex/sessions"
    }

    // MARK: - Pulling the id out of a file name

    /// Claude names the file after the session: `<uuid>.jsonl`.
    static func claudeSessionId(fromFileName name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        return isUUID(stem) ? stem : nil
    }

    /// Codex names it `rollout-<timestamp>-<uuid>.jsonl`, and the timestamp has
    /// dashes of its own, so the id is the last 36 characters of the stem.
    static func codexSessionId(fromFileName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return isUUID(candidate) ? candidate : nil
    }

    /// Shape check only: Codex ids are UUID-shaped but not always RFC 4122 versions.
    static func isUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        for (part, length) in zip(parts, lengths) {
            guard part.count == length,
                  part.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        return true
    }

    // MARK: - Pulling the working directory out of a transcript

    /// Reads the head of a file without loading all of it: a transcript runs to
    /// megabytes and the fields we want sit in the first entries.
    static func head(ofFile path: String, maxBytes: Int = 65_536) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Claude writes `cwd` on its entries, though not always the very first one.
    /// The folder name on disk cannot stand in for it: both `/` and `.` are
    /// written as `-`, so `-Users-jose-vicente-moreno--claude` is ambiguous.
    static func claudeCwd(inLines lines: [String]) -> String? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let cwd = json["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    /// Codex opens with a `session_meta` record holding the folder.
    static func codexCwd(inLines lines: [String]) -> String? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let payload = json["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
            if let cwd = json["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    // MARK: - Scanning

    /// Every Claude transcript touched inside the window.
    static func claudeSessions(
        root: String,
        since: Date,
        fileManager: FileManager = .default
    ) -> [ResumableSession] {
        guard let projects = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        var found: [ResumableSession] = []
        for project in projects {
            let dir = "\(root)/\(project)"
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                guard let id = claudeSessionId(fromFileName: name) else { continue }
                let path = "\(dir)/\(name)"
                guard let modified = modificationDate(path, fileManager: fileManager), modified >= since else { continue }
                guard let cwd = claudeCwd(inLines: head(ofFile: path)) else { continue }
                found.append(ResumableSession(agent: .claudeCode, sessionId: id, cwd: cwd, lastActivity: modified))
            }
        }
        return found
    }

    /// Every Codex transcript touched inside the window. They sit under
    /// `sessions/YYYY/MM/DD/`, so the walk is a shallow recursive one.
    static func codexSessions(
        root: String,
        since: Date,
        fileManager: FileManager = .default
    ) -> [ResumableSession] {
        guard let walker = fileManager.enumerator(atPath: root) else { return [] }
        var found: [ResumableSession] = []
        for case let relative as String in walker {
            let name = (relative as NSString).lastPathComponent
            guard let id = codexSessionId(fromFileName: name) else { continue }
            let path = "\(root)/\(relative)"
            guard let modified = modificationDate(path, fileManager: fileManager), modified >= since else { continue }
            guard let cwd = codexCwd(inLines: head(ofFile: path)) else { continue }
            found.append(ResumableSession(agent: .codex, sessionId: id, cwd: cwd, lastActivity: modified))
        }
        return found
    }

    static func modificationDate(_ path: String, fileManager: FileManager = .default) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Collapsing to something a person can read

    /// One row per agent and folder, keeping the most recent session, newest first.
    static func groupedByFolder(_ sessions: [ResumableSession]) -> [ResumableSession] {
        var newest: [String: ResumableSession] = [:]
        for session in sessions {
            if let kept = newest[session.groupKey], kept.lastActivity >= session.lastActivity { continue }
            newest[session.groupKey] = session
        }
        return newest.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Adds what the hooks know to what the disk knows: the terminal a session ran
    /// in, and whether it is working right now. A live session the disk scan missed
    /// is kept, so nothing in front of the user disappears.
    static func merged(disk: [ResumableSession], live: [ResumableSession]) -> [ResumableSession] {
        var byId: [String: ResumableSession] = [:]
        for session in disk { byId[session.sessionId] = session }
        for session in live {
            if var existing = byId[session.sessionId] {
                existing.hostApp = session.hostApp ?? existing.hostApp
                existing.bundleId = session.bundleId ?? existing.bundleId
                existing.isWorking = session.isWorking
                existing.lastActivity = max(existing.lastActivity, session.lastActivity)
                byId[session.sessionId] = existing
            } else {
                byId[session.sessionId] = session
            }
        }
        return groupedByFolder(Array(byId.values))
    }

    /// The list the notch shows: stopped sessions, newest first, whose folder is
    /// still there. A folder that has been deleted or was a throwaway run cannot
    /// be resumed into, so it is left out rather than offered and then failing.
    static func waiting(
        disk: [ResumableSession],
        live: [ResumableSession] = [],
        limit: Int = 25,
        projectsOnly: Bool = true,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        throwawayRoots: [String]? = nil,
        fileManager: FileManager = .default
    ) -> [ResumableSession] {
        merged(disk: disk, live: live)
            .filter { !$0.isWorking }
            .filter { !isThrowaway($0.cwd, home: home, roots: throwawayRoots) }
            .filter { folderExists($0.cwd, fileManager: fileManager) }
            .filter { !projectsOnly || isInRepository($0.cwd, fileManager: fileManager) }
            .prefix(limit)
            .map { $0 }
    }

    static func folderExists(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Telling real work from machine runs

    /// Scratch roots nothing is ever resumed into. `~/.claude/jobs` is where a
    /// background job keeps its temporary files; it often sits inside a checked-in
    /// `~/.claude`, so the repository test below would otherwise let it through.
    static func throwawayRoots(home: String) -> [String] {
        ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", "\(home)/.claude/jobs"]
    }

    /// `roots` is injectable so a test can build its fixture inside a temporary
    /// folder, which is itself one of the roots in real life.
    static func isThrowaway(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        roots: [String]? = nil
    ) -> Bool {
        if path == "/" || path == home { return true }
        return (roots ?? throwawayRoots(home: home)).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Whether the folder sits in a repository, walking up to the root.
    ///
    /// This is what separates work worth continuing from machine noise. On a busy
    /// day the folder grouping alone still leaves mostly batch runs of a pipeline,
    /// throwaway temp folders and job scratch directories; every one of those is
    /// outside a repository, and every real project is inside one. It is a default,
    /// not a law: `projectsOnly: false` lists everything.
    static func isInRepository(_ path: String, fileManager: FileManager = .default) -> Bool {
        var current = (path as NSString).standardizingPath
        var guardCount = 0
        while current != "/" && !current.isEmpty && guardCount < 64 {
            if fileManager.fileExists(atPath: current + "/.git") { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
            guardCount += 1
        }
        return false
    }

    // MARK: - The whole scan

    /// Everything that can be continued, from both agents, inside `window`.
    static func scan(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: Date = Date(),
        window: TimeInterval = 24 * 60 * 60,
        live: [ResumableSession] = [],
        limit: Int = 25,
        projectsOnly: Bool = true,
        throwawayRoots: [String]? = nil
    ) -> [ResumableSession] {
        let since = now.addingTimeInterval(-window)
        let disk = claudeSessions(root: claudeRoot(home: home), since: since)
            + codexSessions(root: codexRoot(home: home), since: since)
        return waiting(disk: disk, live: live, limit: limit, projectsOnly: projectsOnly,
                       home: home, throwawayRoots: throwawayRoots)
    }
}
