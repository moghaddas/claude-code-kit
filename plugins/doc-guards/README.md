# doc-guards

Two Claude Code hooks that keep written prose from rotting. One reads the comments the
model adds. The other lands before it starts an agent instruction file.

Both exist because a policy sitting in context competes with the task in front of the
model. A verbosity prior pulls the other way, so writing rules get under-applied exactly
when nobody is watching. A hook fires whether or not anyone remembered.

**This plugin is opinionated, and it ships disabled.** It holds one view of how a comment
and a `CLAUDE.md` should read, and that view is not universal. Installing it changes
nothing until you enable it, so nothing about how your agent writes moves under you.

```
/plugin install doc-guards@moghaddas
```

Claude Code prompts for the two options at enable time. Turn either hook off and its
script exits at once.

## comment-rule-check.sh

Fires on `PostToolUse(Edit|Write|Bash)` and reports comments that will not age well, in
the text the model adds.

It never blocks. It returns `additionalContext` listing what it found, so a false positive
costs a glance. That is deliberate: a noisy guard gets switched off, and a guard that is
off catches nothing.

What it flags:

| | |
|---|---|
| History narration | `used to`, `previously`, `regression`, `now uses`, `fixes the bug` |
| Replacement | `was ... before` |
| Provenance | `formerly`, `ported from`, `renamed from`, `replaces the old` |
| Temporal hedges | `soon`, `eventually`, `currently disabled`, `temporarily hardcoded` |
| Rotting specifics | a calendar date, `~300ms`, `3x faster`, `12k rows` |
| Shape | an inline `//` run of three or more lines, commented-out code |

One rule sits under all of it: **a comment says what is true now and what breaks without
it.** How the code got here is in git, and a comment repeating that drifts the moment the
code moves.

Two ways in, because a code file arrives by two routes. `Edit` and `Write` carry the added
text in the tool call. A Bash command does not: a heredoc, a redirect, `sed -i`, `cp`, `mv`
or an interpreter one-liner writes the file and leaves no text to read, so the added lines
come from `git diff HEAD -U0` on each file the command writes. Cover Bash, or the hook goes
quiet for a whole session: an agent told to prefer shell tools edits every file that way.

A path in a Bash command resolves against the directory a leading `cd` selects, not against
the payload cwd, and git runs in the repository that holds the file. A command shaped
`cd <dir> && sed -i ... src/app.js` is the common one, and resolving it against the session
root finds no file and reports nothing. A `cd` whose argument holds a variable stops the
walk, because resolving it means running it.

Reading git means the Bash arm reports every uncommitted added line in the file, not only
the lines one command wrote. Nothing offers a per-call baseline after the fact. A per-file
digest of the findings keeps a repeated report silent, so a loop of `sed -i` calls speaks
once.

Bare `now` and bare `fix` are absent from the history rule on purpose. `\bnow\b` matches
ordinary present-tense prose ("safe now that the lock is held") and `\bfixed\b` matches
`fixed-width` and `fixed point`. Each token needs the word that makes it narration.

### Configuration

| Variable | Default | What it does |
|---|---|---|
| `COMMENT_CHECK_EXTENSIONS` | `php,js,jsx,ts,tsx,vue,mjs,cjs,py,go,rs,java,kt,kts,cs,rb,swift` | File extensions to read, comma-separated, with or without a leading dot. |
| `COMMENT_CHECK_SKIP_DIRS` | `node_modules,vendor,dist,build,out,target,obj,.venv,venv,site-packages,__pycache__,.tox,.mypy_cache,.next,coverage` | Directory names to skip. Set it empty to skip none. |
| `COMMENT_CHECK_MAX_COMMENT_RUN` | `3` | Inline `//` run length that trips the shape check. |
| `COMMENT_CHECK_RULES` | (unset) | Path to a JSON file that replaces the text checks. |
| `COMMENT_CHECK_TICKET_PREFIXES` | (unset) | Comma-separated ticket prefixes, e.g. `PROJ,BACKEND`. |

`bin` is absent from the skip list on purpose: `src/bin/*.rs` is the canonical home of a
Rust binary, and skipping it would drop real source.

The ticket check stays off until you name prefixes, because a generic ticket shape,
`[A-Z]{2,10}-\d+`, also matches `UTF-8`, `SHA-256`, `AES-256` and `RFC-1918`.

A rules file holds an array of objects:

```json
[
  { "pattern": "\\bTODO\\b", "finding": "A TODO in a comment. Open a ticket or delete it." },
  { "pattern": "\\bXXX\\b",  "finding": "A marker nobody owns. Name the owner or cut it." }
]
```

Each `pattern` is a Python regular expression, matched case-insensitively against comment
text. Your file replaces the shipped rules outright. Validate it with
`python3 -m json.tool your-rules.json`.

## docs-brevity-guard.sh

Fires on `PreToolUse(Write|Edit|Bash)` and injects the brevity bar *before* an agent
instruction file is written. The shipped list is `CLAUDE.md`, `CLAUDE.local.md`,
`SKILL.md`, `AGENTS.md` and `AGENT.md`.

`PreToolUse` is the point. A reminder that arrives after the file exists costs a whole turn
of re-reading and rewriting, which is the behaviour worth avoiding. Injecting context is
not a tool call, so the hook cannot re-trigger itself.

Three triggers, because a file written with a heredoc never touches the Write tool:

- `Write` or `Edit` naming one of the files
- a Bash command that writes one, through a heredoc, a redirect, `tee`, `sed -i`, `cp`,
  `mv`, or an interpreter one-liner such as `python3 -c "open(...,'w')"`
- `git commit` with one of them staged, as the last gate before it lands

Cost is bounded three ways: one reminder per file per session, a reminder ceiling, and a
grep pre-filter that exits before Python starts.

### Configuration

| Variable | Default | What it does |
|---|---|---|
| `DOCS_BREVITY_FILENAMES` | `CLAUDE.md,CLAUDE.local.md,SKILL.md,AGENTS.md,AGENT.md` | File names to guard, comma-separated. |
| `DOCS_BREVITY_CLAUDE_MD` | (unset) | Path to a file that replaces the instruction-file bar. |
| `DOCS_BREVITY_SKILL_MD` | (unset) | Path to a file that replaces the `SKILL.md` bar. |
| `DOCS_BREVITY_COMMIT_MD` | (unset) | Path to a file that replaces the commit bar. |
| `DOCS_BREVITY_MAX_REMINDERS` | `4` | Reminders per session. |

A name whose stem is `SKILL` gets the skill bar. Every other name gets the
instruction-file bar, so `GEMINI.md` or `.cursorrules` works the moment you name it.

A replacement bar is injected verbatim, so keep it near 100 words. Every injection is
trimmed at 9500 characters, because Claude Code caps a hook output string at 10000 and
writes anything longer to a file the model then has to open.

## What it does not do

- **The two shape checks read `//` line comments only.** A Python or Ruby file gets every
  text check and no shape check, because a multi-line `#` block is idiomatic there and
  flagging it is noise. The commented-out-code rule reads the same `//` lines.
- **A trailing `#` comment on a code line is not read.** A full-line `#` comment is. `#`
  appears inside string literals often enough (a CSS colour, a URL fragment) that reading
  the tail of a code line would cost false positives.
- **It reads only the text being added**, never the comments already in the file. A rule
  you enable today says nothing about the code you wrote last month.
- **It never blocks.** Both hooks only add context.

## Fail open

Any parse error, unexpected shape, missing git repo or unwritable state directory exits 0
with no output, and the write proceeds untouched. A guard that wedges a write is worse
than the writing it was meant to catch.

A rules file that does not parse, an entry missing `pattern` or `finding`, and an invalid
regex all fall back to the shipped rules rather than reporting an error. If your rules
never fire, the file is the first thing to check.

## Standalone use

Both scripts run outside a plugin with no configuration. Copy them anywhere, `chmod +x`,
and wire them into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit|Write|Bash", "hooks": [
        { "type": "command", "command": "/path/to/comment-rule-check.sh" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Write|Edit|Bash", "hooks": [
        { "type": "command", "command": "/path/to/docs-brevity-guard.sh" } ] }
    ]
  }
}
```

Bash and Python 3 only.

## License

MIT.
