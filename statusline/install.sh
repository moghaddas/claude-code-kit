#!/usr/bin/env bash
#
# install.sh: point Claude Code's statusLine at claude-code-statusline.sh.
#
# A statusline cannot ship as a plugin. A plugin's bundled settings.json
# accepts only the `agent` and `subagentStatusLine` keys, so `statusLine` has
# to land in user settings, and this script is what puts it there.
#
#   install.sh              print the change, ask, then write it
#   install.sh --dry-run    print the change and exit, writing nothing
#   install.sh --yes        write it without asking
#   install.sh --uninstall  remove the statusLine key, and nothing else
#
# It edits one key with jq and replaces the file atomically. Every other key in
# settings.json is carried through byte for byte. It is safe to run twice.
#
# CLAUDE_STATUSLINE_SETTINGS_FILE overrides the settings path, which is
# ~/.claude/settings.json.

set -uo pipefail

SETTINGS="${CLAUDE_STATUSLINE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
DRY_RUN=false
ASSUME_YES=false
UNINSTALL=false

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --yes|-y)    ASSUME_YES=true ;;
    --uninstall) UNINSTALL=true ;;
    -h|--help)   awk 'NR>2 && !/^#/{exit} NR>2{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *)           die "unknown flag: $1" ;;
  esac
  shift
done

# ---- jq ---------------------------------------------------------------------
# settings.json is edited with jq and never with sed or a regex. A regex edit
# on JSON corrupts a file that holds every permission rule, hook and MCP server
# the user has, and Claude Code then ignores the whole file.
if ! command -v jq >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin) HOW="brew install jq" ;;
    Linux)  HOW="sudo apt install jq   # or: sudo dnf install jq, sudo pacman -S jq" ;;
    *)      HOW="see https://jqlang.github.io/jq/download/" ;;
  esac
  die "jq is required. Install it with:
    ${HOW}"
fi

# ---- resolve the statusline path --------------------------------------------
# The path is recorded in settings.json and read on every render, so it has to
# be absolute and it has to stay correct.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die "cannot resolve this script's directory"
TARGET="${SCRIPT_DIR}/claude-code-statusline.sh"
[[ -f "$TARGET" ]] || die "no claude-code-statusline.sh next to this script (looked in ${SCRIPT_DIR})"

case "$TARGET" in
  */marketplaces/*|"$HOME"/.claude/plugins/*)
    warn "this path is inside a plugin cache. Claude Code treats a plugin's
      directory as ephemeral and rewrites it on the next plugin update, which
      leaves settings.json pointing at a path that no longer exists. Copy the
      script somewhere you own and run install.sh from there." ;;
  "$HOME"/.claude/*)
    warn "this path is inside ~/.claude. Two things to weigh. A settings.json
      that is synced between machines carries this absolute path with it, and
      \$HOME differs between macOS and Linux, so the path resolves on one
      machine and not the other. And if ~/.claude is a git repository, the
      script becomes part of it. A directory outside ~/.claude avoids both." ;;
esac

if [[ ! -x "$TARGET" ]]; then
  if $DRY_RUN || $UNINSTALL; then
    warn "${TARGET} is not executable; the install would run chmod +x on it"
  else
    chmod +x "$TARGET" || die "cannot make ${TARGET} executable"
    note "made ${TARGET} executable"
  fi
fi

# ---- read the current settings ----------------------------------------------
# A file that is not valid JSON is never rewritten. Rewriting it would discard
# whatever the user was in the middle of, and jq cannot read it to begin with.
if [[ ! -e "$SETTINGS" ]]; then
  $UNINSTALL && { note "${SETTINGS} does not exist. Nothing to remove."; exit 0; }
  note "${SETTINGS} does not exist. It gets created with only the statusLine key."
  CURRENT='{}'
elif [[ ! -s "$SETTINGS" ]]; then
  $UNINSTALL && { note "${SETTINGS} is empty. Nothing to remove."; exit 0; }
  note "${SETTINGS} is empty. It gets the statusLine key and nothing else."
  CURRENT='{}'
else
  [[ -r "$SETTINGS" ]] || die "cannot read ${SETTINGS}"
  jq empty "$SETTINGS" 2>/dev/null \
    || die "${SETTINGS} is not valid JSON. Fix it first; this script will not rewrite a file it cannot parse."
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
    || die "${SETTINGS} is valid JSON but not an object. Refusing to touch it."
  CURRENT="$(cat "$SETTINGS")"
fi

# ---- build the new settings --------------------------------------------------
if $UNINSTALL; then
  NEW="$(printf '%s' "$CURRENT" | jq 'del(.statusLine)')" || die "jq failed to build the new settings"
else
  NEW="$(printf '%s' "$CURRENT" | jq --arg cmd "$TARGET" \
    '.statusLine = {"type": "command", "command": $cmd}')" || die "jq failed to build the new settings"
fi

# Compare normalised against normalised, so re-running on an already-installed
# file reports no change instead of a whitespace-only diff.
CURRENT_NORM="$(printf '%s' "$CURRENT" | jq -S .)" || die "jq failed to normalise the current settings"
NEW_NORM="$(printf '%s' "$NEW" | jq -S .)"         || die "jq failed to normalise the new settings"

if [[ "$CURRENT_NORM" == "$NEW_NORM" ]]; then
  if $UNINSTALL; then
    note "${SETTINGS} has no statusLine key. Nothing to remove."
  else
    note "${SETTINGS} already points at ${TARGET}. Nothing to change."
  fi
  exit 0
fi

note "settings file: ${SETTINGS}"
note "statusline:    ${TARGET}"
printf '\n'
diff -u \
  --label "${SETTINGS} (current)" \
  --label "${SETTINGS} (proposed)" \
  <(printf '%s\n' "$CURRENT_NORM") <(printf '%s\n' "$NEW_NORM")
printf '\n'

if $DRY_RUN; then
  note "dry run. Nothing was written."
  exit 0
fi

if ! $ASSUME_YES; then
  [[ -t 0 ]] || die "not an interactive shell. Pass --yes to write, or --dry-run to print only."
  read -r -p "Apply this change to ${SETTINGS}? [y/N] " REPLY
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *) note "cancelled. Nothing was written."; exit 0 ;;
  esac
fi

# ---- write, atomically ------------------------------------------------------
# The temp file sits in the same directory as the target, so `mv` is a rename
# within one filesystem and the settings file is never seen half-written.
mkdir -p "$(dirname "$SETTINGS")" || die "cannot create $(dirname "$SETTINGS")"
TMP="$(mktemp "${SETTINGS}.XXXXXX")" || die "cannot create a temp file beside ${SETTINGS}"
trap 'rm -f "$TMP"' EXIT

printf '%s\n' "$NEW" > "$TMP" || die "cannot write ${TMP}"
jq empty "$TMP" 2>/dev/null || die "the generated file is not valid JSON. ${SETTINGS} is untouched."

# GNU stat takes -c, BSD stat takes -f. Keep the mode the user had; mktemp
# creates 0600 and would silently tighten a 0644 settings file.
if [[ -e "$SETTINGS" ]]; then
  MODE="$(stat -c %a "$SETTINGS" 2>/dev/null || stat -f %Lp "$SETTINGS" 2>/dev/null)"
  [[ -n "$MODE" ]] && chmod "$MODE" "$TMP"
fi

mv "$TMP" "$SETTINGS" || die "cannot replace ${SETTINGS}"
trap - EXIT

if $UNINSTALL; then
  note "removed the statusLine key. Every other key is unchanged."
  exit 0
fi

note "done. Claude Code picks up the statusline on its next start."
command -v ccusage >/dev/null 2>&1 \
  || note "ccusage is not on PATH. It is optional: without it the cost and token
    segments are left out. Install it with 'npm i -g ccusage', or set
    CLAUDE_STATUSLINE_CCUSAGE_BIN to its absolute path."
