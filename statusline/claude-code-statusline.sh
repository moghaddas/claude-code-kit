#!/usr/bin/env bash
# claude-code-statusline.sh: a Claude Code statusline that reports the true
# cost of a session and every repo in the workspace.
#
# Source, and an installer that edits settings.json for you:
#   https://github.com/moghaddas/claude-code-kit
#
# Two things it does that a stock statusline does not:
#
#   Cost that counts subagents. Claude Code's own cost.total_cost_usd is
#   per-thread, so a session that fans out to subagents or workflows reports a
#   fraction of what it spent. This splices in ccusage, which recomputes from
#   the transcript and counts all of it. The scan takes about 0.4s, so it runs
#   in the background and renders the previous value.
#
#   Every repo, grouped by branch. A workspace holding several checkouts shows
#   each one, and repos sitting on the same branch collapse into a single
#   entry, so the common case stays short.
#
# Install: run install.sh next to this file. By hand instead: chmod +x, then
# in ~/.claude/settings.json
#   { "statusLine": { "type": "command", "command": "/path/to/this.sh" } }
#
# Needs jq. ccusage is optional (npm i -g ccusage); without it the cost
# segment is left out.
#
# Configuration, all optional:
#   CLAUDE_STATUSLINE_REPOS                 space-separated repo directories,
#                                           relative to the workspace root.
#                                           Unset discovers them.
#   CLAUDE_STATUSLINE_WEATHER               "lat,lon" to append a weather
#                                           indicator. Unset leaves it out.
#   CLAUDE_STATUSLINE_UNITS                 c or f, for the temperature and its
#                                           colour bands. Default c.
#   CLAUDE_STATUSLINE_CCUSAGE_BIN           absolute path to ccusage, for when
#                                           the search below misses it.
#   CLAUDE_STATUSLINE_CONTEXT_OVERHEAD_PCT  percentage points to subtract for
#                                           system overhead. Default 10.
input=$(cat)

# GNU stat takes -c, BSD stat takes -f. `date -r FILE` is GNU-only: on macOS
# it reads the argument as an epoch instead, so a cache age computed that way
# is always stale and every render refetches.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Colors
CYAN=$'\033[0;36m'
LIGHT_BLUE=$'\033[38;5;39m'
BLUE=$'\033[1;34m'
RED=$'\033[0;31m'
ORANGE=$'\033[38;5;208m'
YELLOW=$'\033[0;33m'
GREEN=$'\033[0;32m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Parse JSON input
eval "$(echo "$input" | jq -r '
  @sh "PROJECT_DIR=\(.workspace.project_dir)",
  @sh "CTX_REMAINING_PCT=\(.context_window.remaining_percentage)",
  @sh "CTX_USED=\(([ (.context_window.current_usage // {}) | .[] ] | add) // 0)",
  @sh "MODEL_NAME=\(.model.display_name)"
')"

# --- ccusage: all-in cost and billable tokens (includes subagents/workflows) ---
# Claude Code's cost.total_cost_usd is per-thread only. ccusage recomputes from the
# session transcripts on disk (main thread + <session-id>/subagents/*.jsonl), so this
# figure also counts subagent and workflow-agent usage. We take only ccusage's cost and
# token totals; git/weather/model/context stay ours.
# A miss shows as a silently absent cost segment, which is the headline
# feature, so the search is wide and CLAUDE_STATUSLINE_CCUSAGE_BIN settles it
# outright. Claude Code runs the statusline with a non-login shell, so a
# version manager's PATH is often absent and `command -v` finds nothing.
if [ -n "${CLAUDE_STATUSLINE_CCUSAGE_BIN:-}" ] && [ -x "${CLAUDE_STATUSLINE_CCUSAGE_BIN}" ]; then
    CCUSAGE_BIN="$CLAUDE_STATUSLINE_CCUSAGE_BIN"
else
    CCUSAGE_BIN="$(command -v ccusage 2>/dev/null)"
fi
if [ -z "$CCUSAGE_BIN" ]; then
    # An unmatched glob stays literal, and `-x` rejects the literal.
    for c in \
        "$HOME"/.nvm/versions/node/*/bin/ccusage \
        "$HOME"/.fnm/node-versions/*/installation/bin/ccusage \
        "$HOME"/Library/"Application Support"/fnm/node-versions/*/installation/bin/ccusage \
        "$HOME"/.volta/bin/ccusage \
        "$HOME"/.bun/bin/ccusage \
        "$HOME"/.local/share/pnpm/ccusage \
        "$HOME"/.local/bin/ccusage \
        "$HOME"/.asdf/shims/ccusage \
        "$HOME"/.npm-global/bin/ccusage \
        "$HOME"/.yarn/bin/ccusage \
        /opt/homebrew/bin/ccusage \
        /usr/local/bin/ccusage \
        /usr/bin/ccusage; do
        [ -x "$c" ] && CCUSAGE_BIN="$c" && break
    done
fi
CCU_COST=""
CCU_TOKENS=""
if [ -n "$CCUSAGE_BIN" ]; then
    SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -n "$SESSION_ID" ]; then
        # ccusage's per-session report gives, from one transcript scan, both the all-in
        # session cost and the billable token total (input+output+cache, including
        # subagents and workflow agents): the exact figures Claude charges on, for THIS
        # session. The scan takes ~0.4s, so refresh it in the background, like weather, and
        # render from cache. The status line never blocks; numbers lag one refresh (~3s).
        CCU_CACHE="${TMPDIR:-/tmp}/ccusage-sl-${SESSION_ID}.txt"
        CCU_LOCK="${CCU_CACHE}.lock"
        CCU_TTL=3
        if [ -f "$CCU_CACHE" ]; then
            CCU_AGE=$(( $(date +%s) - $(file_mtime "$CCU_CACHE") ))
        else
            CCU_AGE=999999
        fi
        # The cache mtime only advances when a scan FINISHES, so a scan that runs longer
        # than the TTL leaves the cache stale for its whole duration. Without a lock every
        # render in that window starts another scan, and because each scan competes with
        # the ones already running they all slow down together, an unbounded pile-up that
        # saturates the CPU (a loaded box turns a 0.4s scan into minutes). `mkdir` is the
        # atomic test-and-set that exists on both macOS and Linux; `flock` does not.
        if [ "$CCU_AGE" -gt "$CCU_TTL" ]; then
            if [ -d "$CCU_LOCK" ]; then
                # Reap a lock orphaned by a killed scan, so the cache cannot freeze forever.
                CCU_LOCK_AGE=$(( $(date +%s) - $(file_mtime "$CCU_LOCK") ))
                [ "$CCU_LOCK_AGE" -gt 120 ] && rmdir "$CCU_LOCK" 2>/dev/null
            fi
            if mkdir "$CCU_LOCK" 2>/dev/null; then
                (
                    trap 'rmdir "$CCU_LOCK" 2>/dev/null' EXIT
                    # A $TMPDIR that no longer exists, which a reaped macOS
                    # per-session directory is, makes mktemp write to stderr on
                    # every render. The status line stays silent instead.
                    TMP=$(mktemp "${CCU_CACHE}.XXXXXX" 2>/dev/null) || exit 0
                    DATA=$("$CCUSAGE_BIN" claude session --id "$SESSION_ID" --json 2>/dev/null \
                        | jq -r '"\(.totalCost // 0)|\(.totalTokens // 0)"' 2>/dev/null)
                    if [ -n "$DATA" ]; then printf '%s' "$DATA" > "$TMP" && mv "$TMP" "$CCU_CACHE"; else rm -f "$TMP"; fi
                ) &
                disown 2>/dev/null
            fi
        fi
        CCU_DATA=$(cat "$CCU_CACHE" 2>/dev/null)
        if [ -n "$CCU_DATA" ]; then
            CCU_COST_RAW=${CCU_DATA%%|*}
            CCU_TOK_RAW=${CCU_DATA##*|}
            [ -n "$CCU_COST_RAW" ] && CCU_COST=$(printf '$%.2f' "$CCU_COST_RAW" 2>/dev/null)
            if [ -n "$CCU_TOK_RAW" ] && [ "$CCU_TOK_RAW" != "0" ]; then
                CCU_TOKENS=$(awk -v t="$CCU_TOK_RAW" 'BEGIN{ if (t>=1000000) printf "%.1fM", t/1000000; else if (t>=1000) printf "%.0fk", t/1000; else printf "%d", t }')
            fi
        fi
    fi
fi

# --- Git repos with branches ---
# Whatever is there: the workspace root when it is itself a checkout,
# otherwise every immediate subdirectory holding a .git. Set
# CLAUDE_STATUSLINE_REPOS to pin the list and skip the scan.
if [ -n "${CLAUDE_STATUSLINE_REPOS:-}" ]; then
    read -ra REPOS <<< "$CLAUDE_STATUSLINE_REPOS"
elif [ -e "$PROJECT_DIR/.git" ]; then
    REPOS=(".")
else
    REPOS=()
    for d in "$PROJECT_DIR"/*/; do
        [ -e "${d}.git" ] && REPOS+=("$(basename "$d")")
    done
fi
# "." is the workspace root itself, which reads better under its own name.
repo_label() { [ "$1" = "." ] && basename "$PROJECT_DIR" || printf '%s' "$1"; }

# Two parallel indexed arrays, not an associative one. macOS ships bash 3.2,
# where `declare -A` is a syntax error and a subscript like feature/x is
# evaluated as arithmetic instead, so the whole git segment renders as garbage
# on the platform most people run this on.
REPO_NAMES=()
REPO_BRANCH=()

for repo in "${REPOS[@]}"; do
    REPO_PATH="$PROJECT_DIR/$repo"
    # A .git DIRECTORY is a normal checkout; a .git FILE is a worktree or a
    # submodule, which has a branch too.
    if [ -e "$REPO_PATH/.git" ]; then
        BRANCH=$(git -C "$REPO_PATH" branch --show-current 2>/dev/null)
        if [ -n "$BRANCH" ]; then
            REPO_NAMES+=("$repo")
            REPO_BRANCH+=("$BRANCH")
        fi
    fi
done

# Distinct branches, in the order they were found, so the line does not
# reshuffle itself between renders the way a hash iteration would.
BRANCHES=()
for i in "${!REPO_BRANCH[@]}"; do
    seen=false
    for b in ${BRANCHES[@]+"${BRANCHES[@]}"}; do
        [ "$b" = "${REPO_BRANCH[$i]}" ] && { seen=true; break; }
    done
    $seen || BRANCHES+=("${REPO_BRANCH[$i]}")
done

GIT_INFO=""
FIRST_GROUP=true
for branch in ${BRANCHES[@]+"${BRANCHES[@]}"}; do
    NAMES=""
    for i in "${!REPO_BRANCH[@]}"; do
        [ "${REPO_BRANCH[$i]}" = "$branch" ] || continue
        [ -n "$NAMES" ] && NAMES+="${DIM},${RESET}"
        NAMES+="${DIM}$(repo_label "${REPO_NAMES[$i]}")${RESET}"
    done
    $FIRST_GROUP || GIT_INFO+=" ${DIM}|${RESET} "
    FIRST_GROUP=false
    # The branch keeps the terminal's own foreground colour. A fixed dark grey
    # reads as invisible on a dark theme, and this is the most useful field
    # in the line.
    GIT_INFO+="${NAMES}${BLUE}:${RESET}${branch}"
done

# --- Weather indicator (opt-in, cached, non-blocking) ---
# Off unless CLAUDE_STATUSLINE_WEATHER holds "lat,lon".
WEATHER_LAT=""
WEATHER_LON=""
if [ -n "${CLAUDE_STATUSLINE_WEATHER:-}" ]; then
    WEATHER_LAT="${CLAUDE_STATUSLINE_WEATHER%%,*}"
    WEATHER_LON="${CLAUDE_STATUSLINE_WEATHER##*,}"
fi
STATUSLINE_UNITS="c"
WEATHER_UNIT_PARAM=""
if [ "${CLAUDE_STATUSLINE_UNITS:-c}" = "f" ]; then
    STATUSLINE_UNITS="f"
    WEATHER_UNIT_PARAM="&temperature_unit=fahrenheit"
fi
# One cache file per coordinate pair and unit, the way CCU_CACHE is one file
# per session. A single global filename lets two concurrent sessions watching
# different cities overwrite each other every WEATHER_TTL seconds, so each one
# renders the other's city. The key holds only alphanumerics, dot, comma,
# underscore and hyphen, so it can never carry a path separator, and the
# fallback keeps it non-empty.
WEATHER_KEY=$(printf '%s-%s' "${CLAUDE_STATUSLINE_WEATHER:-none}" "$STATUSLINE_UNITS" \
    | tr -c 'A-Za-z0-9.,_-' '_' | cut -c1-64)
WEATHER_CACHE="${TMPDIR:-/tmp}/claude-statusline-weather-${WEATHER_KEY}.json"
WEATHER_TTL=600  # 10 minutes
WEATHER_EMOJI=""
TEMP_COLOR=""
if [ -f "$WEATHER_CACHE" ]; then
    CACHE_AGE=$(( $(date +%s) - $(file_mtime "$WEATHER_CACHE") ))
else
    CACHE_AGE=999999
fi
if [ -n "$WEATHER_LAT" ] && [ "$CACHE_AGE" -gt "$WEATHER_TTL" ]; then
    # Refresh in background; current render uses whatever is cached (or nothing).
    # mktemp avoids concurrent renders racing on the same tmp file.
    (
        TMP=$(mktemp "${WEATHER_CACHE}.XXXXXX" 2>/dev/null) || exit 0
        if curl -fsS --max-time 4 "https://api.open-meteo.com/v1/forecast?latitude=${WEATHER_LAT}&longitude=${WEATHER_LON}&current=weather_code,temperature_2m,precipitation${WEATHER_UNIT_PARAM}" -o "$TMP" 2>/dev/null \
           && jq -e '.current.weather_code != null and .current.temperature_2m != null' "$TMP" >/dev/null 2>&1; then
            mv "$TMP" "$WEATHER_CACHE"
        else
            rm -f "$TMP"
        fi
    ) &
    disown 2>/dev/null
fi
WEATHER_TEMP=""
if [ -n "$WEATHER_LAT" ] && [ -f "$WEATHER_CACHE" ] && jq -e '.current.weather_code != null' "$WEATHER_CACHE" >/dev/null 2>&1; then
    WCODE=$(jq -r '.current.weather_code // 0' "$WEATHER_CACHE" 2>/dev/null)
    TEMP=$(jq -r '.current.temperature_2m // empty' "$WEATHER_CACHE" 2>/dev/null)
    PRECIP=$(jq -r '.current.precipitation // 0' "$WEATHER_CACHE" 2>/dev/null)
    # Open-Meteo's weather_code is a forecast for the grid cell, not an observation.
    # For rain codes, defer to observed precipitation (mm in the last 15 min) so the
    # statusline reflects what is falling, not what the model expected.
    IS_RAINING=$(awk -v p="$PRECIP" 'BEGIN { print (p+0 >= 0.1) ? 1 : 0 }')
    # WMO weather code → emoji
    case "$WCODE" in
        0)                       WEATHER_EMOJI="☀️" ;;   # clear sky
        1)                       WEATHER_EMOJI="🌤️" ;;   # mainly clear
        2)                       WEATHER_EMOJI="⛅" ;;    # partly cloudy
        3)                       WEATHER_EMOJI="☁️" ;;   # overcast
        45|48)                   WEATHER_EMOJI="🌫️" ;;   # fog
        51|53|55)                                          # drizzle (forecast)
            [ "$IS_RAINING" = "1" ] && WEATHER_EMOJI="🌦️" || WEATHER_EMOJI="☁️" ;;
        56|57)                                             # freezing drizzle
            [ "$IS_RAINING" = "1" ] && WEATHER_EMOJI="🥶🌧️" || WEATHER_EMOJI="☁️" ;;
        61|63|65|80|81|82)                                 # rain / showers
            [ "$IS_RAINING" = "1" ] && WEATHER_EMOJI="🌧️" || WEATHER_EMOJI="⛅" ;;
        66|67)                                             # freezing rain
            [ "$IS_RAINING" = "1" ] && WEATHER_EMOJI="🥶🌧️" || WEATHER_EMOJI="☁️" ;;
        71|73|75|77|85|86)       WEATHER_EMOJI="🌨️" ;;   # snow
        95|96|99)                WEATHER_EMOJI="⛈️" ;;   # thunderstorm
        *)                       WEATHER_EMOJI="🌡️" ;;
    esac
    if [ -n "$TEMP" ]; then
        TEMP_INT=$(printf '%.0f' "$TEMP")
        WEATHER_TEMP="${TEMP_INT}°"
        # Five bands, written in °C and converted once when Fahrenheit is
        # requested, so a colour means the same weather in both units.
        TEMP_BANDS=(0 10 18 25 30)
        if [ "$STATUSLINE_UNITS" = "f" ]; then
            for i in "${!TEMP_BANDS[@]}"; do
                TEMP_BANDS[$i]=$(( TEMP_BANDS[i] * 9 / 5 + 32 ))
            done
        fi
        if [ "$TEMP_INT" -le "${TEMP_BANDS[0]}" ]; then
            TEMP_COLOR="$LIGHT_BLUE"     # freezing
        elif [ "$TEMP_INT" -le "${TEMP_BANDS[1]}" ]; then
            TEMP_COLOR="$CYAN"           # cold
        elif [ "$TEMP_INT" -le "${TEMP_BANDS[2]}" ]; then
            TEMP_COLOR="$GREEN"          # mild
        elif [ "$TEMP_INT" -le "${TEMP_BANDS[3]}" ]; then
            TEMP_COLOR="$YELLOW"         # warm
        elif [ "$TEMP_INT" -le "${TEMP_BANDS[4]}" ]; then
            TEMP_COLOR="$ORANGE"         # hot
        else
            TEMP_COLOR="$RED"            # very hot
        fi
    fi
fi

PROMPT=""

# Git info
if [ -n "$GIT_INFO" ]; then
    PROMPT+="${GIT_INFO}"
fi

# Model name (drop the " (1M context)" suffix Claude Code appends for 1M-context models)
if [ -n "$MODEL_NAME" ] && [ "$MODEL_NAME" != "null" ]; then
    MODEL_NAME=${MODEL_NAME/ (1M context)/}
    MODEL_NAME=${MODEL_NAME/(1M context)/}
    PROMPT+=" ${DIM}${MODEL_NAME}${RESET}"
fi

# Context remaining with 5-level color gradient
if [ -n "$CTX_REMAINING_PCT" ] && [ "$CTX_REMAINING_PCT" != "null" ]; then
    CTX_INT=${CTX_REMAINING_PCT%.*}
    # Subtract system overhead (tools, CLAUDE.md and so on), which
    # remaining_percentage excludes but the real context limit includes. The
    # real figure moves with CLAUDE.md size and MCP tool count, so compare the
    # rendered number against /context and set the difference here.
    CTX_OVERHEAD_PCT=${CLAUDE_STATUSLINE_CONTEXT_OVERHEAD_PCT:-10}
    case "$CTX_OVERHEAD_PCT" in ''|*[!0-9]*) CTX_OVERHEAD_PCT=10 ;; esac
    CTX_INT=$((CTX_INT > CTX_OVERHEAD_PCT ? CTX_INT - CTX_OVERHEAD_PCT : 0))
    CTX_REMAINING_PCT=$CTX_INT
    if [ "$CTX_INT" -gt 60 ]; then
        CTX_COLOR="$GREEN"      # 60%+ remaining
    elif [ "$CTX_INT" -gt 40 ]; then
        CTX_COLOR="$CYAN"       # 40-60% remaining
    elif [ "$CTX_INT" -gt 25 ]; then
        CTX_COLOR="$YELLOW"     # 25-40% remaining
    elif [ "$CTX_INT" -gt 15 ]; then
        CTX_COLOR="$ORANGE"     # 15-25% remaining
    else
        CTX_COLOR="$RED"        # <15% remaining
    fi
    # Current context-window usage (tokens in context right now), then % remaining.
    if [ -n "$CTX_USED" ] && [ "$CTX_USED" != "null" ]; then
        CTX_TOK_INT=${CTX_USED%.*}
        CTX_TOK_FMT=$(awk -v t="$CTX_TOK_INT" 'BEGIN{ if (t>=1000000) printf "%.1fM", t/1000000; else if (t>=1000) printf "%.1fk", t/1000; else printf "%d", t }')
        PROMPT+=" ${DIM}${CTX_TOK_FMT}${RESET}"
    fi
    PROMPT+=" ${CTX_COLOR}${CTX_REMAINING_PCT}%${RESET}"
fi

# Billable tokens + session cost from ccusage (all-in, including subagents), before weather.
# "billed" = total input+output+cache tokens Claude charges on; "$" = the resulting cost.
if [ -n "$CCU_TOKENS" ]; then
    PROMPT+=" ${DIM}${CCU_TOKENS}${RESET}"
fi
if [ -n "$CCU_COST" ]; then
    PROMPT+=" ${DIM}${CCU_COST}${RESET}"
fi

# Weather (at the end)
if [ -n "$WEATHER_EMOJI" ] || [ -n "$WEATHER_TEMP" ]; then
    PROMPT+=" ${WEATHER_EMOJI}"
    [ -n "$WEATHER_TEMP" ] && PROMPT+=" ${TEMP_COLOR}${WEATHER_TEMP}${RESET}"
fi

printf "%s\n" "$PROMPT"
