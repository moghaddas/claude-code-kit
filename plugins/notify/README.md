# notify

A desktop notification when Claude Code needs you, or when a long turn finishes. One Operating System Command (OSC) write, no daemon, no dependencies beyond `python3`.

| Event | Banner |
|---|---|
| `Notification` | Claude needs you: a permission prompt or an idle wait. |
| `Stop` | The turn finished, and only when it ran long enough that you probably looked away. |

The banner body is the last assistant message from the transcript, prefixed with the project directory and the git branch.

## Install

```
/plugin install notify@moghaddas
```

## Why the pty and not a notifier

On a headless or remote host there is no display and no `org.freedesktop.Notifications`, so a local notifier reaches nobody. The pseudo-terminal (pty) is the one channel that crosses back to the machine you are sitting at.

Claude Code runs with no *controlling* terminal. `tty` prints `not a tty`, and every write to `/dev/tty` fails. The stdio is still a pty, so the hook cannot open the terminal by name and has to find it: it walks up the process tree and takes the first ancestor whose file descriptor 1 is a `/dev/pts/*`. On macOS `/proc` does not exist, the walk finds nothing, and `/dev/tty` is the fallback. That works, because a local session there does hold a controlling terminal.

The trap underneath: a terminal synthesised by `pty.fork()` in a test **does** give you `/dev/tty`. A harness shows the notification working while the live session stays quiet. Test it in a real session or you test nothing.

## Pick your OSC sequence

Terminals disagree on the sequence, and a terminal that does not know the one you send drops it without an error. Set `osc` to match your terminal.

| Value | Terminals | Shape |
|---|---|---|
| `777` (default) | VS Code through the `terminal-osc-notifier` extension, tmux passthrough, urxvt | `ESC ] 777 ; notify ; title ; body BEL` |
| `9` | iTerm2 | `ESC ] 9 ; title: body BEL` |
| `99` | kitty, WezTerm, Ghostty | Two chunks under one id: `p=title` with `d=0`, then `p=body` |

OSC 9 carries a body and no title field. The hook folds the title into the body as `title: body`, so an iTerm2 banner reads on one line rather than losing the title.

## What it does not do

- **It does not reach a terminal that drops your sequence.** That is silence with no error, which is why `CC_NOTIFY_DEBUG=1` exists.
- **It does not cross a multiplexer that fails to forward OSC.** A multiplexer between the hook and the editor has to pass the sequence outward, or the banner stops there. The ancestry walk goes six levels, which covers shell to node to hook; a multiplexer that buries the pty deeper has already broken OSC forwarding anyway.
- **It does not use a notification daemon, and it does not fall back to one.** The pty is the whole design.
- **It does not notify on a short turn.** See `CC_NOTIFY_MIN_SECONDS`.

## Configuration

Three options appear in the enable dialog. Every option also has a shell variable, and the plugin option wins when both hold a value. Set each one in a single place, otherwise the enable-dialog value shadows your shell variable and you debug the wrong string.

| Option / variable | Effect |
|---|---|
| `osc` / `CC_NOTIFY_OSC` | `777` (default), `9`, or `99`. An unrecognised value prints a warning on stderr and falls back to `777`. |
| `title` / `CC_NOTIFY_TITLE` | Title for **both** events. A value here costs you the needs-you and finished distinction unless you also set the done title. |
| `title_done` / `CC_NOTIFY_TITLE_DONE` | Title for the `Stop` event only. It wins over `title`, which restores the distinction. |
| `CC_NOTIFY=off` | Disable entirely. `0`, `false`, and `no` also work. |
| `CC_NOTIFY_MIN_SECONDS` | Minimum turn length before `Stop` fires, default `60`. A three second exchange you were watching does not need a banner. |
| `CC_NOTIFY_MAX_BODY` | Body length in characters before truncation, default `180`. A truncated body ends in an ellipsis. An invalid value falls back to `180`. |
| `CC_NOTIFY_DEBUG=1` | Print the resolved pty, the title, the body, and the exact bytes written to stderr. |

Titles resolve in this order for `Stop`: `title_done`, `CC_NOTIFY_TITLE_DONE`, `title`, `CC_NOTIFY_TITLE`, then `Claude Code: done`. For `Notification` the done titles are ignored.

Semicolons and BEL in the title and the body get replaced before the write. Either one would end the OSC string early and truncate the banner.

## Failure modes

Every one of these is silent without `CC_NOTIFY_DEBUG=1`. Set it first.

| Symptom | Cause |
|---|---|
| No banner, and debug prints `target is not writable`. | No pty in the six-level ancestry. The hook has no channel back to you. |
| No banner, and debug prints the bytes with a `/dev/pts/*` target. | Your terminal does not read that sequence, or a multiplexer swallows it. Try another `osc` value. |
| No banner after a short turn, and debug prints `stop suppressed`. | The turn was shorter than `CC_NOTIFY_MIN_SECONDS`. That is the design. |
| Nothing at all, and debug prints `disabled by CC_NOTIFY=off`. | `CC_NOTIFY` is set to a disabling value in your environment. |
| The banner shows a title and no body, or a body and no title. | You picked an `osc` value your terminal reads partially. `9` has no title field at all. |
| The banner title is not the one you set. | The plugin option shadows the shell variable. Clear one of them. |

## Requirements

`python3` and `git` on `PATH`. `git` resolves the branch label and times out after three seconds, so a slow repository delays the banner rather than losing it.

The hook is a bash script, which needs Git Bash on Windows.

## License

MIT
