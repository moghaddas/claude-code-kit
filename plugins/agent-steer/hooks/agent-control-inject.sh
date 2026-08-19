#!/bin/bash
# PreToolUse(*) hook. Delivers a mid-run steer to a RUNNING subagent.
#
# A message to a teammate sits in a queue that is read at a turn boundary, so
# `SendMessage` reaches an agent after its task ends. This delivers by pull
# instead. The lead writes <control dir>/<name>.md, and the hook injects it on
# the agent's next tool call, once per write.
#
#   - Subagents only. Main-conversation tool calls carry no `agent_id`.
#   - Keyed by the `name` passed to the Agent tool, so an unnamed agent is never
#     targeted.
#   - A control file past the age cutoff is ignored. A leftover from an earlier
#     run must not steer a new agent that reuses the track name.
#   - Never sets permissionDecision. The tool call keeps its normal permission
#     flow. This hook only adds context.
#   - Fails open. Any parse, IO or python error exits 0 with no output.
#
# Configuration. Each setting reads a plugin option first and a plain variable
# second, so one script serves both the plugin and a standalone install:
#
#   CLAUDE_PLUGIN_OPTION_AGENT_STEER_CONTROL_DIR      AGENT_STEER_DIR
#   CLAUDE_PLUGIN_OPTION_AGENT_STEER_MAX_AGE_MINUTES  AGENT_STEER_MAX_AGE_MINUTES
#   CLAUDE_PLUGIN_OPTION_AGENT_STEER_MAX_CHARS        AGENT_STEER_MAX_CHARS

set -u

INPUT=$(cat)

# Fast path: main-conversation calls carry no agent_id. One grep, no python.
printf '%s' "$INPUT" | grep -q '"agent_id"' || exit 0

AGENT_ID=$(printf '%s' "$INPUT" |
  sed -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$AGENT_ID" ] || exit 0

# agent_id is "<name>@<team>"; the name is what the lead knows and addresses.
NAME=${AGENT_ID%%@*}
[ -n "$NAME" ] || exit 0
case "$NAME" in */*|.|..) exit 0 ;; esac   # never let a name escape the directory

STEER_DIR=${CLAUDE_PLUGIN_OPTION_AGENT_STEER_CONTROL_DIR:-${AGENT_STEER_DIR:-$HOME/.claude/agent-control}}
MAX_AGE_MINUTES=${CLAUDE_PLUGIN_OPTION_AGENT_STEER_MAX_AGE_MINUTES:-${AGENT_STEER_MAX_AGE_MINUTES:-720}}
MAX_CHARS=${CLAUDE_PLUGIN_OPTION_AGENT_STEER_MAX_CHARS:-${AGENT_STEER_MAX_CHARS:-9000}}

# A value that is not a plain integer falls back to the default. `find -mmin`
# and python both reject a bad value, and the hook must not fail on config.
case "$MAX_AGE_MINUTES" in ''|*[!0-9]*) MAX_AGE_MINUTES=720 ;; esac
case "$MAX_CHARS"       in ''|*[!0-9]*) MAX_CHARS=9000 ;; esac

CONTROL="$STEER_DIR/$NAME.md"
[ -f "$CONTROL" ] || exit 0

# Ignore a leftover from an earlier run on the same name.
[ -n "$(find "$CONTROL" -mmin "+$MAX_AGE_MINUTES" 2>/dev/null)" ] && exit 0

# One delivery per write, per agent. The control directory is part of the key,
# so two directories holding the same agent name keep separate markers.
KEY=$(printf '%s' "$STEER_DIR/$AGENT_ID" | cksum | cut -d' ' -f1)
MARKER="${TMPDIR:-/tmp}/claude-agent-control/$KEY"
mkdir -p "${MARKER%/*}" 2>/dev/null || exit 0
if [ -e "$MARKER" ] && [ ! "$CONTROL" -nt "$MARKER" ]; then
  exit 0
fi

# NOTE: heredoc fed to `read`, NOT nested in $(...). macOS stock bash 3.2 has a
# parser bug with here-docs inside command substitution.
read -r -d '' PYCODE <<'PYEOF' || true
import json, os, sys

# Claude Code caps a hook's output at 10,000 characters. Over-limit output goes
# to a file and is replaced with a preview plus a path, so the steer never
# arrives inline and the failure looks exactly like a delivery.
HOOK_OUTPUT_CAP = 10000

WRAPPER = (
    "Mid-run steer from your team lead, delivered from %s.\n"
    "It is newer than your brief and overrides any part of the brief it "
    "contradicts. Act on it before your next unit of work. Do not reply "
    "to it with SendMessage unless it asks you to.\n\n%s"
)
NOTICE = '\n\n[truncated at %d characters]'

path = os.environ['CONTROL_FILE']
max_chars = int(os.environ['AGENT_STEER_MAX_CHARS'])

try:
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read().strip()
except Exception:
    sys.exit(0)

if not text:
    sys.exit(0)


def build(body):
    return json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": WRAPPER % (path, body),
        }
    })


def render(body):
    # The notice always states the length actually delivered, so a reader can
    # tell how much of the steer arrived.
    note = NOTICE % len(body) if len(body) < len(text) else ''
    return build(body + note)


reserve = len(NOTICE % HOOK_OUTPUT_CAP)
body = text[:min(max_chars, HOOK_OUTPUT_CAP)]
out = render(body)

# The wrapper prose, the file path and JSON escaping all count toward the same
# cap, so the finished output is what must fit it. Trim by the measured excess.
while len(out) > HOOK_OUTPUT_CAP and len(body) > reserve:
    body = body[:max(0, len(body) - (len(out) - HOOK_OUTPUT_CAP) - reserve)]
    out = render(body)

if len(out) > HOOK_OUTPUT_CAP:
    sys.exit(0)
print(out)
PYEOF

OUT=$(CONTROL_FILE="$CONTROL" AGENT_STEER_MAX_CHARS="$MAX_CHARS" \
  python3 -c "$PYCODE" 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

: > "$MARKER" 2>/dev/null || exit 0
printf '%s' "$OUT"
