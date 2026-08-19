#!/bin/bash
# curl-ua-guard.sh: a PreToolUse(Bash) hook that gives curl and wget a real
# browser User-Agent before they leave the machine.
#
# Installable as the `curl-ua-guard` Claude Code plugin, with the rest of the kit:
#   https://github.com/moghaddas/claude-code-kit
#
# Much of the web answers `curl/8.x` differently. Anything behind Cloudflare,
# and plenty of SaaS front ends, return a challenge page, a 403, a redirect, or
# markup with the content stripped out. None of that looks like an error. The
# agent reads the challenge as the page and reports a confident finding built
# on it. Telling a model in prose to always pass a UA works until the one time
# it forgets, and the transcript does not tell you which time that was.
#
# This makes it automatic. The command is rewritten to carry `-A` (curl) or
# `-U` (wget), and Claude Code shows you the rewritten command to confirm
# before it runs. Set CLAUDE_CURL_UA_AUTO_ALLOW=1 to skip that prompt.
#
# Install as a plugin:
#
#   /plugin install curl-ua-guard@moghaddas
#
# Install standalone: save it, chmod +x, and register it as a PreToolUse hook
# on Bash in ~/.claude/settings.json:
#
#   { "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
#       { "type": "command", "command": "/path/to/curl-ua-guard.sh" }
#   ] } ] } }
#
# Configuration. A plugin option wins over the matching CLAUDE_CURL_UA*
# variable, so the standalone copy keeps working unchanged:
#   CLAUDE_CURL_UA / CLAUDE_PLUGIN_OPTION_CURL_UA_USER_AGENT
#                              the UA string. The default ages, so a strict
#                              origin may want a current one. A stale major
#                              version is one of the things an origin gates on.
#   CLAUDE_CURL_UA_AUTO_ALLOW / CLAUDE_PLUGIN_OPTION_CURL_UA_AUTO_ALLOW
#                              set to 1 to auto-approve the rewritten command.
#                              Off by default: the hook fixes a User-Agent, it
#                              is not a reason to stop prompting on curl.
#   CLAUDE_CURL_UA_INTERNAL_SUFFIXES
#                              comma-separated extra host suffixes to treat as
#                              internal. Appends to the built-in list.
#   CLAUDE_CURL_UA_SKIP_HOSTS  comma-separated exact hosts to leave alone. Use
#                              it for an API that rate-limits a browser UA but
#                              not `curl/8.x`.
#
# Scope. It only acts when it is sure it is needed:
#   - curl and wget only.
#   - Skips when a UA is already set (-A, -U, --user-agent, -H user-agent:).
#   - Injects only when the command holds at least one EXTERNAL http(s) URL
#     literal. localhost, 127.0.0.1, ::1, 0.0.0.0, host.docker.internal,
#     RFC1918, and the suffixes .local .localhost .test .internal .lan
#     .home.arpa .corp .intranet are all left alone, so local and corporate
#     development is never touched.
#   - Skips the whole command when any literal host is on the skip list. The
#     rewrite is command-wide, so it cannot inject for one host and not another.
#   - Skips anything inside a heredoc body, which is a file being written
#     rather than a command about to run.
#   - Known gap: a URL held only in a shell variable has no literal to read,
#     so nothing is rewritten. Pass -A yourself there.
#
# Fails open. A parse error or an unexpected shape exits 0 with no output and
# the original command runs, because a guard that wedges a fetch is worse than
# the gating it exists to avoid.

set -u

INPUT=$(cat)

# Cheap pre-filter, a plain substring test on the raw JSON. It deliberately
# carries no word boundary: a newline inside the command arrives as the two
# characters backslash and n, so `\bcurl` fails to match `...\ncurl ...` and
# every multi-line command would leave without being looked at. The precise
# word-boundary test belongs on the decoded command, and runs below.
printf '%s' "$INPUT" | grep -qE 'curl|wget' || exit 0

# NOTE: heredoc fed to `read`, NOT nested in $(...). macOS stock bash 3.2 has a
# parser bug with here-docs inside command substitution (mis-reads the closing
# paren as EOF). `read -d ''` slurps the whole doc and returns non-zero at EOF,
# hence `|| true`.
read -r -d '' PYCODE <<'PYEOF' || true
import sys, json, re, ipaddress, shlex

import os


def env_first(*names):
    """First environment variable that holds a non-blank value.

    Plugin options come first in every call site, so a value set in the enable
    dialog wins over the shell variable of the same meaning. Claude Code
    exports an unset option as an empty string, which is why blank counts as
    absent.
    """
    for name in names:
        value = os.environ.get(name)
        if value is not None and value.strip():
            return value.strip()
    return None


UA = env_first('CLAUDE_PLUGIN_OPTION_CURL_UA_USER_AGENT', 'CLAUDE_CURL_UA') or (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36")


def csv_set(raw):
    return [item for item in
            (part.strip().lower() for part in (raw or '').split(',')) if item]


# Suffixes that mark a host as internal. The extra list appends, so a corporate
# suffix does not cost you the built-in ones.
INTERNAL_SUFFIXES = tuple(
    ['.local', '.localhost', '.test', '.internal', '.lan', '.home.arpa',
     '.corp', '.intranet']
    + [s if s.startswith('.') else '.' + s
       for s in csv_set(env_first('CLAUDE_CURL_UA_INTERNAL_SUFFIXES'))]
)

# Hosts that answer a browser UA worse than they answer curl, so they keep the
# default one. An exact host match, not a suffix.
SKIP_HOSTS = frozenset(csv_set(env_first('CLAUDE_CURL_UA_SKIP_HOSTS')))


def allow_unchanged():
    # No output + exit 0 -> tool proceeds with the original input.
    sys.exit(0)


try:
    data = json.load(sys.stdin)
except Exception:
    allow_unchanged()

tool_input = data.get('tool_input') or {}
cmd = tool_input.get('command') or ''
if not cmd:
    allow_unchanged()

# A curl/wget command token has to be present (word-boundary, not a
# substring inside a path/URL/string).
if not re.search(r'(?:^|[\s;&|()`])(?:curl|wget)(?=[\s;&|)]|$)', cmd):
    allow_unchanged()

# Already carrying a UA anywhere in the command? Leave it alone.
ua_present = (
    re.search(r'(?:^|\s)-A(?:[=\s\'"]|$)', cmd) or            # curl short
    re.search(r'(?:^|\s)-U(?:[=\s\'"]|$)', cmd) or            # wget short
    re.search(r'--user-agent\b', cmd, re.I) or
    re.search(r'(?:-H|--header)\s*[=\s]?\s*[\'"]?\s*user-agent\s*:', cmd, re.I)
)
if ua_present:
    allow_unchanged()


def bare_host(host):
    """Host with userinfo, IPv6 brackets, and port removed."""
    h = host.strip().lower()
    h = h.split('@')[-1]
    h = h.strip('[]')          # IPv6 brackets
    h = h.split(']')[0]
    h = h.split(':')[0] if h.count(':') == 1 else h  # host:port (not bare IPv6)
    return h


def is_external(h):
    if not h:
        return False
    if h in ('localhost', '0.0.0.0', '::1', 'host.docker.internal'):
        return False
    if h.endswith(INTERNAL_SUFFIXES):
        return False
    try:
        ip = ipaddress.ip_address(h)
        # Private / loopback / link-local IPs are internal.
        return not (ip.is_private or ip.is_loopback or ip.is_link_local)
    except ValueError:
        pass  # a hostname, not an IP
    return True


def heredoc_spans(text):
    """Character ranges holding heredoc bodies.

    A heredoc body is data being written, not a command about to run. Rewriting
    a curl inside one edits the file the user is creating, which is both wrong
    and silent. Ranges found here are excluded from the rewrite.
    """
    spans = []
    for m in re.finditer(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1', text):
        delim = m.group(2)
        body = text.find('\n', m.end())
        if body < 0:
            continue
        end = re.search(r'^\s*%s\s*$' % re.escape(delim), text[body:], re.M)
        spans.append((body, body + end.start() if end else len(text)))
    return spans


def quoted_spans(text):
    """Character ranges inside a single- or double-quoted string.

    Without this the rewrite fires on the word curl wherever it appears, so
    `echo 'a curl b' && curl https://x` gets a -A flag spliced into the middle
    of the echo argument. That closes the quote early and hands the rest to
    the shell as syntax, which is a broken command at best.
    """
    spans, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '\\':
            i += 2
            continue
        if ch in ('"', "'"):
            start, quote = i, ch
            i += 1
            while i < n:
                if quote == '"' and text[i] == '\\':
                    i += 2
                    continue
                if text[i] == quote:
                    break
                i += 1
            spans.append((start, min(i + 1, n)))
        i += 1
    return spans


def outside(pos, spans):
    return not any(a <= pos < b for a, b in spans)


SPANS = heredoc_spans(cmd) + quoted_spans(cmd)

# Find http(s) URL literals and classify their hosts.
hosts = [bare_host(m.group(1))
         for m in re.finditer(r'https?://([^/\s"\'`)]+)', cmd, re.I)
         if outside(m.start(), SPANS)]
if not hosts:
    # URL is in a variable or otherwise not literal -> can't safely confirm an
    # external target, so don't touch it.
    allow_unchanged()
if any(h in SKIP_HOSTS for h in hosts):
    # One flag covers every URL in the command, so a single opted-out host
    # takes the whole command out.
    allow_unchanged()
if not any(is_external(h) for h in hosts):
    # Every literal target is local/private -> local dev, no gating risk.
    allow_unchanged()


# Inject the UA flag after each curl/wget command token. The leading char in the
# match (start / whitespace / shell operator) is preserved.
def inject(m):
    if not outside(m.start(), SPANS):
        return m.group(0)
    lead, tool = m.group(1), m.group(2)
    flag = '-A' if tool == 'curl' else '-U'
    # shlex.quote, not a hand-rolled pair of quotes. A UA holding an
    # apostrophe would otherwise close the quote and the remainder would run
    # as a command.
    return "%s%s %s %s" % (lead, tool, flag, shlex.quote(UA))


new_cmd = re.sub(r'(^|[\s;&|()`])(curl|wget)(?=[\s;&|)]|$)', inject, cmd)
if new_cmd == cmd:
    allow_unchanged()

updated = dict(tool_input)
updated['command'] = new_cmd

# "ask" shows the rewritten command and lets the user confirm it. "allow"
# would skip the prompt Claude Code shows for a command no permission rule
# covers, which on a curl command is the prompt most worth keeping: this hook
# exists to fix a User-Agent, not to widen what runs unattended. Set
# CLAUDE_CURL_UA_AUTO_ALLOW=1 to take that trade deliberately.
auto_allow = (env_first('CLAUDE_PLUGIN_OPTION_CURL_UA_AUTO_ALLOW',
                        'CLAUDE_CURL_UA_AUTO_ALLOW') or '').lower()
decision = 'allow' if auto_allow in ('1', 'true', 'yes', 'on') else 'ask'

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": (
            "Added a browser User-Agent. The default curl UA draws challenges "
            "and stripped markup that read as real content."
        ),
        "updatedInput": updated,
    }
}))
sys.exit(0)
PYEOF

printf '%s' "$INPUT" | python3 -c "$PYCODE"
