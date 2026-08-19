# agent-steer

Correct a running Claude Code subagent without waiting for it to finish.

## The problem

`SendMessage` lands after a subagent's task ends. The message sits in a queue, and the queue is read at a turn boundary. So when you watch one walk into the wrong file, or solve the wrong half of the problem, you have no way to say so while it still matters. You wait, then you respawn.

## The fix

Delivery by pull instead of push.

You write a file. The agent picks it up on its next tool call, whatever that tool is. It needs no instruction to look, because the read happens one layer below.

```
~/.claude/agent-control/<agent-name>.md
```

`<agent-name>` is the `name` you passed to the Agent tool. A `PreToolUse` hook runs before every tool call, sees the file, and injects the text as `additionalContext`. The agent reads it as a message from its lead that outranks its brief.

## Install

Enable the plugin from the marketplace:

```
/plugin install agent-steer@moghaddas
```

The enable-time dialog asks for the control directory, the staleness cutoff and the character limit. Every field is optional.

Needs `bash` and `python3`.

### Standalone, without the plugin

Copy `hooks/agent-control-inject.sh` anywhere, make it executable, and register it as a `PreToolUse` hook on every tool in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/agent-control-inject.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

## Use it

Spawn an agent with a name.

```
Agent(name: "docs", prompt: "...")
```

Steer it.

```bash
mkdir -p ~/.claude/agent-control
cat > ~/.claude/agent-control/docs.md <<'STEER'
Stop editing the parser. The parser is fine. Move to the README and document the flag you added.
STEER
```

The next tool call that agent makes carries your text.

## Configuration

Each setting reads its plugin option first and its plain variable second, so the standalone copy of the script honours the same knobs.

| Plugin option | Variable | Default | What it does |
| :--- | :--- | :--- | :--- |
| `agent_steer_control_dir` | `AGENT_STEER_DIR` | `~/.claude/agent-control` | Directory that holds the `<agent-name>.md` files |
| `agent_steer_max_age_minutes` | `AGENT_STEER_MAX_AGE_MINUTES` | `720` | Ignore a control file older than this |
| `agent_steer_max_chars` | `AGENT_STEER_MAX_CHARS` | `9000` | Truncate a steer longer than this |

**Put the control directory outside `~/.claude` if you keep `~/.claude` in version control.** A steer is a scratch file with a lifetime of minutes. Under git it gets committed, and on a synced setup it arrives on your other machine, where it can steer a same-named agent inside the staleness window. `~/.local/state/agent-control` or anything under `$TMPDIR` reads the same to the hook and leaks nowhere.

**Raise `agent_steer_max_age_minutes` for a long run, lower it if control files pile up.** A background agent that runs for three days needs a cutoff longer than twelve hours to stay steerable. Anyone who never deletes a control file wants the opposite.

**Claude Code caps hook output at 10,000 characters,** and over-limit output is written to a file and replaced with a preview plus a path. A steer that trips the cap therefore never arrives inline, and nothing in the run says so. The default of 9,000 sits under the cap with room for the wrapper prose, which is 233 characters, and for the JSON escaping of your text. The script also clamps whatever you configure to what the cap actually leaves.

## Rules that make it work

**One steer per file, rewritten in full.** Each write delivers once. Appending re-delivers the old text along with the new, and the agent has to guess which part is live.

**Say what to do next, not what happened.** "Move to the README" beats "you have been editing the parser for a while". The agent has its own transcript, not your view of the run.

**Use it for corrections, stop orders and scope changes.** A new task is a new agent. A steer that opens a second workstream gets you an agent doing two jobs badly.

**Delete the file when the run ends.** Otherwise it steers the next agent that reuses the name. The staleness cutoff behind you is a backstop, not a cleanup plan.

## What the script does

- Runs on every tool call, in the main conversation and in agents alike.
- Exits at once on a main-conversation call. Those carry no `agent_id`, so a single `grep` over the payload settles it before Python starts. That fast path is what makes a match-everything hook affordable.
- Reads the agent name from `agent_id`, which has the form `<name>@<team>`. An unnamed agent is never targeted.
- Refuses a name holding a path separator, so a name cannot reach out of the directory.
- Ignores a control file past the staleness cutoff.
- Delivers once per write. It stamps a marker under `$TMPDIR` and compares timestamps, so a rewrite delivers again and a plain re-read does not. The control directory is part of the marker key.
- Truncates to fit the hook output cap and says so in the injected text.
- Never sets `permissionDecision`, so the tool call keeps its normal permission flow. It adds context, nothing else.
- Fails open. Any parse, IO or Python error exits 0 with no output.

## Who writes the control file

The control file lands in an agent's context as instructions. Only you or your lead should write one. Nothing automated belongs in that directory.

## License

MIT. See [LICENSE](../../LICENSE).
