# claude-code-statusline

A Claude Code statusline that reports the true cost of a session and every repo in the workspace.

```
monorepo,infrastructure:main | docs:ZPT-3308-slug-lookup  Opus 5  132.4k  47%  4.1M  $18.72  ⛅ 21°
```

## Two things a stock statusline does not do

**Cost that counts subagents.** Claude Code's own `cost.total_cost_usd` is per-thread, so a session that fans out to subagents or workflow agents reports a fraction of what it spent. This splices in [ccusage](https://github.com/ryoppippi/ccusage), which recomputes from the transcripts on disk — the main thread plus `<session-id>/subagents/*.jsonl` — and counts all of it. The scan is slow enough to notice, so it runs in the background behind a lock and the line renders the previous value. The status line never blocks.

**Every repo, grouped by branch.** A workspace holding several checkouts shows each one, and repos sitting on the same branch collapse into a single entry, so the common case stays short. Worktrees and submodules count too: a `.git` file has a branch just as a `.git` directory does.

The rest of the line is the model name, the tokens in context right now, the percentage of context left with a five-band colour, and an optional weather indicator.

## Install

```bash
./install.sh
```

It prints the exact change it intends to make to `~/.claude/settings.json`, then asks. `--dry-run` prints and exits. `--yes` skips the prompt. `--uninstall` removes the `statusLine` key and leaves every other key untouched.

The edit goes through `jq`, never a regex, and the file is replaced atomically. A `settings.json` that is not valid JSON is refused rather than rewritten, because that file holds every permission rule, hook and MCP server you have.

Restart Claude Code, or run `/statusline` to see it.

## Requirements

| | |
| :--- | :--- |
| `bash` 3.2 or later | macOS ships 3.2. The script uses no associative array and no `date -r FILE`, both of which break there. |
| `jq` | Required. `brew install jq`, `sudo apt install jq`. |
| `ccusage` | Optional. `npm i -g ccusage`. Without it the cost and token segments are left out and nothing else changes. |
| `curl` | Only for the weather segment, which is off by default. |

## Configuration

Every variable is optional. Set them where Claude Code can see them, which means your shell profile, or the `env` key in `settings.json`.

| Variable | Default | What it does |
| :--- | :--- | :--- |
| `CLAUDE_STATUSLINE_REPOS` | discovered | Space-separated repo directories, relative to the workspace root. Pin the list to skip the scan. |
| `CLAUDE_STATUSLINE_WEATHER` | off | `"lat,lon"` to append a weather indicator, for example `52.52,13.405`. |
| `CLAUDE_STATUSLINE_UNITS` | `c` | `c` or `f`, for the temperature and its colour bands. |
| `CLAUDE_STATUSLINE_CCUSAGE_BIN` | searched | Absolute path to `ccusage`, for when the search misses it. |
| `CLAUDE_STATUSLINE_CONTEXT_OVERHEAD_PCT` | `10` | Percentage points to subtract for system overhead. |
| `CLAUDE_STATUSLINE_SETTINGS_FILE` | `~/.claude/settings.json` | Read by `install.sh` only. Which settings file to edit. |

**`CLAUDE_STATUSLINE_CCUSAGE_BIN` is the fix when the cost segment is missing.** Claude Code runs the statusline with a non-login shell, so a version manager's `PATH` is often absent and `command -v ccusage` finds nothing. The script searches nvm, fnm, Volta, Bun, pnpm, asdf, Yarn, Homebrew and the usual system directories, and a hit anywhere is silent. Run `command -v ccusage` in your own shell and set the variable to what it prints.

**`CLAUDE_STATUSLINE_CONTEXT_OVERHEAD_PCT` reconciles the percentage with `/context`.** The `remaining_percentage` Claude Code passes in excludes system overhead — tool definitions, `CLAUDE.md`, MCP schemas — which the real context limit includes. The size of that overhead moves with your own setup, so the default of 10 is a starting point. Compare the rendered figure against `/context` and set the difference.

## Why this is not a plugin

A plugin's bundled `settings.json` accepts only the `agent` and `subagentStatusLine` keys, so there is no way for a plugin to declare a `statusLine` — that key exists in user and project settings alone. Pointing `statusLine.command` at a path under `${CLAUDE_PLUGIN_ROOT}` would not work around it either, because the plugin directory is ephemeral across updates and the path would break on the next one. So it ships as a script plus `install.sh`.

## Making it yours

Fork it. It is one readable file with no configuration language layered on top, and the whole line is assembled in the `PROMPT` block at the bottom. A statusline of a different shape is an edit to that block, not a plugin API to learn.

## License

MIT. See [LICENSE](../LICENSE).
