#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-claude-code-chat.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# The stand-in command replays a recorded stream, so this test needs neither the
# real `claude` binary, nor an account, nor a network.
FAKE="$TEST_DIR/claude"
cp tests/fake_claude_code.sh "$FAKE"
chmod +x "$FAKE"

swiftc -swift-version 6 -warnings-as-errors \
    NotchBuddy/Sources/App/ClaudeCodeChat.swift \
    tests/ClaudeCodeChatTests.swift \
    -o "$TEST_DIR/claude-code-chat-tests"

"$TEST_DIR/claude-code-chat-tests" "$FAKE"
