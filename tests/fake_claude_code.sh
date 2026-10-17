#!/usr/bin/env bash
# A stand-in for the `claude` command, for ClaudeCodeChatTests.
#
# It prints the same NDJSON stream the real command prints with
# `--output-format stream-json --include-partial-messages`, recorded from
# Claude Code 2.1.301, so the test covers the real shapes without a network
# call, an account, or the CLI being installed on the machine running CI.
#
# Behaviour:
#   --resume <id>        answers as a second turn, same session id
#   prompt contains FAIL answers with an error result and exits 1
#   auth status          prints the signed-in JSON
set -u

SESSION="078a8466-fda1-4eea-a4bb-d12adaf0d39b"

# `claude auth status`
if [ "${1:-}" = "auth" ]; then
    echo '{"loggedIn":true,"authMethod":"claude.ai","email":"someone@example.com","subscriptionType":"enterprise"}'
    exit 0
fi

PROMPT=""
RESUMED="no"
want_prompt="no"
for arg in "$@"; do
    if [ "$want_prompt" = "yes" ]; then PROMPT="$arg"; want_prompt="no"; continue; fi
    case "$arg" in
        -p) want_prompt="yes" ;;
        --resume) RESUMED="yes" ;;
    esac
done

emit_prelude() {
    echo '{"type":"system","subtype":"init","session_id":"'"$SESSION"'"}'
    echo '{"type":"system","subtype":"status"}'
    echo '{"type":"stream_event","event":{"type":"message_start"}}'
}

emit_thinking() {
    # A reasoning model opens a thinking block first. None of it may reach the user.
    echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}'
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"the user wants a greeting"}}}'
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"abc123"}}}'
    echo '{"type":"stream_event","event":{"type":"content_block_stop"}}'
}

emit_tail() {
    echo '{"type":"stream_event","event":{"type":"message_delta"}}'
    echo '{"type":"stream_event","event":{"type":"message_stop"}}'
    echo '{"type":"rate_limit_event","rate_limit":{"status":"allowed"}}'
}

case "$PROMPT" in
    *FAIL*)
        emit_prelude
        echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid API key · Please run /login","session_id":"'"$SESSION"'"}'
        exit 1
        ;;
esac

emit_prelude
emit_thinking
echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}'

if [ "$RESUMED" = "yes" ]; then
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"you asked "}}}'
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"me to say hello"}}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"you asked me to say hello"}]}}'
    echo '{"type":"stream_event","event":{"type":"content_block_stop"}}'
    emit_tail
    echo '{"type":"result","subtype":"success","is_error":false,"result":"you asked me to say hello","session_id":"'"$SESSION"'"}'
else
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"h"}}}'
    echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ello from coucou"}}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hello from coucou"}]}}'
    echo '{"type":"stream_event","event":{"type":"content_block_stop"}}'
    emit_tail
    echo '{"type":"result","subtype":"success","is_error":false,"result":"hello from coucou","session_id":"'"$SESSION"'"}'
fi
exit 0
