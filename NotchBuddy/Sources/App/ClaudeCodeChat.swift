import Foundation

// MARK: - Chat through the Claude Code CLI (no API key)
//
// Every other cloud provider in the chat needs the user's own API key. This one
// needs none: it drives the `claude` command already installed on the Mac, which
// is signed in with the user's Claude account, and reads its answer back.
//
// `claude -p <prompt> --output-format stream-json --include-partial-messages`
// prints one JSON object per line. Text arrives as `text_delta` pieces, the
// reasoning of a thinking model as `thinking_delta` (dropped here, the same job
// `LocalChat.progressiveFilter` does for `<think>` tags), and the last line is a
// `result` object with the whole answer and the session id. That id goes back in
// as `--resume` on the next turn, which is what keeps the conversation going.
//
// `--safe-mode` turns off the user's own CLAUDE.md, hooks, plugins, skills and
// MCP servers, so a question asked in the notch is not answered by whatever
// project the terminal happens to sit in. It leaves authentication alone, which
// is the point. `--bare` would ALSO disable it and force ANTHROPIC_API_KEY, so
// it must never be added here.
//
// GitHub build only: the App Store build is sandboxed and can't start `claude`.
// Foundation only, no app types, so `scripts/test-claude-code-chat.sh` can
// compile this file on its own.

// MARK: - Typed error

enum ClaudeCodeChatError: Error, Equatable {
    /// The `claude` command isn't installed anywhere we look.
    case cliNotFound
    /// It is installed, but nobody is signed in.
    case notSignedIn
    /// It ran and failed; the message is for the user.
    case runFailed(String)

    var localizedDescription: String {
        switch self {
        case .cliNotFound:
            return "Claude Code isn't installed on this Mac."
        case .notSignedIn:
            return "Claude Code is installed but not signed in. Run `claude` once in a terminal."
        case .runFailed(let message):
            return message
        }
    }
}

enum ClaudeCodeChat {

    // MARK: - Where the command lives

    /// The usual install locations, in the order they are tried.
    /// The app doesn't inherit the shell's PATH, so they are spelled out.
    static func searchPaths(home: String) -> [String] {
        [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
    }

    /// First location that holds something runnable, or nil.
    static func executablePath(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        searchPaths(home: home).first(where: isExecutable)
    }

    /// Whether the provider can be offered at all.
    static var isAvailable: Bool {
        #if APPSTORE
        // The sandbox forbids starting another program.
        return false
        #else
        return executablePath() != nil
        #endif
    }

    // MARK: - Models

    /// The CLI takes an alias, not an API model id, and there is no endpoint to
    /// ask, so the list is fixed rather than fetched.
    static let models: [(id: String, label: String)] = [
        (id: "opus",   label: "Opus"),
        (id: "sonnet", label: "Sonnet"),
        (id: "haiku",  label: "Haiku"),
        (id: "fable",  label: "Fable"),
    ]

    // MARK: - Arguments

    /// A chat in the notch answers questions; it does not touch the user's files.
    static let blockedTools = "Bash Edit Write Read Glob Grep WebFetch WebSearch Task NotebookEdit TodoWrite"

    /// Built apart from the run so a test can assert what is sent, in particular
    /// that `--safe-mode` is on and `--bare` never appears.
    static func arguments(
        prompt: String,
        systemPrompt: String,
        model: String,
        resumeSessionId: String?
    ) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--safe-mode",
            "--disallowed-tools", blockedTools,
        ]
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if !systemPrompt.isEmpty {
            args.append(contentsOf: ["--system-prompt", systemPrompt])
        }
        if let session = resumeSessionId, !session.isEmpty {
            args.append(contentsOf: ["--resume", session])
        }
        return args
    }

    /// The command needs a PATH it can use, and must NOT see an Anthropic key:
    /// the whole point of this provider is that it bills the account, so a key
    /// left in the environment would quietly change who pays.
    static func environment(
        executable: String,
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var env = base
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let binDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        env["PATH"] = [
            binDir, "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin",
            base["PATH"] ?? "",
        ].joined(separator: ":")
        return env
    }

    // MARK: - Stream parsing

    enum StreamPiece: Equatable {
        /// A piece of the visible answer.
        case text(String)
        /// The closing line: the whole answer, the session to resume, and whether it failed.
        case result(text: String, sessionId: String?, isError: Bool)
    }

    /// Reads one NDJSON line. Returns nil for every line that carries no answer:
    /// `system`, `assistant`, `rate_limit_event`, and the thinking and signature
    /// deltas of a reasoning model.
    static func parseStreamLine(_ line: String) -> StreamPiece? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }

        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  (event["type"] as? String) == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String,
                  !text.isEmpty else { return nil }
            return .text(text)

        case "result":
            let text = json["result"] as? String ?? ""
            let sessionId = json["session_id"] as? String
            let flagged = json["is_error"] as? Bool ?? false
            let subtype = json["subtype"] as? String ?? "success"
            return .result(text: text, sessionId: sessionId, isError: flagged || subtype != "success")

        default:
            return nil
        }
    }

    /// Maps a failure message onto `notSignedIn` when that is what it says, so the
    /// user is told to sign in rather than shown a raw CLI error.
    static func error(for message: String) -> ClaudeCodeChatError {
        let lower = message.lowercased()
        let signInWords = ["not signed in", "not logged in", "please log in", "please login",
                           "authentication", "unauthorized", "invalid api key", "/login"]
        if signInWords.contains(where: { lower.contains($0) }) {
            return .notSignedIn
        }
        return .runFailed(message)
    }

    // MARK: - Signed-in state

    struct AuthInfo: Equatable {
        var loggedIn: Bool
        var email: String?
        var method: String?
    }

    /// Parses `claude auth status --json`-shaped output. Separate from the run so
    /// it can be tested without the command.
    static func parseAuthStatus(_ raw: String) -> AuthInfo {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AuthInfo(loggedIn: false, email: nil, method: nil)
        }
        return AuthInfo(
            loggedIn: json["loggedIn"] as? Bool ?? false,
            email: json["email"] as? String,
            method: json["authMethod"] as? String
        )
    }

    /// Asks the command who is signed in, for the line shown in Settings.
    static func authStatus() async -> AuthInfo {
        guard let exe = executablePath() else {
            return AuthInfo(loggedIn: false, email: nil, method: nil)
        }
        let output = await runCapturing(executable: exe, arguments: ["auth", "status"], timeout: 15)
        return parseAuthStatus(output)
    }

    // MARK: - Chat

    /// Sends one turn and streams the answer back.
    ///
    /// - Parameters:
    ///   - resumeSessionId: the id returned by the previous turn, or nil to start.
    ///   - executable: overridden by the tests; otherwise discovered.
    ///   - onToken: called on the **main actor** with the answer so far.
    /// - Returns: the finished answer and the session id to resume next time.
    /// - Throws: `ClaudeCodeChatError`
    static func streamChat(
        prompt: String,
        systemPrompt: String,
        model: String,
        resumeSessionId: String? = nil,
        executable: String? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 180,
        onToken: @MainActor @escaping (String) -> Void
    ) async throws -> (text: String, sessionId: String?) {

        guard let exe = executable ?? executablePath() else { throw ClaudeCodeChatError.cliNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments(
            prompt: prompt, systemPrompt: systemPrompt,
            model: model, resumeSessionId: resumeSessionId
        )
        // Answering a question in the notch is not work on a project: run it
        // somewhere neutral so nothing in the current folder colours the answer.
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory ?? NSTemporaryDirectory())
        process.environment = environment(executable: exe)
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // stderr goes to a file, never a second pipe: an unread pipe that fills up
        // would stall the command (the same reason InstructionRunner logs to a file).
        let errorURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coucou-claude-code-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try? FileHandle(forWritingTo: errorURL)
        process.standardError = errorHandle ?? FileHandle.nullDevice
        defer {
            try? errorHandle?.close()
            try? FileManager.default.removeItem(at: errorURL)
        }

        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw ClaudeCodeChatError.runFailed("Couldn't start Claude Code: \(error.localizedDescription)")
        }

        // A hung command would leave the chat spinning forever, so it gets a deadline.
        // `Process` isn't Sendable; the box carries it across with that stated.
        let box = ProcessBox(process)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            box.terminate()
        }

        var buffer = Data()
        var accumulated = ""
        var finalText: String?
        var sessionId: String?
        var failed = false
        var lastUpdate = Date.distantPast
        let minInterval: TimeInterval = 1.0 / 15.0

        for await chunk in chunks {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                switch parseStreamLine(line) {
                case .text(let piece):
                    accumulated += piece
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) >= minInterval {
                        lastUpdate = now
                        let visible = accumulated
                        await MainActor.run { onToken(visible) }
                    }
                case .result(let text, let session, let isError):
                    finalText = text
                    sessionId = session
                    failed = isError
                case nil:
                    continue
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        watchdog.cancel()
        process.waitUntilExit()

        let errorText = String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if failed {
            let message = (finalText?.isEmpty == false ? finalText! : errorText)
            throw error(for: message.isEmpty ? "Claude Code couldn't answer." : message)
        }

        let answer = (finalText ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines)

        if answer.isEmpty {
            if process.terminationStatus != 0 {
                let message = errorText.isEmpty
                    ? "Claude Code stopped with code \(process.terminationStatus)."
                    : errorText
                throw error(for: message)
            }
            throw ClaudeCodeChatError.runFailed("Claude Code returned nothing.")
        }

        await MainActor.run { onToken(answer) }
        return (answer, sessionId)
    }

    // MARK: - Small helper for one-shot commands

    /// Runs a short command and returns its output; "" on any failure.
    private static func runCapturing(executable: String, arguments: [String], timeout: TimeInterval) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(executable: executable)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return "" }

        let box = ProcessBox(process)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            box.terminate()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Carrying a Process across a concurrency boundary
//
// `Process` is not Sendable, and the only thing crossing here is `terminate()`,
// which is safe to call from another thread and harmless once the process ended.

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
