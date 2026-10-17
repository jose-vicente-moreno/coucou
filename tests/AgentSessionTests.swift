import Foundation

// Tests for AgentSessionIndex and AgentSessionRunner: finding the agent sessions
// that have stopped, and continuing one or several of them.
//
// Run by scripts/test-agent-sessions.sh. Argument 1 is the path of
// tests/fake_agent_cli.sh, which stands in for `claude` and `codex`; the
// launching tests are skipped when it is absent. Nothing here needs the real
// tools, an account or a network.

@main
@MainActor
enum AgentSessionTests {

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

    // MARK: - Fixtures

    /// A home directory holding two Claude projects and one Codex session, with
    /// one project inside a repository and one outside it.
    static func makeFixture() -> String {
        let fm = FileManager.default
        let rawRoot = NSTemporaryDirectory() + "coucou-agent-tests-" + UUID().uuidString
        try? fm.createDirectory(atPath: rawRoot, withIntermediateDirectories: true)
        // Resolved only once it exists: /var is a symlink to /private/var on
        // macOS, and the launched command reports the resolved path as its
        // working directory. Resolving a path that is not there yet is a no-op.
        let root = URL(fileURLWithPath: rawRoot).resolvingSymlinksInPath().path
        let repo = root + "/work/myrepo"
        let loose = root + "/scratch/batch-001"
        for dir in [repo + "/.git", loose] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Claude: ~/.claude/projects/<slug>/<uuid>.jsonl
        let projects = root + "/.claude/projects"
        let repoProject = projects + "/-work-myrepo"
        let looseProject = projects + "/-scratch-batch-001"
        for dir in [repoProject, looseProject] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // Two sessions in the same folder: only the newest should be listed.
        write(repoProject + "/aaaaaaaa-1111-2222-3333-444444444444.jsonl", claudeLines(cwd: repo))
        write(repoProject + "/bbbbbbbb-1111-2222-3333-444444444444.jsonl", claudeLines(cwd: repo))
        write(looseProject + "/cccccccc-1111-2222-3333-444444444444.jsonl", claudeLines(cwd: loose))
        // A file that is not a transcript, and a broken one.
        write(repoProject + "/notes.jsonl", "not json at all\n")
        write(repoProject + "/dddddddd-1111-2222-3333-444444444444.jsonl", "{oops\n")

        // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
        let codexDay = root + "/.codex/sessions/2026/10/16"
        try? fm.createDirectory(atPath: codexDay, withIntermediateDirectories: true)
        write(codexDay + "/rollout-2026-10-16T19-00-56-eeeeeeee-1111-2222-3333-444444444444.jsonl",
              codexLines(cwd: repo))

        // Make the newest Claude session unambiguous.
        touch(repoProject + "/bbbbbbbb-1111-2222-3333-444444444444.jsonl", minutesAgo: 1)
        touch(repoProject + "/aaaaaaaa-1111-2222-3333-444444444444.jsonl", minutesAgo: 30)
        return root
    }

    static func claudeLines(cwd: String) -> String {
        // `cwd` deliberately absent from the first line: the real transcripts
        // open with an entry that does not carry it.
        """
        {"type":"system","sessionId":"x","timestamp":"2026-10-16T19:00:00Z"}
        {"type":"assistant","message":{"role":"assistant"}}
        {"type":"user","cwd":"\(cwd)","timestamp":"2026-10-16T19:00:01Z"}

        """
    }

    static func codexLines(cwd: String) -> String {
        """
        {"type":"session_meta","payload":{"cwd":"\(cwd)","id":"eeeeeeee"}}
        {"type":"event","payload":{}}

        """
    }

    static func write(_ path: String, _ contents: String) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `/private/var/...` and `/var/...` are the same folder on macOS.
    static func withoutPrivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    static func touch(_ path: String, minutesAgo: Int) {
        let date = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    // MARK: - Entry point

    static func main() async {
        let home = makeFixture()
        let repo = home + "/work/myrepo"
        let loose = home + "/scratch/batch-001"

        // ── Reading the session id out of a file name ────────────────────────

        print("AgentSessionIndex file names")
        check("claude id is the stem",
              AgentSessionIndex.claudeSessionId(fromFileName: "aaaaaaaa-1111-2222-3333-444444444444.jsonl") ?? "",
              "aaaaaaaa-1111-2222-3333-444444444444")
        checkTrue("a non-uuid claude file is skipped",
                  AgentSessionIndex.claudeSessionId(fromFileName: "notes.jsonl") == nil)
        // The timestamp has dashes of its own, so the id is the tail.
        check("codex id is the tail of the stem",
              AgentSessionIndex.codexSessionId(
                fromFileName: "rollout-2026-10-16T19-00-56-01a145a8-da03-72d0-bca0-c74983afd3bb.jsonl") ?? "",
              "01a145a8-da03-72d0-bca0-c74983afd3bb")
        checkTrue("a file that is not a rollout is skipped",
                  AgentSessionIndex.codexSessionId(fromFileName: "something.jsonl") == nil)
        checkTrue("uuid shape is checked", !AgentSessionIndex.isUUID("not-a-uuid"))

        // ── Reading the folder out of a transcript ───────────────────────────

        print("AgentSessionIndex working directory")
        check("claude cwd found past the first line",
              AgentSessionIndex.claudeCwd(inLines: claudeLines(cwd: "/a/b").split(separator: "\n").map(String.init)) ?? "",
              "/a/b")
        check("codex cwd read from session_meta",
              AgentSessionIndex.codexCwd(inLines: codexLines(cwd: "/c/d").split(separator: "\n").map(String.init)) ?? "",
              "/c/d")
        checkTrue("no cwd gives nil", AgentSessionIndex.claudeCwd(inLines: ["{}"]) == nil)
        checkTrue("broken json does not crash", AgentSessionIndex.claudeCwd(inLines: ["{oops"]) == nil)

        // ── Noise filters ────────────────────────────────────────────────────

        print("AgentSessionIndex filters")
        checkTrue("/tmp is throwaway",           AgentSessionIndex.isThrowaway("/tmp/x", home: home))
        checkTrue("var folders is throwaway",    AgentSessionIndex.isThrowaway("/private/var/folders/x/T", home: home))
        checkTrue("the root is throwaway",       AgentSessionIndex.isThrowaway("/", home: home))
        checkTrue("home itself is throwaway",    AgentSessionIndex.isThrowaway(home, home: home))
        // Job scratch usually sits inside a checked-in ~/.claude, so the
        // repository test alone would let it through.
        checkTrue("job scratch is throwaway",    AgentSessionIndex.isThrowaway(home + "/.claude/jobs/abc/tmp", home: home))
        checkTrue("a real project is not",
                  !AgentSessionIndex.isThrowaway("/Users/someone/code/myrepo", home: "/Users/someone"))
        checkTrue("a repository is recognised",  AgentSessionIndex.isInRepository(repo))
        checkTrue("a folder outside one is not", !AgentSessionIndex.isInRepository(loose))

        // ── Collapsing the list ──────────────────────────────────────────────

        print("AgentSessionIndex grouping")
        let now = Date()
        let older = ResumableSession(agent: .claudeCode, sessionId: "old", cwd: "/p",
                                     lastActivity: now.addingTimeInterval(-600))
        let newer = ResumableSession(agent: .claudeCode, sessionId: "new", cwd: "/p",
                                     lastActivity: now)
        let other = ResumableSession(agent: .codex, sessionId: "codex", cwd: "/p",
                                     lastActivity: now.addingTimeInterval(-60))
        let grouped = AgentSessionIndex.groupedByFolder([older, newer, other])
        check("one row per folder and agent", String(grouped.count), "2")
        check("the newest session wins", grouped.first?.sessionId ?? "", "new")
        checkTrue("a different agent keeps its own row",
                  grouped.contains { $0.agent == .codex })

        // ── Merging what the hooks know ──────────────────────────────────────

        print("AgentSessionIndex merge")
        let fromDisk = ResumableSession(agent: .claudeCode, sessionId: "s1", cwd: repo, lastActivity: now)
        var fromHooks = ResumableSession(agent: .claudeCode, sessionId: "s1", cwd: repo, lastActivity: now)
        fromHooks.hostApp = "Terminal"
        fromHooks.bundleId = "com.apple.Terminal"
        let merged = AgentSessionIndex.merged(disk: [fromDisk], live: [fromHooks])
        check("the merge keeps one row", String(merged.count), "1")
        check("the terminal comes from the hooks", merged.first?.bundleId ?? "", "com.apple.Terminal")

        var working = fromHooks
        working.isWorking = true
        let waiting = AgentSessionIndex.waiting(disk: [fromDisk], live: [working], home: home, throwawayRoots: [])
        check("a session still working is not offered", String(waiting.count), "0")

        // ── The whole scan over the fixture ──────────────────────────────────

        print("AgentSessionIndex scan")
        let rows = AgentSessionIndex.scan(home: home, now: now, window: 24 * 60 * 60, throwawayRoots: [])
        check("only the repository folders are listed", String(rows.count), "2")
        checkTrue("the claude session is there",
                  rows.contains { $0.agent == .claudeCode && $0.cwd == repo })
        checkTrue("the codex session is there",
                  rows.contains { $0.agent == .codex && $0.cwd == repo })
        checkTrue("the newest claude session of the folder won",
                  rows.first(where: { $0.agent == .claudeCode })?.sessionId
                    == "bbbbbbbb-1111-2222-3333-444444444444")
        checkTrue("the folder outside a repository is left out",
                  !rows.contains { $0.cwd == loose })
        check("the project name is the folder",
              rows.first(where: { $0.agent == .claudeCode })?.projectName ?? "", "myrepo")

        let everything = AgentSessionIndex.scan(home: home, now: now, window: 24 * 60 * 60, projectsOnly: false, throwawayRoots: [])
        checkTrue("turning the filter off shows the loose folder too",
                  everything.contains { $0.cwd == loose })

        let narrow = AgentSessionIndex.scan(home: home, now: now, window: 60, throwawayRoots: [])
        checkTrue("the window leaves out what is older",
                  !narrow.contains { $0.sessionId == "aaaaaaaa-1111-2222-3333-444444444444" })

        // ── The command line for each agent ──────────────────────────────────

        print("AgentSessionRunner arguments")
        check("claude resumes with -p",
              AgentSessionRunner.arguments(for: .claudeCode, sessionId: "s1", text: "go on").joined(separator: " "),
              "-p go on --resume s1")
        check("codex resumes with exec resume",
              AgentSessionRunner.arguments(for: .codex, sessionId: "s1", text: "go on").joined(separator: " "),
              "exec resume s1 go on")

        print("AgentSessionRunner environment")
        let env = AgentSessionRunner.environment(
            executable: "/opt/homebrew/bin/claude",
            base: ["ANTHROPIC_API_KEY": "sk-keep-me", "PATH": "/usr/bin"],
            home: home
        )
        // The opposite of the chat provider on purpose: this resumes the user's
        // own session and must not change how it authenticates.
        check("the api key is kept, not stripped", env["ANTHROPIC_API_KEY"] ?? "missing", "sk-keep-me")
        checkTrue("PATH starts with the command's folder", env["PATH"]?.hasPrefix("/opt/homebrew/bin") ?? false)
        check("no known terminal falls back to vscode", env["TERM_PROGRAM"] ?? "", "vscode")
        let pinned = AgentSessionRunner.environment(
            executable: "/opt/homebrew/bin/claude", bundleId: "com.apple.Terminal",
            base: [:], home: home
        )
        check("a known terminal is pinned", pinned["__CFBundleIdentifier"] ?? "", "com.apple.Terminal")

        // ── Launching, against the stand-in command ──────────────────────────

        guard CommandLine.arguments.count > 1 else {
            print("\n(skipping the launch tests: no stand-in command given)")
            finish()
        }
        let fake = CommandLine.arguments[1]

        print("AgentRunLauncher")
        let launcher = AgentRunLauncher.shared
        var session = ResumableSession(agent: .claudeCode, sessionId: "run-1", cwd: repo, lastActivity: now)
        session.bundleId = "com.apple.Terminal"

        do {
            _ = try launcher.run(session: session, text: "   ", executableOverride: fake, home: home)
            print("  ✗ an empty instruction should have been refused")
            failures += 1
        } catch let e as AgentRunError {
            checkTrue("an empty instruction is refused", e == .emptyInstruction)
        } catch { print("  ✗ unexpected error: \(error)"); failures += 1 }

        var gone = session
        gone = ResumableSession(agent: .claudeCode, sessionId: "run-gone",
                                cwd: home + "/does-not-exist", lastActivity: now)
        do {
            _ = try launcher.run(session: gone, text: "go", executableOverride: fake, home: home)
            print("  ✗ a missing folder should have been refused")
            failures += 1
        } catch let e as AgentRunError {
            checkTrue("a missing folder is refused", e == .folderMissing(home + "/does-not-exist"))
        } catch { print("  ✗ unexpected error: \(error)"); failures += 1 }

        do {
            let process = try launcher.run(session: session, text: "carry on", executableOverride: fake, home: home)
            checkTrue("the run is tracked while it works", launcher.isRunning("run-1"))

            // While it is still going, a second one must be refused.
            do {
                _ = try launcher.run(session: session, text: "again", executableOverride: fake, home: home)
                print("  ✗ a second run on the same session should have been refused")
                failures += 1
            } catch let e as AgentRunError {
                checkTrue("a session already working is refused", e == .alreadyRunning("run-1"))
            }

            process.waitUntilExit()
            let log = (try? String(contentsOfFile:
                AgentSessionRunner.logURL(sessionId: "run-1", home: home).path, encoding: .utf8)) ?? ""
            let reportedPWD = log.split(separator: "\n").first { $0.hasPrefix("PWD=") }
                .map { String($0.dropFirst(4)) } ?? "none"
            // The shell reports /private/var/... where Foundation hands back
            // /var/..., so both sides are normalised before comparing.
            check("it ran in the session's folder", withoutPrivate(reportedPWD), withoutPrivate(repo))
            checkTrue("it passed --resume with the session id", log.contains("ARG=--resume") && log.contains("ARG=run-1"))
            checkTrue("it passed the instruction", log.contains("ARG=carry on"))
            checkTrue("it pinned the terminal", log.contains("CFBUNDLE=com.apple.Terminal"))
        } catch {
            print("  ✗ unexpected failure launching: \(error)")
            failures += 1
        }

        // The cap exists because each one of these is real work in a real repo.
        let many = (1...20).map {
            ResumableSession(agent: .claudeCode, sessionId: "bulk-\($0)", cwd: repo, lastActivity: now)
        }
        let outcome = launcher.runAll(sessions: many, text: "status please",
                                      executableOverride: fake, home: home)
        check("send to all stops at the cap", String(outcome.started.count),
              String(AgentRunLauncher.maxConcurrent))

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
