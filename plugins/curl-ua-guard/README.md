# curl-ua-guard

A `PreToolUse` hook that gives `curl` and `wget` a real browser User-Agent (UA) before they leave the machine.

## The problem it solves

Much of the web answers `curl/8.x` differently. Anything behind Cloudflare, and plenty of Software-as-a-Service (SaaS) front ends, return a challenge page, a 403, a redirect, or markup with the content stripped out. None of that looks like an error. The agent reads the challenge page as the page and reports a confident finding built on it.

A prose instruction to always pass a UA works until the one time the model forgets, and the transcript does not tell you which time that was. This hook makes it automatic.

## What it does

The hook rewrites the command to carry `-A` (curl) or `-U` (wget), then hands the rewritten command back through `hookSpecificOutput.updatedInput`. Claude Code shows you the rewritten command and asks you to confirm it.

It acts only when it is sure the injection is needed:

- `curl` and `wget` only.
- It skips a command that already sets a UA through `-A`, `-U`, `--user-agent`, or `-H user-agent:`.
- It injects only when the command holds at least one external `http(s)` Uniform Resource Locator (URL) literal.
- It skips a `curl` inside a heredoc body, because that is a file being written rather than a command about to run.
- It skips a `curl` inside a quoted string, so `echo 'a curl b' && curl https://x` gets one flag and not two.

These hosts count as internal, and a command that targets only internal hosts stays untouched:

`localhost`, `0.0.0.0`, `::1`, `host.docker.internal`, any private, loopback, or link-local Internet Protocol (IP) address, and any host under `.local`, `.localhost`, `.test`, `.internal`, `.lan`, `.home.arpa`, `.corp`, or `.intranet`.

## What it does not do

- **It does not cover `httpie`, `xh`, or any other client.** Each one needs its own flag syntax and its own already-set detection. The abstraction costs more than the coverage.
- **It does not read a URL out of a shell variable.** `curl "$URL"` has no literal host to classify, so nothing is rewritten. Pass `-A` yourself there.
- **It does not widen what runs unattended.** The default decision is `ask`, not `allow`.
- **It does not keep its default UA current for you.** Bump it yourself, see below.

## Install

```
/plugin install curl-ua-guard@moghaddas
```

## Configuration

Two options appear in the enable dialog. Every option also has a shell variable, and the plugin option wins when both hold a value. Set the UA in one place, otherwise the enable-dialog value shadows your shell variable and you debug the wrong string.

| Option / variable | Effect |
|---|---|
| `user_agent` / `CLAUDE_CURL_UA` | The UA string to inject. Defaults to Chrome 152 on macOS. |
| `auto_allow` / `CLAUDE_CURL_UA_AUTO_ALLOW` | Approve the rewritten command without a prompt. Unset means `ask`. The variable accepts `1`, `true`, `yes`, or `on`. |
| `CLAUDE_CURL_UA_INTERNAL_SUFFIXES` | Comma-separated extra host suffixes to treat as internal, for example `.acme,.dev-cluster`. It appends to the built-in list rather than replacing it. A leading dot is optional. |
| `CLAUDE_CURL_UA_SKIP_HOSTS` | Comma-separated exact hosts to leave alone, for example `api.github.com`. Use it for an Application Programming Interface (API) that rate-limits a browser UA but not `curl/8.x`. |

`auto_allow` ships with no default, so the shell variable still works after you install the plugin. Once you answer the option in the enable dialog, that answer wins.

`CLAUDE_CURL_UA_SKIP_HOSTS` matches a host exactly and not as a suffix: `api.github.com` does not cover `sub.api.github.com`. One flag covers every URL in a command, so a single skipped host takes the whole command out of the rewrite.

### Bump the User-Agent periodically

The shipped default names a Chrome major version. That version ages. A stale major is exactly what a strict origin gates on, so the default that works today draws a challenge page in a year. Check your own browser's UA now and then, and paste the current string into the `user_agent` option.

## Failure modes

| Symptom | Cause |
|---|---|
| A fetch still returns a challenge page or stripped markup. | The default UA major is stale. Set `user_agent` to a current string. |
| Nothing is rewritten and the command holds a URL. | The URL sits in a shell variable, inside a heredoc, or inside a quoted string. Pass `-A` yourself. |
| A local development fetch gets a browser UA. | Your host suffix is not on the internal list. Add it through `CLAUDE_CURL_UA_INTERNAL_SUFFIXES`. |
| An API starts returning 429 after you install this. | That API rate-limits browser UAs. Add its host to `CLAUDE_CURL_UA_SKIP_HOSTS`. |
| Every `curl` now prompts you. | That is the design. Set `auto_allow` if you want the trade. |

The hook fails open. A parse error or an unexpected input shape exits 0 with no output, and the original command runs, because a guard that wedges a fetch is worse than the gating it exists to avoid.

## Requirements

`python3` on `PATH`. The hook is a bash wrapper around a Python parser, and it runs on macOS stock bash 3.2.

## License

MIT
