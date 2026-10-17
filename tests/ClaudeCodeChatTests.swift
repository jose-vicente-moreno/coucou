import Foundation

// Tests for ClaudeCodeChat, the chat provider that answers through the local
// `claude` command instead of an API key.
//
// Run by scripts/test-claude-code-chat.sh. The end-to-end part takes the path of
// tests/fake_claude_code.sh as argument 1 and is skipped when it is absent, so
// nothing here needs the real CLI, an account, or a network.

@MainActor
final class TokenLog {
    var calls: [String] = []
    var last: String { calls.last ?? "" }
}

@main
@MainActor
enum ClaudeCodeChatTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    // MARK: - Entry point

    static func main() async {

        // ── Finding the command ──────────────────────────────────────────────

        print("ClaudeCodeChat.executablePath")
        let paths = ClaudeCodeChat.searchPaths(home: "/Users/someone")
        checkTrue("looks in ~/.claude/local", paths.contains("/Users/someone/.claude/local/claude"))
        checkTrue("looks in ~/.local/bin",    paths.contains("/Users/someone/.local/bin/claude"))
        checkTrue("looks in Homebrew",        paths.contains("/opt/homebrew/bin/claude"))
        check("takes the first that runs",
              ClaudeCodeChat.executablePath(home: "/Users/someone") { $0 == "/opt/homebrew/bin/claude" } ?? "",
              "/opt/homebrew/bin/claude")
        checkTrue("nil when none is installed",
                  ClaudeCodeChat.executablePath(home: "/Users/someone") { _ in false } == nil)

        // ── The command line ─────────────────────────────────────────────────

        print("ClaudeCodeChat.arguments")
        let args = ClaudeCodeChat.arguments(
            prompt: "hello", systemPrompt: "be brief", model: "sonnet", resumeSessionId: nil
        )
        // The feature exists to bill the account. `--bare` forces ANTHROPIC_API_KEY,
        // so it must never appear here, whatever else changes.
        checkTrue("never passes --bare",            !args.contains("--bare"))
        checkTrue("passes --safe-mode",             args.contains("--safe-mode"))
        checkTrue("asks for stream-json",           args.contains("stream-json"))
        checkTrue("asks for partial messages",      args.contains("--include-partial-messages"))
        checkTrue("blocks the tools",               args.contains("--disallowed-tools"))
        checkTrue("blocks Bash and Write",
                  ClaudeCodeChat.blockedTools.contains("Bash") && ClaudeCodeChat.blockedTools.contains("Write"))
        checkTrue("prompt follows -p",
                  args.firstIndex(of: "-p").map { args[args.index(after: $0)] == "hello" } ?? false)
        checkTrue("passes the model",               args.contains("sonnet"))
        checkTrue("passes the system prompt",       args.contains("be brief"))
        checkTrue("no --resume on a first turn",    !args.contains("--resume"))

        let resumed = ClaudeCodeChat.arguments(
            prompt: "and again", systemPrompt: "", model: "", resumeSessionId: "sess-1"
        )
        checkTrue("resumes when given a session",   resumed.contains("--resume") && resumed.contains("sess-1"))
        checkTrue("omits --model when empty",       !resumed.contains("--model"))
        checkTrue("omits --system-prompt when empty", !resumed.contains("--system-prompt"))

        // ── Reading the stream ───────────────────────────────────────────────

        print("ClaudeCodeChat.parseStreamLine")
        let textLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#
        checkTrue("reads a text delta",
                  ClaudeCodeChat.parseStreamLine(textLine) == .text("hi"))

        let thinkingLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret"}}}"#
        checkTrue("drops a thinking delta",   ClaudeCodeChat.parseStreamLine(thinkingLine) == nil)

        let signatureLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"x"}}}"#
        checkTrue("drops a signature delta",  ClaudeCodeChat.parseStreamLine(signatureLine) == nil)

        checkTrue("ignores the init line",
                  ClaudeCodeChat.parseStreamLine(#"{"type":"system","subtype":"init"}"#) == nil)
        checkTrue("ignores the assistant line",
                  ClaudeCodeChat.parseStreamLine(#"{"type":"assistant","message":{"content":[]}}"#) == nil)
        checkTrue("ignores the rate limit line",
                  ClaudeCodeChat.parseStreamLine(#"{"type":"rate_limit_event"}"#) == nil)
        checkTrue("ignores an empty line",    ClaudeCodeChat.parseStreamLine("") == nil)
        checkTrue("ignores a broken line",    ClaudeCodeChat.parseStreamLine("not json at all") == nil)

        let okResult = #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s1"}"#
        checkTrue("reads a successful result",
                  ClaudeCodeChat.parseStreamLine(okResult) == .result(text: "done", sessionId: "s1", isError: false))

        let badResult = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom","session_id":"s1"}"#
        checkTrue("reads a failed result",
                  ClaudeCodeChat.parseStreamLine(badResult) == .result(text: "boom", sessionId: "s1", isError: true))

        let oddResult = #"{"type":"result","subtype":"error_max_turns","result":"stopped"}"#
        checkTrue("a non-success subtype is a failure",
                  ClaudeCodeChat.parseStreamLine(oddResult) == .result(text: "stopped", sessionId: nil, isError: true))

        // ── The child environment ────────────────────────────────────────────

        print("ClaudeCodeChat.environment")
        let env = ClaudeCodeChat.environment(
            executable: "/opt/homebrew/bin/claude",
            base: ["ANTHROPIC_API_KEY": "sk-should-not-survive",
                   "ANTHROPIC_AUTH_TOKEN": "tok",
                   "PATH": "/usr/bin"],
            home: "/Users/someone"
        )
        // A key left in the environment would quietly bill the API instead of the account.
        checkTrue("drops ANTHROPIC_API_KEY",    env["ANTHROPIC_API_KEY"] == nil)
        checkTrue("drops ANTHROPIC_AUTH_TOKEN", env["ANTHROPIC_AUTH_TOKEN"] == nil)
        checkTrue("PATH starts with the command's own folder",
                  env["PATH"]?.hasPrefix("/opt/homebrew/bin") ?? false)

        // ── Who is signed in ─────────────────────────────────────────────────

        print("ClaudeCodeChat.parseAuthStatus")
        let authJSON = #"{"loggedIn":true,"authMethod":"claude.ai","email":"someone@example.com"}"#
        let auth = ClaudeCodeChat.parseAuthStatus(authJSON)
        checkTrue("reads loggedIn",  auth.loggedIn)
        check("reads the email",     auth.email ?? "", "someone@example.com")
        check("reads the method",    auth.method ?? "", "claude.ai")
        checkTrue("survives noise around the JSON",
                  ClaudeCodeChat.parseAuthStatus("warning: update available\n" + authJSON).loggedIn)
        checkTrue("signed out on junk", !ClaudeCodeChat.parseAuthStatus("nope").loggedIn)

        // ── Turning a message into the right error ───────────────────────────

        print("ClaudeCodeChat.error(for:)")
        checkTrue("/login means not signed in",
                  ClaudeCodeChat.error(for: "Invalid API key · Please run /login") == .notSignedIn)
        checkTrue("unauthorized means not signed in",
                  ClaudeCodeChat.error(for: "401 Unauthorized") == .notSignedIn)
        checkTrue("anything else stays a plain failure",
                  ClaudeCodeChat.error(for: "the network is unreachable") == .runFailed("the network is unreachable"))

        // ── End to end against the stand-in command ──────────────────────────

        guard CommandLine.arguments.count > 1 else {
            print("\n(skipping the end-to-end tests: no stand-in command given)")
            finish()
        }
        let fake = CommandLine.arguments[1]

        print("ClaudeCodeChat.streamChat")
        let log = TokenLog()
        do {
            let (text, session) = try await ClaudeCodeChat.streamChat(
                prompt: "say hello", systemPrompt: "be brief", model: "sonnet",
                executable: fake
            ) { visible in log.calls.append(visible) }

            check("returns the answer", text, "hello from coucou")
            check("returns the session", session ?? "", "078a8466-fda1-4eea-a4bb-d12adaf0d39b")
            let calls = log.calls
            checkTrue("streamed at least once", !calls.isEmpty)
            check("the last token call is the answer", log.last, "hello from coucou")
            checkTrue("the thinking never reached the user",
                      !calls.contains { $0.contains("the user wants a greeting") })
        } catch {
            print("  ✗ unexpected failure: \(error)")
            failures += 1
        }

        do {
            let log2 = TokenLog()
            let (text, session) = try await ClaudeCodeChat.streamChat(
                prompt: "what did I ask", systemPrompt: "", model: "sonnet",
                resumeSessionId: "078a8466-fda1-4eea-a4bb-d12adaf0d39b", executable: fake
            ) { visible in log2.calls.append(visible) }
            check("a resumed turn answers in context", text, "you asked me to say hello")
            check("keeps the same session", session ?? "", "078a8466-fda1-4eea-a4bb-d12adaf0d39b")
        } catch {
            print("  ✗ unexpected failure on resume: \(error)")
            failures += 1
        }

        do {
            _ = try await ClaudeCodeChat.streamChat(
                prompt: "please FAIL", systemPrompt: "", model: "sonnet", executable: fake
            ) { _ in }
            print("  ✗ a failed run should have thrown")
            failures += 1
        } catch let e as ClaudeCodeChatError {
            checkTrue("a /login failure asks the user to sign in", e == .notSignedIn)
        } catch {
            print("  ✗ unexpected error type: \(error)")
            failures += 1
        }

        do {
            _ = try await ClaudeCodeChat.streamChat(
                prompt: "hi", systemPrompt: "", model: "sonnet",
                executable: "/nowhere/claude"
            ) { _ in }
            print("  ✗ a missing command should have thrown")
            failures += 1
        } catch let e as ClaudeCodeChatError {
            checkTrue("a missing command fails fast", e == .runFailed(e.localizedDescription) || e == .cliNotFound)
        } catch {
            print("  ✗ unexpected error type: \(error)")
            failures += 1
        }

        finish()
    }

    // MARK: - Finish

    private static func finish() -> Never {
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
