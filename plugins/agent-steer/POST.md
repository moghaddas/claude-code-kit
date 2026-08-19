# Steer a running Claude Code agent by pull, not push

`SendMessage` reaches a subagent after its task ends, exactly when you no longer need it. The message sits in a queue, and the queue is read at a turn boundary. That is the whole problem.

So a lead watching an agent go wrong has two options today. Wait for it to finish and burn the tokens, or kill it and respawn with a better brief and no memory of the work.

There is a third. Stop pushing the message, let the agent pull it.

## The mechanism

Claude Code fires a `PreToolUse` hook before every tool call. The hook gets the call as JSON on stdin, and whatever it prints back as `additionalContext` lands in that agent's context.

An agent working on a real task makes a tool call every few seconds. That is a delivery slot, several times a minute, that nothing was using.

The lead writes `~/.claude/agent-control/<agent-name>.md`. The hook reads the JSON, pulls the agent name out of `agent_id`, checks for a file with that name, and prints the contents. Next tool call, the steer is there.

Nobody told the agent to look for a file. It has no polling loop and no new instruction in its brief. The delivery happens one layer below it, and it reads the result as a message from its lead.

## Design rules

**Deliver once per write.** An agent makes hundreds of tool calls. Printing the file every time is a loop that eats the context window. The hook stamps a marker and compares timestamps, so one write delivers one time. Rewrite the file and it goes again, which is also why you rewrite in full rather than append.

**Only named agents.** The key is the `name` passed to the Agent tool. Main conversation calls carry no `agent_id`, and one `grep` for that string sends them straight out, about 9ms, before Python starts.

**Age it out.** A control file from this morning must not steer tonight's agent that happens to reuse the track name. Twelve hours, then it is ignored.

**Fail open, always.** Any parse or IO error exits 0 with no output. A hook that breaks a tool call to report its own problem is worse than the problem.

**Never touch permissions.** The hook adds context. It does not set `permissionDecision`, so every tool call keeps its normal permission flow.

## What changes in practice

Steers are corrections, stop orders and scope changes. Short ones. "The bug is in the serializer, not the parser." "Ship what you have." "Drop the CSV export from scope."

A new task is still a new agent. This is a steering wheel, not a second brief.

Code: [claude-code-kit](https://github.com/moghaddas/claude-code-kit), in `plugins/agent-steer`. MIT.
