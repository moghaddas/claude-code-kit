# help-intercept

`/<command> --help` prints the command's help text and burns zero model tokens. No API
call, no turn, no latency.

```
/plugin install help-intercept@moghaddas
```

## How

`UserPromptSubmit` fires before the model sees anything, and it gets the **raw typed
text**. For a skill invocation that means the literal `/jira --help`, not the expanded
`SKILL.md` body. So the hook can match it, and the block contract does the rest:

```json
{"decision": "block", "reason": "<help text>",
 "hookSpecificOutput": {"hookEventName": "UserPromptSubmit"}}
```

On `UserPromptSubmit`, `block` means the prompt never reaches the model, and `reason` goes
to the user only. It never enters the context window. That is the whole trick: `reason` is
a user-visible channel that costs nothing.

Verified against Claude Code 2.1.x.

## Where the help text comes from

The first fenced code block under the `## Help` heading of the matching
`skills/<cmd>/SKILL.md`:

````markdown
## Help

```
/jira [--epic KEY] [--assign me]

Create a Jira issue from the session.
```
````

Nothing is duplicated. The hook reads the same block the skill documents itself with, so
the two cannot drift apart.

Search order, first match wins:

1. `CC_HELP_SKILL_ROOTS`, extra `skills/` directories
2. `$CLAUDE_PLUGIN_ROOT/skills`
3. `../skills` relative to the hook
4. `$CLAUDE_PROJECT_DIR/.claude/skills`
5. `./.claude/skills`
6. `~/.claude/skills`

A `<namespace>:` prefix is optional, so `/myplugin:jira --help` and `/jira --help` both
resolve to the `jira` skill. Both segments accept lowercase letters, digits, hyphens and
underscores, so a directory named `my_skill` resolves.

## Configuration

| Option | Variable | Default | What it does |
|---|---|---|---|
| Help heading | `CC_HELP_HEADING` | `Help` | Heading text that opens the help section. Matched case-insensitively at heading level 1 to 3, so `# Help`, `## Help` and `### Help` all resolve. |
| Extra skills directories | `CC_HELP_SKILL_ROOTS` | (unset) | Absolute paths searched before every built-in root. Separate them with `:`, a comma, or a newline. |

Claude Code prompts for both at enable time and exports them as
`CLAUDE_PLUGIN_OPTION_CC_HELP_HEADING` and `CLAUDE_PLUGIN_OPTION_CC_HELP_SKILL_ROOTS`. A
plugin option wins over the bare variable of the same name. The roots are the exception:
both lists are searched, the plugin option first.

Point `CC_HELP_HEADING` at whatever your skills already use — `Usage`, `Options`,
`Synopsis`. This is the one convention the hook depends on. A repo whose skills head that
section differently gets nothing until you set it.

## What it does not do

- **It does not read the skills of other plugins.** Installed as its own plugin,
  `$CLAUDE_PLUGIN_ROOT` and `../skills` both point inside this plugin, which ships no
  skills, so roots 2 and 3 are dead. The hook covers your user skills
  (`~/.claude/skills`) and your project skills (`.claude/skills`). To reach a plugin's
  skills, name that directory in `CC_HELP_SKILL_ROOTS`. The plugin cache layout is not a
  documented contract, so the hook does not glob it.
- **It does not invent help text.** A skill with no `## Help` section, or a Help section
  with no fenced block, passes the prompt to the model unchanged.
- **It does not match a bare `--help`.** The prompt has to start with a slash command.
- **It does not print more than 9500 characters.** Claude Code caps a hook output string
  at 10000 and writes anything longer to a file, which defeats the point, so a longer
  block is trimmed with a pointer to the `SKILL.md`.

## Failure modes

| Symptom | Cause |
|---|---|
| The model answers instead of the help text | No `SKILL.md` under any searched root, or the heading does not match `CC_HELP_HEADING`. |
| Help prints for one skill and not another | The second skill's Help section holds prose, not a fenced block. |
| A plugin's skill never resolves | Roots 2 and 3 are dead in a plugin install. Name the directory in `CC_HELP_SKILL_ROOTS`. |
| The help text ends in `Help text trimmed` | The fenced block runs past the 10000-character output cap. |

## Standalone use

The script runs outside a plugin with no configuration. Copy it anywhere, `chmod +x`, and
wire it into `~/.claude/settings.json`:

```json
{"hooks": {"UserPromptSubmit": [{"hooks": [
  {"type": "command", "command": "~/.claude/hooks/help-intercept.sh"}]}]}}
```

A prompt that is not a help invocation exits with no output and goes to the model
unchanged.

## Cost

A shell `grep` gates the interpreter startup, so the common case is one cheap string
match. A prompt that does carry a help flag pays for one Python process. Neither path
involves the model.

## License

MIT.
