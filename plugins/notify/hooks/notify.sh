#!/usr/bin/env bash
# Claude Code notification hook. One OSC write, two events.
#
#   Notification -> "Claude needs you"   (permission prompt, idle wait)
#   Stop         -> "finished"           (only when the turn ran long enough)
#
# Wire both in ~/.claude/settings.json. The event is the first argument.
#
# Installable as the `notify` Claude Code plugin, with the rest of the kit:
#   https://github.com/moghaddas/claude-code-kit
#
# WHY NOT /dev/tty. Claude Code runs with no controlling terminal, so `tty`
# prints "not a tty" and every write to /dev/tty fails. The stdio is still a
# pty, only not a controlling one, so this script resolves it from the process
# tree instead. A terminal synthesised by pty.fork() in a test DOES give
# /dev/tty, which is why a harness can show this working while the live session
# stays silent.
#
# WHY THE PTY IS THE RIGHT CHANNEL. On a headless or remote host a local
# notifier reaches nobody: no display, no org.freedesktop.Notifications. The pty
# is the one channel that crosses back to the machine you are sitting at. VS Code
# renders OSC 777 through the terminal-osc-notifier extension. A multiplexer
# between this process and the editor has to forward the sequence outward, or the
# banner stops there.
#
# WHICH OSC SEQUENCE. Terminals disagree, and a terminal that does not know the
# sequence drops it without an error. Pick the one your terminal reads:
#   777  VS Code (terminal-osc-notifier), tmux passthrough, urxvt. Carries a
#        title and a body as separate fields.
#   9    iTerm2. Carries a body only, so this script sends "title: body".
#   99   kitty, WezTerm, Ghostty. Two chunks, one for the title and one for the
#        body, both under one notification id.
# Set CC_NOTIFY_DEBUG=1 to print the resolved pty and the exact bytes written.
#
# Env:
#   CC_NOTIFY=off             disable entirely (also 0/false/no)
#   CC_NOTIFY_OSC             777 (default), 9, or 99
#   CC_NOTIFY_MIN_SECONDS=60  Stop stays quiet for turns shorter than this
#   CC_NOTIFY_MAX_BODY=180    body is truncated to this many characters
#   CC_NOTIFY_TITLE           title for both events
#   CC_NOTIFY_TITLE_DONE      title for Stop only, wins over CC_NOTIFY_TITLE
#   CC_NOTIFY_DEBUG=1         report the target and the bytes on stderr
#
# A plugin option wins over the matching CC_NOTIFY* variable:
#   CLAUDE_PLUGIN_OPTION_NOTIFY_OSC, CLAUDE_PLUGIN_OPTION_NOTIFY_TITLE,
#   CLAUDE_PLUGIN_OPTION_NOTIFY_TITLE_DONE

set -uo pipefail

# --- configuration ------------------------------------------------------------
# First non-blank value wins. Claude Code exports an unset plugin option as an
# empty string, which is why blank counts as absent.
first() {
  local v
  for v in "$@"; do
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 0
}

debug="${CC_NOTIFY_DEBUG:-}"
dbg() { [ -n "$debug" ] && printf 'cc-notify: %s\n' "$1" >&2; return 0; }

case "${CC_NOTIFY:-on}" in
  off | 0 | false | no) dbg "disabled by CC_NOTIFY=${CC_NOTIFY}"; exit 0 ;;
esac

event="${1:-notification}"
payload="$(cat 2>/dev/null || true)"
min_seconds="${CC_NOTIFY_MIN_SECONDS:-60}"
max_body="${CC_NOTIFY_MAX_BODY:-180}"
case "$max_body" in ''|*[!0-9]*|0) max_body=180 ;; esac
osc="$(first "${CLAUDE_PLUGIN_OPTION_NOTIFY_OSC:-}" "${CC_NOTIFY_OSC:-}" "777")"

# --- resolve a writable pty ---------------------------------------------------
# Walk the ancestry for the first stdout that is a pty. /proc is Linux-only; on
# macOS the loop finds nothing and /dev/tty is the fallback, which works because
# a local session there does hold a controlling terminal.
target=""
if [ -d /proc ]; then
  p=$$
  for _ in 1 2 3 4 5 6; do
    link="$(readlink "/proc/$p/fd/1" 2>/dev/null || true)"
    case "$link" in
      /dev/pts/*) target="$link"; break ;;
    esac
    p="$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || true)"
    [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] || break
  done
fi
[ -n "$target" ] || target=/dev/tty
dbg "event=$event osc=$osc target=$target"
if ! [ -w "$target" ] 2>/dev/null; then
  dbg "target is not writable, nothing sent. No pty in the ancestry means the banner cannot leave this process."
  exit 0
fi

# --- build the banner ---------------------------------------------------------
# Line 1 is the body, line 2 the seconds since the last user turn (-1 unknown).
read -r -d '' _py <<'PY' || true
import json, os, subprocess, sys
from datetime import datetime, timezone

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}

max_body = 180
raw_max = os.environ.get("CC_NOTIFY_MAX_BODY") or ""
if raw_max.strip().isdigit() and int(raw_max) > 0:
    max_body = int(raw_max)

def g(k):
    return str(d.get(k) or "").replace("\n", " ").strip()

def scan(path, tail=200000):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > tail:
                fh.seek(size - tail)
            lines = fh.read().decode("utf-8", "replace").splitlines()
        if size > tail and lines:
            lines = lines[1:]          # the seek cuts the first line in half
    except Exception:
        return "", None
    text, user_ts = "", None
    for ln in lines:
        try:
            e = json.loads(ln)
        except Exception:
            continue
        kind = e.get("type")
        if kind == "user" and e.get("timestamp"):
            user_ts = e["timestamp"]
        elif kind == "assistant":
            msg = e.get("message")
            blocks = msg.get("content") if isinstance(msg, dict) else None
            for b in blocks if isinstance(blocks, list) else []:
                if isinstance(b, dict) and b.get("type") == "text":
                    t = " ".join((b.get("text") or "").split())
                    if t:
                        text = t
    return text, user_ts

text, user_ts = scan(g("transcript_path")) if g("transcript_path") else ("", None)
body = text[:max_body].rstrip() + "…" if len(text) > max_body else text
body = body or g("message") or "Claude needs your attention"

cwd = g("cwd")
label = ""
if cwd:
    project = os.path.basename(cwd)
    try:
        branch = subprocess.run(
            ["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
    except Exception:
        branch = ""
    label = f"{project} · {branch}" if branch and branch != project else project

elapsed = -1
if user_ts:
    try:
        started = datetime.fromisoformat(user_ts.replace("Z", "+00:00"))
        elapsed = int((datetime.now(timezone.utc) - started).total_seconds())
    except Exception:
        elapsed = -1

# A semicolon or BEL inside the body would end the OSC string early.
clean = lambda s: s.replace(";", ",").replace("\x07", " ").replace("\x1b", " ")
print(clean(f"{label}: {body}" if label else body))
print(elapsed)
PY

parsed="$(printf '%s' "$payload" | CC_NOTIFY_MAX_BODY="$max_body" python3 -c "$_py" 2>/dev/null)"
body="$(printf '%s' "$parsed" | sed -n '1p')"
elapsed="$(printf '%s' "$parsed" | sed -n '2p')"
[ -n "$body" ] || body="Claude needs your attention"
case "$elapsed" in ''|*[!0-9-]*) elapsed=-1 ;; esac

# A finished turn is only worth a banner when it ran long enough that you have
# probably looked away. Short exchanges you are watching stay silent.
#
# CC_NOTIFY_TITLE covers both events, so it costs you the needs-you / finished
# distinction. CC_NOTIFY_TITLE_DONE restores it for the Stop event.
title="$(first "${CLAUDE_PLUGIN_OPTION_NOTIFY_TITLE:-}" "${CC_NOTIFY_TITLE:-}" "Claude Code")"
if [ "$event" = "stop" ]; then
  if ! [ "$elapsed" -ge "$min_seconds" ] 2>/dev/null; then
    dbg "stop suppressed, elapsed=${elapsed}s below CC_NOTIFY_MIN_SECONDS=${min_seconds}"
    exit 0
  fi
  title="$(first "${CLAUDE_PLUGIN_OPTION_NOTIFY_TITLE_DONE:-}" "${CC_NOTIFY_TITLE_DONE:-}" \
                 "${CLAUDE_PLUGIN_OPTION_NOTIFY_TITLE:-}" "${CC_NOTIFY_TITLE:-}" "Claude Code: done")"
fi

# A semicolon in the title would end the OSC string early, the same way it does
# in the body. The body is cleaned in Python, the title here.
title="${title//;/,}"

# --- write the sequence -------------------------------------------------------
esc=$'\033'
bel=$'\007'
st=$'\033\\'

case "$osc" in
  777) seq="${esc}]777;notify;${title};${body}${bel}" ;;
  # OSC 9 carries a body and no title field, so the title is folded into the
  # body text. iTerm2 shows one line.
  9)   seq="${esc}]9;${title}: ${body}${bel}" ;;
  # OSC 99 sends the title and the body as two chunks under one id. d=0 marks
  # the first chunk as "more to come"; the second chunk takes the default d=1.
  99)  seq="${esc}]99;i=1:d=0:p=title;${title}${st}${esc}]99;i=1:p=body;${body}${st}" ;;
  *)
    printf 'cc-notify: CC_NOTIFY_OSC=%s is not 777, 9, or 99. Falling back to 777.\n' \
      "$osc" >&2
    seq="${esc}]777;notify;${title};${body}${bel}"
    ;;
esac

if [ -n "$debug" ]; then
  printf 'cc-notify: title=%s\n' "$title" >&2
  printf 'cc-notify: body=%s\n' "$body" >&2
  printf 'cc-notify: bytes=' >&2
  printf '%s' "$seq" | od -An -c | tr '\n' ' ' | tr -s ' ' >&2
  printf '\n' >&2
fi

printf '%s' "$seq" >"$target" 2>/dev/null || dbg "write to $target failed"
exit 0
