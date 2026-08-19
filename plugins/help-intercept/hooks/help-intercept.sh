#!/usr/bin/env bash
# help-intercept.sh. A UserPromptSubmit hook for Claude Code.
#
# Installable as the `help-intercept` Claude Code plugin, with the rest of the kit:
#   https://github.com/moghaddas/claude-code-kit
#
# Goal: make `/<command> --help` (and `-h`) print the command's help text with
# ZERO model tokens. The hook spots that invocation in the raw prompt and
# returns the text through the UserPromptSubmit block contract, so the model
# never runs.
#
# Contract (Claude Code 2.1.x):
#   {"decision":"block","reason":"<text>"} on UserPromptSubmit
#     -> the prompt never reaches the model, `reason` goes to the USER only and
#        never enters the context window.
#   UserPromptSubmit fires for skill and plugin-skill invocations and receives
#   the raw typed text (`/jira --help`), not the expanded SKILL.md body.
#
# Source of truth: the first fenced code block under the "## Help" heading of
# the matching skills/<cmd>/SKILL.md. Nothing is duplicated, so the hook and the
# skill cannot drift apart.
#
# Where it looks for that file, first match wins:
#   $CC_HELP_SKILL_ROOTS   colon-separated list of skills/ directories
#   $CLAUDE_PLUGIN_ROOT/skills
#   <this hook>/../skills          (drop the hook in a plugin's hooks/ dir)
#   $CLAUDE_PROJECT_DIR/.claude/skills
#   ./.claude/skills
#   ~/.claude/skills
#
# Configuration. A plugin option wins over the bare environment variable of the
# same name, except for the roots, where both lists are searched:
#   CC_HELP_HEADING       Heading text that opens the help section. Default
#                         "Help". Matched case-insensitively at heading level 1
#                         to 3.
#   CC_HELP_SKILL_ROOTS   Extra skills/ directories to search first. Separate
#                         them with the path separator, a comma, or a newline.
#   CLAUDE_PLUGIN_OPTION_CC_HELP_HEADING
#   CLAUDE_PLUGIN_OPTION_CC_HELP_SKILL_ROOTS
#                         The same two values, set by the help-intercept plugin.
#
# Wire it in settings.json:
#   {"hooks":{"UserPromptSubmit":[{"hooks":[
#     {"type":"command","command":"~/.claude/hooks/help-intercept.sh"}]}]}}

set -euo pipefail

payload="$(cat)"

# Cheap pre-filter: skip the interpreter startup on most prompts. Continue only
# if the payload mentions a help flag. This gate is about speed, the match in
# Python below decides correctness.
if ! printf '%s' "$payload" | grep -qE -- '-h|--help'; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOOK_DIR="$HOOK_DIR" PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import re
import sys

# The reason string is capped at 10000 characters by Claude Code. Over the cap it is
# written to a file and replaced with a preview, which defeats the point of the hook, so
# a long help block is trimmed here instead.
MAX_REASON = 9500

payload = os.environ.get("PAYLOAD", "")

try:
    data = json.loads(payload)
except Exception:
    sys.exit(0)

prompt = (data.get("prompt") or "").strip()
if not prompt:
    sys.exit(0)

# Match a slash command. The `<namespace>:` prefix is optional, so both
# `/myplugin:jira --help` and `/jira --help` land here. <cmd> is a skill
# directory name: lowercase letters, digits, hyphens and underscores. Both
# segments take the same character set, so a directory named my_skill resolves.
m = re.match(r"^/(?:[a-z][a-z0-9_-]*:)?([a-z][a-z0-9_-]*)\b(.*)$", prompt, re.DOTALL)
if not m:
    sys.exit(0)
cmd, rest = m.group(1), m.group(2)

# Require -h / --help as a standalone token in the remainder.
if not re.search(r"(?:^|\s)(?:-h|--help)(?:\s|$)", rest):
    sys.exit(0)


def option(name, default=""):
    """The plugin option, then the bare environment variable, then the default."""
    for var in ("CLAUDE_PLUGIN_OPTION_" + name, name):
        value = os.environ.get(var, "").strip()
        if value:
            return value
    return default


HEADING_RE = re.compile(
    r"^#{1,3}\s+%s(?!\w)" % re.escape(option("CC_HELP_HEADING", "Help")), re.I)


def configured_roots():
    """Roots from both configuration sources, in order, split on any separator."""
    roots = []
    for var in ("CLAUDE_PLUGIN_OPTION_CC_HELP_SKILL_ROOTS", "CC_HELP_SKILL_ROOTS"):
        raw = os.environ.get(var, "")
        for part in re.split(r"[%s\n,]" % re.escape(os.pathsep), raw):
            part = part.strip()
            if part and part not in roots:
                roots.append(part)
    return roots


def skill_roots():
    """Every skills/ directory to search, in priority order."""
    roots = configured_roots()
    # Installed as its own plugin, both plugin-aware roots point inside this plugin,
    # which ships no skills. Set CC_HELP_SKILL_ROOTS to reach a plugin's skills.
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if plugin_root:
        roots.append(os.path.join(plugin_root, "skills"))
    hook_dir = os.environ.get("HOOK_DIR", "")
    if hook_dir:
        roots.append(os.path.join(os.path.dirname(hook_dir), "skills"))
    project = os.environ.get("CLAUDE_PROJECT_DIR", "") or os.getcwd()
    roots.append(os.path.join(project, ".claude", "skills"))
    roots.append(os.path.expanduser("~/.claude/skills"))
    return roots


skill_md = ""
for root in skill_roots():
    candidate = os.path.join(root, cmd, "SKILL.md")
    if os.path.isfile(candidate):
        skill_md = candidate
        break
if not skill_md:
    sys.exit(0)

try:
    with open(skill_md, encoding="utf-8") as f:
        lines = f.read().splitlines()
except Exception:
    sys.exit(0)


def extract_help_block(lines):
    """First fenced code block under the configured help heading."""
    in_help = in_fence = False
    collected = []
    for line in lines:
        if not in_help:
            if HEADING_RE.match(line):
                in_help = True
            continue
        if not in_fence:
            # A new heading before any fence means the Help section had no block.
            if re.match(r"^#{1,6}\s+\S", line):
                break
            if re.match(r"^```", line):
                in_fence = True
            continue
        if re.match(r"^```", line):  # closing fence
            break
        collected.append(line)
    return "\n".join(collected).rstrip()


help_text = extract_help_block(lines)
if not help_text:
    # No block to print, so let the prompt through to the model unchanged.
    sys.exit(0)

if len(help_text) > MAX_REASON:
    help_text = (help_text[:MAX_REASON].rstrip()
                 + "\n...\nHelp text trimmed. Read %s for the rest." % skill_md)

print(json.dumps({
    "decision": "block",
    "reason": help_text,
    "hookSpecificOutput": {"hookEventName": "UserPromptSubmit"},
}))
PY
