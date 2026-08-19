# claude-code-kit

Six Claude Code hooks in five plugins, and a statusline. Each one closes a gap
that costs real time: an agent that narrates history in a comment, a subagent
you cannot correct until it finishes, a bot challenge that reads like a missing
file, a long turn that ends while you are in another window.

Install what you want. Nothing here depends on anything else here.

## Install

```
/plugin marketplace add moghaddas/claude-code-kit
/plugin install curl-ua-guard@moghaddas
```

From a shell instead of a session:

```
claude plugin marketplace add moghaddas/claude-code-kit
claude plugin install curl-ua-guard@moghaddas --scope user
```

All five plugins at once:

```
claude plugin install kit@moghaddas
```

## What is here

| Plugin | Event | What it does |
| --- | --- | --- |
| [`curl-ua-guard`](plugins/curl-ua-guard) | `PreToolUse` | Gives `curl` and `wget` a browser User-Agent before they leave the machine. A Cloudflare-fronted origin serves a challenge to a default `curl/8.x` UA, and that response reads like a real finding. |
| [`notify`](plugins/notify) | `Notification`, `Stop` | Writes a desktop banner when Claude needs you, and when a long turn ends. |
| [`doc-guards`](plugins/doc-guards) | `PostToolUse`, `PreToolUse` | Flags a comment that narrates history in code just written. Sets the brevity bar before a `CLAUDE.md`, `AGENTS.md` or `SKILL.md` is written. |
| [`agent-steer`](plugins/agent-steer) | `PreToolUse` | Corrects a running subagent. A queued message reaches an agent only at a turn boundary, so this one delivers by pull instead. |
| [`help-intercept`](plugins/help-intercept) | `UserPromptSubmit` | Prints a skill's help text for zero model tokens. The hook returns the text through the block contract, so the model never runs. |

`doc-guards` and `agent-steer` install **disabled**. Both change how the agent behaves,
so you opt in rather than discover them. Enable either in `/plugin`.

Each plugin's README carries its own configuration table and its failure mode.

## The statusline

[`statusline/`](statusline) holds a statusline that reports two things a stock one does
not: the true cost of a session including subagents, and every repo in the workspace
grouped by branch.

It is not a plugin. A plugin's bundled `settings.json` supports only the `agent` and
`subagentStatusLine` keys, so no plugin can install a statusline. Run the installer:

```
git clone https://github.com/moghaddas/claude-code-kit ~/src/claude-code-kit
~/src/claude-code-kit/statusline/install.sh
```

## Requirements

The statusline needs `jq`, and uses `ccusage` for the cost segment when it is present.
Every hook runs on `bash` and the Python 3 that ships with the system. Nothing here
needs a package manager.

## License

MIT.
