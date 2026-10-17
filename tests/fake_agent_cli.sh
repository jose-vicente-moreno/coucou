#!/usr/bin/env bash
# Stand-in for `claude` and `codex` in AgentSessionTests.
#
# It prints what the runner gave it, so the test can assert the exact command
# line, the working directory and the environment without the real tools, an
# account or a network. The runner sends stdout to its own per-session log file,
# which is where the test reads this back from.
set -u

# A short pause so the test can prove a second run on the same session is refused
# while the first is still going.
sleep 0.4

echo "PWD=$PWD"
echo "ARGC=$#"
for arg in "$@"; do
    echo "ARG=$arg"
done
echo "TERM_PROGRAM=${TERM_PROGRAM:-unset}"
echo "CFBUNDLE=${__CFBundleIdentifier:-unset}"
# The runner must NOT strip this: resuming the user's own session has to keep
# authenticating the way that session already did.
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-unset}"
exit 0
