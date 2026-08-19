#!/bin/bash
# docs-brevity-guard.sh: a PreToolUse(Write|Edit|Bash) hook that injects the brevity bar
# before an agent instruction file is written. The shipped list is CLAUDE.md,
# CLAUDE.local.md, SKILL.md, AGENTS.md and AGENT.md.
#
# PreToolUse, not PostToolUse or Stop, because the guidance has to reach the model while
# it writes. A reminder that arrives after the file exists costs a whole extra turn of
# re-reading and rewriting, which is the behaviour this hook exists to avoid. Adding
# context is not a tool call, so a PreToolUse hook cannot re-trigger itself and no loop
# is possible.
#
# Three trigger points:
#   Write/Edit  tool_input.file_path names one of the files
#   Bash        the command writes one (heredoc, redirect, tee, sed -i, cp, mv, or
#               an interpreter one-liner such as python3 -c "open(...,'w')")
#   Bash        git commit with one of the files staged, the last gate before it lands
# The Bash arm matters because a heredoc or `sed -i` never touches the Write/Edit tools,
# and auto mode writes files that way.
#
# Token cost is bounded three ways: one reminder per file per session, a reminder ceiling,
# and a grep pre-filter that exits before python starts in the common case.
#
# Configuration. Every value is an environment variable:
#   DOCS_BREVITY_FILENAMES      Comma-separated file names to guard. A name whose stem is
#                               SKILL gets the skill bar. Every other name gets the
#                               CLAUDE.md bar. An empty value keeps the shipped list.
#   DOCS_BREVITY_CLAUDE_MD      Path to a file that replaces the CLAUDE.md bar.
#   DOCS_BREVITY_SKILL_MD       Path to a file that replaces the SKILL.md bar.
#   DOCS_BREVITY_COMMIT_MD      Path to a file that replaces the commit bar.
#   DOCS_BREVITY_MAX_REMINDERS  Reminders per session. Default 4. A value below 1 falls
#                               back to 4.
#   CLAUDE_PLUGIN_OPTION_BREVITY_GUARD
#                               Set by the doc-guards plugin. Any value other than
#                               true/1/yes/on exits the hook at once. An unset value
#                               keeps the hook enabled, so a standalone copy needs no
#                               configuration.
#
# Each bar stands alone. A replacement is injected verbatim, so keep it to roughly 100
# words. A path that cannot be read falls back to the shipped bar.
#
# Fails open: any parse error, missing git repo, or unwritable state directory exits 0
# with no output, so the write is never disturbed.

set -u

# Plugin opt-out, before any work. An unset value means enabled.
case "${CLAUDE_PLUGIN_OPTION_BREVITY_GUARD-}" in
  '' | [Tt][Rr][Uu][Ee] | 1 | [Yy][Ee][Ss] | [Oo][Nn]) ;;
  # Drain stdin before leaving, so the writer never sees a broken pipe.
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

DOCS_BREVITY_FILENAMES_DEFAULT='CLAUDE.md,CLAUDE.local.md,SKILL.md,AGENTS.md,AGENT.md'
export DOCS_BREVITY_FILENAMES_DEFAULT

INPUT=$(cat)

# Cheap pre-filter: only a guarded file name or a commit can match. The alternation is
# built from the same list the Python check reads, so the filter cannot drop a write the
# check would have caught.
_NAME_ALTERNATION=$(
  printf '%s' "${DOCS_BREVITY_FILENAMES:-$DOCS_BREVITY_FILENAMES_DEFAULT}" |
    sed -E -e 's/[][\\.^$*+?(){}|]/\\&/g' -e 's/[[:space:]]*,[[:space:]]*/|/g' \
           -e 's/^\|+|\|+$//g'
)
printf '%s' "$INPUT" | grep -qE "${_NAME_ALTERNATION:+$_NAME_ALTERNATION|}commit" || exit 0

# NOTE: heredoc fed to `read`, NOT nested in $(...). macOS stock bash 3.2 has a parser
# bug with here-docs inside command substitution. `read -d ''` returns non-zero at EOF,
# hence `|| true`.
read -r -d '' PYCODE <<'PYEOF' || true
import json
import os
import re
import subprocess
import sys
import time

try:
    MAX_REMINDERS = int(os.environ.get("DOCS_BREVITY_MAX_REMINDERS", "").strip() or 4)
except ValueError:
    MAX_REMINDERS = 4
if MAX_REMINDERS < 1:
    MAX_REMINDERS = 4

# Hook output strings are capped at 10000 characters. A bar file of your own can hold any
# text, so every injection is bounded here.
MAX_CONTEXT = 9500

# Not a bare /tmp path. This directory is pruned by unlink, and on a shared
# host a predictable name is a directory another user can create first, as a
# symlink pointing wherever they choose. The uid suffix makes it ours, and
# 0700 keeps it so.
STATE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "claude-docs-brevity-%d" % os.getuid())
STATE_TTL = 3 * 24 * 3600

# Longest name first, so CLAUDE.local.md wins over CLAUDE.md on the same path.
FILENAMES = sorted(
    {n.strip() for n in (os.environ.get("DOCS_BREVITY_FILENAMES")
                         or os.environ.get("DOCS_BREVITY_FILENAMES_DEFAULT", "")
                         ).split(",") if n.strip()},
    key=len, reverse=True)

DOC_RE = re.compile(
    r"(?:^|[\s'\"=/])((?:[\w.@/~-]*/)?(?:%s))(?!\w)"
    % "|".join(re.escape(n) for n in FILENAMES)) if FILENAMES else None
WRITE_HINT_RE = re.compile(
    r"(>>?|\btee\b|\bsed\b[^|;&]*-i|\bperl\b[^|;&]*-i|\bcp\b|\bmv\b|\bdd\b|\binstall\b)"
)
# An interpreter one-liner writes through a call, not a redirect, so the window before
# the path holds no hint and the call can sit any distance away. Both halves are needed:
# the flag that makes it a one-liner, and a call that opens a file for writing. A
# one-liner that only reads matches the first and not the second.
INTERPRETER_FLAG_RE = re.compile(
    r"\b(?:python3?|node|ruby|perl|deno|bun|php)\b[^|;&]*?\s-(?:c|e|r)\b"
)
WRITE_CALL_RE = re.compile(
    r"\bwrite_?File(?:Sync)?\b|\bcreateWriteStream\b|\bwrite_text\b"
    r"|\bfile_put_contents\b|\bFile\.write\b"
    r"|\bopen\s*\([^)]*['\"][wax]"
)
GIT_COMMIT_RE = re.compile(r"\bgit\s+(?:-\S+\s+)*commit\b")

def _override(var, default):
    """Your own bar, if you wrote one. An unreadable path falls back."""
    path = os.environ.get(var)
    if path:
        try:
            with open(path) as fh:
                return fh.read().strip()
        except OSError:
            pass
    return default


CLAUDE_MD = """Agent instruction file brevity bar - {path}

Keep only what the directory cannot tell the reader itself: cross-file invariants,
ordering constraints, cascade and side effects fired from elsewhere, and footguns named
with the symptom that reveals them. Cut purpose sections, file and class listings,
responsibility tables, and anything a reader gets from the folder itself.
Write the present state, never the history. Make each rule imperative, one instruction
per sentence. Write no file rather than a thin one.

"""

SKILL_MD = """SKILL.md brevity bar - {path}

Write imperative steps, not documentation. Put the condition first ("If the token is
expired, refresh it"). Name the failure each step prevents. Write the frontmatter
description as when to trigger the skill, not what it is. Cut background prose, restated
context, and anything the reader derives from the repo. Move long references, tables, and
examples into separate files the skill loads on demand."""

COMMIT = """Committing {path}. Before it lands, cut every line the folder or the repo
already tells the reader. Keep the prose in the present tense. Make each rule
imperative."""

CLAUDE_MD = _override("DOCS_BREVITY_CLAUDE_MD", CLAUDE_MD)
SKILL_MD = _override("DOCS_BREVITY_SKILL_MD", SKILL_MD)
COMMIT = _override("DOCS_BREVITY_COMMIT_MD", COMMIT)


def passthrough():
    sys.exit(0)


def state_path(session):
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session or "nosession")[:64]
    return os.path.join(STATE_DIR, safe)


def prune():
    """Drop session files older than STATE_TTL so the directory stays small.

    entry.is_file() follows a symlink, so it would happily report a link to
    somebody else's file as a plain file and unlink it. follow_symlinks=False
    asks about the entry itself.
    """
    cutoff = time.time() - STATE_TTL
    for entry in os.scandir(STATE_DIR):
        st = entry.stat(follow_symlinks=False)
        if entry.is_file(follow_symlinks=False) and st.st_mtime < cutoff:
            os.unlink(entry.path)


def claim(session, key):
    """True the first time this session asks about `key`, False on every repeat."""
    path = state_path(session)
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(path):
            with open(path) as fh:
                seen = fh.read().split("\n")
        else:
            prune()
            seen = []
        if key in seen or len(seen) >= MAX_REMINDERS:
            return False
        with open(path, "a") as fh:
            fh.write(("\n" if seen else "") + key)
        return True
    except OSError:
        return False


def emit(text):
    if len(text) > MAX_CONTEXT:
        text = text[:MAX_CONTEXT].rstrip() + "\n[bar truncated]"
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": text,
        }
    }))
    sys.exit(0)


def kind_of(path):
    """Return skill for a SKILL-stemmed name, claude for any other guarded name."""
    base = os.path.basename((path or "").strip())
    if base not in FILENAMES:
        return None
    return "skill" if base.split(".")[0].upper() == "SKILL" else "claude"


def note_for(kind, path):
    # replace, not format. A bar file of your own holding a brace, a JSON
    # snippet or a code example would make .format raise, the hook exit 1, and
    # Claude Code report a hook error on every matching write.
    return (CLAUDE_MD if kind == "claude" else SKILL_MD).replace("{path}", path)


def staged_docs(cwd):
    """Guarded paths in the index, or [] when git cannot answer."""
    try:
        out = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=cwd or None, capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if out.returncode != 0:
        return []
    return [line for line in out.stdout.split("\n") if kind_of(line)]


def bash_targets(command):
    """Doc paths the command writes to. A read (cat, grep, less) yields nothing."""
    targets = []
    if DOC_RE is None:
        return targets
    interpreter = bool(INTERPRETER_FLAG_RE.search(command)
                       and WRITE_CALL_RE.search(command))
    for match in DOC_RE.finditer(command):
        window = command[max(0, match.start() - 60):match.start()]
        if interpreter or WRITE_HINT_RE.search(window) or "<<" in window:
            targets.append(match.group(1))
    return targets


try:
    data = json.load(sys.stdin)
except Exception:
    passthrough()

session = data.get("session_id") or ""
tool = data.get("tool_name") or ""
tool_input = data.get("tool_input") or {}

if tool in ("Write", "Edit", "NotebookEdit"):
    file_path = tool_input.get("file_path") or ""
    kind = kind_of(file_path)
    if kind and claim(session, os.path.abspath(file_path)):
        emit(note_for(kind, file_path))
    passthrough()

if tool != "Bash":
    passthrough()

command = tool_input.get("command") or ""

for target in bash_targets(command):
    kind = kind_of(target)
    if kind and claim(session, target):
        emit(note_for(kind, target))

if GIT_COMMIT_RE.search(command):
    docs = staged_docs(data.get("cwd") or "")
    if docs and claim(session, "commit-gate"):
        emit(COMMIT.replace("{path}", ", ".join(docs[:5])))

passthrough()
PYEOF

printf '%s' "$INPUT" | python3 -c "$PYCODE"
