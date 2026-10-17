#if !APPSTORE
import Foundation

// MARK: - Continuing a stopped agent session
//
// Both agents can pick a finished conversation back up from the command line:
//
//     claude -p <text> --resume <session id>
//     codex exec resume <session id> <text>
//
// so the notch can list what has stopped and send the next instruction without
// the user going back to a terminal. The hooks keep working on the continued
// turn, which is how the island, the approvals and the iPhone follow it like any
// other run.
//
// This is the Mac-side home of what `PhoneLink/InstructionRunner` has been doing
// for the iPhone since 0.1.9, lifted out so it no longer needs CloudKit, iCloud
// sync or `PHONE_LINK`, and extended to Codex, which InstructionRunner refuses
// by name.
//
// GitHub build only: the App Store build is sandboxed and can't start a command.
//
// Deliberately NOT reusing `ClaudeCodeChat.environment()`: that one strips
// ANTHROPIC_API_KEY so the chat provider bills the account. Here we are resuming
// the user's own work and must not change how their session authenticates.

enum AgentRunError: Error, Equatable {
    case executableNotFound(AgentKind)
    case folderMissing(String)
    case alreadyRunning(String)
    case emptyInstruction
    case launchFailed(String)

    var localizedDescription: String {
        switch self {
        case .executableNotFound(let agent): return "\(agent.displayName) isn't installed on this Mac."
        case .folderMissing(let path):       return "The session's folder is gone: \(path)"
        case .alreadyRunning:                return "That session is already working."
        case .emptyInstruction:              return "Type an instruction first."
        case .launchFailed(let message):     return message
        }
    }
}

enum AgentSessionRunner {

    // MARK: - Where the commands live

    /// Codex install locations, newest nvm version first. `CodexPlanGauge` calls
    /// this too, so the list lives in one place.
    static func codexSearchPaths(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/Library/pnpm/codex",
        ]
        let nvmNode = "\(home)/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmNode) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            candidates += sorted.map { "\(nvmNode)/\($0)/bin/codex" }
        }
        return candidates
    }

    static func executablePath(
        for agent: AgentKind,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        switch agent {
        case .claudeCode:
            // Same list the chat provider uses.
            return ClaudeCodeChat.executablePath(home: home, isExecutable: isExecutable)
        case .codex:
            return codexSearchPaths(home: home).first(where: isExecutable)
        }
    }

    // MARK: - The command line

    /// Built apart from the run so a test can assert exactly what is sent.
    static func arguments(for agent: AgentKind, sessionId: String, text: String) -> [String] {
        switch agent {
        case .claudeCode: return ["-p", text, "--resume", sessionId]
        case .codex:      return ["exec", "resume", sessionId, text]
        }
    }

    /// The command does not inherit the shell's PATH, so it is spelled out. When
    /// the terminal that ran the session is known, it is pinned so the hooks come
    /// back on the same pill instead of a second one appearing.
    static func environment(
        executable: String,
        bundleId: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var env = base
        let binDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        env["PATH"] = [
            binDir, "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin",
            base["PATH"] ?? "",
        ].joined(separator: ":")
        if let bundleId, !bundleId.isEmpty {
            env["__CFBundleIdentifier"] = bundleId
        } else {
            env["TERM_PROGRAM"] = "vscode"
        }
        return env
    }

    /// Where a run's output is kept, one file per session, for when it fails.
    static func logURL(sessionId: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Logs/NotchBuddy")
            .appendingPathComponent("continue-\(sessionId).log")
    }
}

// MARK: - Launching and keeping track

@MainActor
final class AgentRunLauncher {
    static let shared = AgentRunLauncher()

    /// Runs in flight, by session id, so one session is never started twice.
    private var running: [String: Process] = [:]

    /// How many may be started by one "send to all". Continuing a session starts
    /// real work in a real repository, so the fan-out is capped rather than
    /// unleashed over everything the list happens to hold.
    static let maxConcurrent = 8

    func isRunning(_ sessionId: String) -> Bool { running[sessionId] != nil }

    var runningCount: Int { running.count }

    /// Sends one instruction to one stopped session.
    @discardableResult
    func run(
        session: ResumableSession,
        text: String,
        executableOverride: String? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> Process {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw AgentRunError.emptyInstruction }
        guard running[session.sessionId] == nil else { throw AgentRunError.alreadyRunning(session.sessionId) }
        guard AgentSessionIndex.folderExists(session.cwd) else { throw AgentRunError.folderMissing(session.cwd) }
        guard let executable = executableOverride
                ?? AgentSessionRunner.executablePath(for: session.agent, home: home) else {
            throw AgentRunError.executableNotFound(session.agent)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = AgentSessionRunner.arguments(
            for: session.agent, sessionId: session.sessionId, text: instruction
        )
        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
        // Codex tags its own pill through its hooks, so only Claude needs pinning.
        process.environment = AgentSessionRunner.environment(
            executable: executable,
            bundleId: session.agent == .claudeCode ? session.bundleId : nil,
            home: home
        )
        process.standardInput = FileHandle.nullDevice

        // Output to a file, never a pipe: an unread pipe that fills up stalls the
        // command (the same reason InstructionRunner logs to a file).
        let logURL = AgentSessionRunner.logURL(sessionId: session.sessionId, home: home)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice

        let sessionId = session.sessionId
        process.terminationHandler = { finished in
            try? output?.close()
            let status = finished.terminationStatus
            Task { @MainActor in
                AgentRunLauncher.shared.running[sessionId] = nil
                NotificationCenter.default.post(
                    name: .agentRunFinished,
                    object: AgentRunOutcome(sessionId: sessionId, exitCode: status)
                )
            }
        }

        do {
            try process.run()
        } catch {
            try? output?.close()
            throw AgentRunError.launchFailed(error.localizedDescription)
        }
        running[sessionId] = process
        return process
    }

    /// Sends the same instruction to several stopped sessions, up to the cap.
    /// Returns what was started and what refused, so the caller can say so
    /// instead of silently dropping half of them.
    @discardableResult
    func runAll(
        sessions: [ResumableSession],
        text: String,
        executableOverride: String? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> (started: [ResumableSession], failed: [(ResumableSession, AgentRunError)]) {
        var started: [ResumableSession] = []
        var failed: [(ResumableSession, AgentRunError)] = []
        for session in sessions.prefix(Self.maxConcurrent) {
            do {
                try run(session: session, text: text, executableOverride: executableOverride, home: home)
                started.append(session)
            } catch let error as AgentRunError {
                failed.append((session, error))
            } catch {
                failed.append((session, .launchFailed(error.localizedDescription)))
            }
        }
        return (started, failed)
    }
}

struct AgentRunOutcome {
    let sessionId: String
    let exitCode: Int32
}

extension Notification.Name {
    static let agentRunFinished = Notification.Name("notchBuddy.agentRunFinished")
}
#endif
