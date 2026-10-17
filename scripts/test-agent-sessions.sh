#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-agent-sessions.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Stands in for both `claude` and `codex`, so this test needs neither tool,
# nor an account, nor a network.
FAKE="$TEST_DIR/agent-cli"
cp tests/fake_agent_cli.sh "$FAKE"
chmod +x "$FAKE"

swiftc -swift-version 6 -warnings-as-errors \
    NotchBuddy/Sources/App/ClaudeCodeChat.swift \
    NotchBuddy/Sources/App/AgentSessionIndex.swift \
    NotchBuddy/Sources/App/AgentSessionRunner.swift \
    tests/AgentSessionTests.swift \
    -o "$TEST_DIR/agent-session-tests"

"$TEST_DIR/agent-session-tests" "$FAKE"
