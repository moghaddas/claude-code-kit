#!/bin/bash
# comment-rule-check.sh: a PostToolUse(Edit|Write|Bash) hook that flags comments
# which will rot, in code the model has written.
#
# The model can follow a comment policy. The trouble is that a policy sitting
# in context competes with the task in front of it, and a verbosity prior
# pulls the other way, so the rules get under-applied exactly when nobody is
# looking. This surfaces the cheap-to-detect misses at write time, while the
# diff is still on screen.
#
# It NEVER blocks. It returns hookSpecificOutput.additionalContext listing what
# it found, so a false positive costs a glance. That is also why the keyword
# set is narrow: a noisy guard gets switched off, and a guard that is off
# catches nothing.
#
# What it flags, all matched against comment TEXT only:
#   - history narration (used to / previously / regression / now uses / fixes the bug)
#   - "was ... before"
#   - provenance (formerly / ported from / renamed from / replaces the old)
#   - temporal hedges (soon / eventually / currently disabled / temporarily
#     hardcoded), which either state a durable fact flatly or rot
#   - a calendar date, or a measured metric like ~300ms or 3x faster
#   - a ticket ID, when you configure prefixes (see below)
#   - an inline // run of 3+ consecutive lines, and commented-out code
#
# One rule sits under all of it: a comment states what is true now and what
# breaks without it. How the code got here is in git, and a comment repeating
# it drifts the moment the code moves.
#
# Configuration. Every value is an environment variable:
#   COMMENT_CHECK_EXTENSIONS       Comma-separated file extensions to read, with
#                                  or without a leading dot. An empty value
#                                  keeps the shipped list.
#   COMMENT_CHECK_SKIP_DIRS        Comma-separated directory names to skip. An
#                                  empty value skips no directory.
#   COMMENT_CHECK_MAX_COMMENT_RUN  Inline // run length that trips the shape
#                                  check. Default 3. A value below 1 falls back.
#   COMMENT_CHECK_RULES            Path to a JSON file that replaces the text
#                                  checks. The file holds an array of
#                                  {"pattern": "...", "finding": "..."} objects.
#                                  A file that does not parse, an entry without
#                                  both keys, and an invalid regex all fall back
#                                  to the shipped rules.
#   COMMENT_CHECK_TICKET_PREFIXES  Comma-separated, e.g. "PROJ,BACKEND". The
#                                  ticket check is OFF unless you set this,
#                                  because a generic ticket shape also matches
#                                  UTF-8, SHA-256 and RFC-1918.
#   CLAUDE_PLUGIN_OPTION_COMMENT_CHECK
#                                  Set by the doc-guards plugin. Any value other
#                                  than true/1/yes/on exits the hook at once. An
#                                  unset value keeps the hook enabled, so a
#                                  standalone copy needs no configuration.
#
# Install: chmod +x, then in ~/.claude/settings.json
#   { "hooks": { "PostToolUse": [ { "matcher": "Edit|Write|Bash", "hooks": [
#       { "type": "command", "command": "/path/to/comment-rule-check.sh" }
#   ] } ] } }
#
# Two ways in, because a code file arrives by two routes. Edit and Write carry the
# added text in tool_input. A Bash command does not: a heredoc, a redirect, `sed -i`,
# `cp`, `mv`, or an interpreter one-liner writes the file and leaves no text to read,
# so the added lines come from `git diff HEAD -U0` on each file the command writes.
# Cover Bash, or the hook goes quiet for a whole session: an agent told to prefer
# shell tools edits every file that way.
#
# The Bash arm reads git, so it reports every uncommitted added line in the file, not
# only the lines one command wrote. Nothing offers a per-call baseline after the fact.
# A per-file findings digest keeps a repeated report silent, so a loop of `sed -i`
# calls speaks once.
#
# Scope. It only looks at text being added (Edit.new_string, Write.content, or the
# added side of the diff), never at committed comments, and only in the configured
# extensions.
# Shell, YAML and Markdown are outside the shipped list, because a long # or
# <!-- --> block is idiomatic there. Generated and vendored trees are left
# alone. Docblocks are exempt from the run rule, since a shared definition
# earns a real explanation.
#
# The two shape checks read // line comments only. A file whose line comment is
# # gets the text checks and no shape check, because a multi-line # block is
# idiomatic in Python and Ruby.
#
# Dates and metrics carry extra guards: URLs are stripped before matching, and
# a line reading as a data-shape example or a licence header is exempt.
#
# Fails open. A parse error or an unexpected shape exits 0 with no output, so
# the edit is never disturbed.

set -u

# Plugin opt-out, before any work. An unset value means enabled.
case "${CLAUDE_PLUGIN_OPTION_COMMENT_CHECK-}" in
  '' | [Tt][Rr][Uu][Ee] | 1 | [Yy][Ee][Ss] | [Oo][Nn]) ;;
  # Drain stdin before leaving, so the writer never sees a broken pipe.
  *) cat >/dev/null 2>&1; exit 0 ;;
esac

COMMENT_CHECK_EXT_DEFAULT='php,js,jsx,ts,tsx,vue,mjs,cjs,py,go,rs,java,kt,kts,cs,rb,swift'
export COMMENT_CHECK_EXT_DEFAULT

INPUT=$(cat)

# Cheap pre-filter: only an edit to a configured extension can match. The
# alternation is built from the same list the Python check reads, so the filter
# cannot drop a file the check would have flagged.
_EXT_ALTERNATION=$(
  printf '%s' "${COMMENT_CHECK_EXTENSIONS:-$COMMENT_CHECK_EXT_DEFAULT}" |
    sed -E -e 's/[[:space:]]+//g' -e 's/(^|,)\.+/\1/g' -e 's/\./\\./g' -e 's/,+/|/g' -e 's/^\|+|\|+$//g'
)
[ -n "$_EXT_ALTERNATION" ] || exit 0
printf '%s' "$INPUT" | grep -qE "\.($_EXT_ALTERNATION)\b" || exit 0

# NOTE: heredoc fed to `read`, NOT nested in $(...). macOS stock bash 3.2 has a parser
# bug with here-docs inside command substitution. `read -d ''` returns non-zero at EOF,
# hence `|| true`.
read -r -d '' PYCODE <<'PYEOF' || true
import sys, json, re, os, time, hashlib, subprocess


def passthrough():
    # No output + exit 0 -> tool result is delivered unchanged.
    sys.exit(0)


try:
    data = json.load(sys.stdin)
except Exception:
    passthrough()

tool = data.get('tool_name') or ''
tool_input = data.get('tool_input') or {}
cwd = data.get('cwd') or ''
session = data.get('session_id') or ''

CODE_EXT = tuple(
    '.' + e.strip().lstrip('.').lower()
    for e in (os.environ.get('COMMENT_CHECK_EXTENSIONS')
              or os.environ.get('COMMENT_CHECK_EXT_DEFAULT', '')).split(',')
    if e.strip().strip('.')
)
EXT_ALT = '|'.join(re.escape(e.lstrip('.')) for e in CODE_EXT)

# Generated and vendored trees hold prose nobody is going to rewrite, and a minified
# bundle is one long line of punctuation that matches almost anything.
# `bin` is absent on purpose: src/bin/*.rs is the canonical home of a Rust binary.
_SKIP_DEFAULT = ('node_modules,vendor,dist,build,out,target,obj,.venv,venv,'
                 'site-packages,__pycache__,.tox,.mypy_cache,.next,coverage')
_SKIP_DIRS = [d.strip().strip('/') for d in
              os.environ.get('COMMENT_CHECK_SKIP_DIRS', _SKIP_DEFAULT).split(',')
              if d.strip().strip('/')]
_SKIP_RE = re.compile(
    r'(?:^|/)(?:%s)/' % '|'.join(re.escape(d) for d in _SKIP_DIRS)) if _SKIP_DIRS else None


def eligible(path):
    """A file this hook reads. Everything else leaves without an analysis."""
    if not path or not path.lower().endswith(CODE_EXT):
        return False
    if _SKIP_RE and _SKIP_RE.search(path):
        return False
    return not re.search(r'\.min\.[cm]?js$', path)

try:
    MAX_COMMENT_RUN = int(os.environ.get('COMMENT_CHECK_MAX_COMMENT_RUN', '').strip() or 3)
except ValueError:
    MAX_COMMENT_RUN = 3
if MAX_COMMENT_RUN < 1:
    MAX_COMMENT_RUN = 3

# Each entry is (pattern, finding). Matched case-insensitively against comment text.
_PREFIXES = [p.strip().upper() for p in
             os.environ.get('COMMENT_CHECK_TICKET_PREFIXES', '').split(',') if p.strip()]

DEFAULT_CHECKS = (
    # Bare "now" and bare "fix" are absent on purpose. "now that the lock is held" is
    # present-tense prose, and "fixed-width" is a noun. Each token needs the word that
    # makes it narration.
    (r'\b(?:used to|previously|regression)\b'
     r'|\bnow\s+(?:uses?|returns?|handles?|calls?|reads?|writes?|sends?|runs?|does|'
     r'only|always|never|instead|defaults?)\b'
     r'|\bbug ?fix(?:e[sd])?\b'
     r'|\bfix(?:e[sd])?\s+(?:the\s+|a\s+|an\s+)?(?:bug|issue|regression|crash|leak|'
     r'race|typo)\b',
     "History narration (used to / previously / regression / now uses / fixes the bug). "
     "Rewrite it to state only current behaviour."),
    (r'\bwas\b.*\bbefore\b',
     '"was ... before" narration. State what the code does now.'),
    # "X replaces the Y" is usually current behavior; only replacing something named as
    # outgoing is provenance.
    (r'\b(?:formerly|ported from|migrated from|renamed from|moved from)\b'
     r'|\breplaces the\s+(?:old|legacy|previous|former|manual|deprecated)\b',
     "Provenance (formerly / ported from / renamed from / replaces the old). Describe "
     "the current shape only."),
    # "currently"/"temporarily" alone describe runtime state far more often than code
    # status ("temporary file", "currently attached"), so both need a status word after
    # them to count.
    (r'\b(?:at the moment|for the time being|eventually|soon|until we|'
     r'will be (?:removed|replaced|dropped))\b'
     # A date can legitimately be "in the future"; only a plan rots.
     r'|\b(?:will|would|may|might|plan(?:ned)?|intend|hope)\b[^.]{0,40}?\bin the future\b'
     r'|\b(?:currently|temporar(?:y|ily))\s+(?:only|disabled|unused|unsupported|broken|'
     r'stubbed|a stub|skipped|commented|hard-?coded|off|not\s+\w+)\b',
     "Temporal hedge (soon / eventually / currently disabled). If the fact is durable, "
     "state it flatly. Otherwise cut the comment."),
)


def load_checks(default):
    """Rules from COMMENT_CHECK_RULES, or the shipped set when the file is unusable."""
    path = os.environ.get('COMMENT_CHECK_RULES', '').strip()
    if not path:
        return default
    try:
        with open(path) as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return default
    if not isinstance(raw, list):
        return default
    rules = []
    for item in raw:
        try:
            pattern = item['pattern']
            finding = item['finding']
            re.compile(pattern)
        except (TypeError, KeyError, IndexError, re.error):
            continue
        rules.append((pattern, finding))
    return tuple(rules) or default


CHECKS = load_checks(DEFAULT_CHECKS)

if _PREFIXES:
    # Only ever built from configured prefixes. A generic ticket shape,
    # [A-Z]{2,10}-\d+, also matches UTF-8, SHA-256, AES-256 and RFC-1918, and a
    # guard that fires on those is one nobody keeps.
    CHECKS += ((r'\b(?:%s)-[A-Za-z0-9]' % '|'.join(re.escape(p) for p in _PREFIXES),
                "Ticket reference in a comment. State the durable fact instead."),)

DATE_RE = re.compile(
    r'\b\d{4}-\d{2}-\d{2}\b'
    r'|\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|'
    r'Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?,?\s+'
    r'(?:19|20)\d{2}\b'
    r'|\bas of\b|\bsince\s+(?:19|20)\d{2}\b',
    re.I,
)

# A date-shaped string is durable when it documents a data shape or sits in a licence
# header. Only a temporal claim about the code itself rots. A quoted or timestamped date
# is a data literal, not a claim.
DATE_EXEMPT_RE = re.compile(
    r'\be\.g\.|\bexample|\bsample|\bformat|\bISO[- ]?8601|\bcopyright|\blicen[cs]e|'
    r'\d{4}-\d{2}-\d{2}T|[\'"`]\d{4}-\d{2}-\d{2}[\'"`]',
    re.I,
)

# A bare number is often a durable invariant ("the shortest 3-month span is 89 days"),
# so a figure only counts as a measurement when a measuring verb or a "~" introduces it.
MEASURE_RE = re.compile(
    r'\b\d+(?:\.\d+)?\s*(?:x|×)\s*(?:faster|slower|fewer|more|less|cheaper)\b'
    r'|(?:\b(?:takes?|took|runs? in|drops?|dropped|reduces?|reduced|improves?|improved|'
    r'saves?|saved|shaves?|down from|up from|benchmark(?:ed)?|measured|profil(?:ed|ing))'
    r'\b[^.]{0,40}?|~\s*)'
    r'\d+(?:\.\d+)?\s*[kKmM]?\s*'
    r'(?:ms|s|secs?|seconds?|min(?:ute)?s?|%|[KMG]i?B|rows|records|queries|'
    r'req(?:uests)?|rps|qps)\b',
    re.I,
)

URL_RE = re.compile(r'https?://\S+', re.I)

# Prose almost never ends in a semicolon or an opening brace; a statement almost always
# does. That trailing anchor is what keeps this off explanatory comments. The keyword set
# covers every // language the extension list can name, including one a user adds.
CODE_LINE_RE = re.compile(
    r'^//+\s*(?:'
    r'(?:const|let|var|val|return|await|throw|new|import|export|using|namespace|'
    r'public|private|protected|static|void|function|func|fn|def|struct|impl|pub|'
    r'package|use|defer|echo)\b'
    r'|[\w$)\]]+\s*(?:=|=>|->|::|\.)\s*\S'
    r').*[;{]\s*$'
)

def scan(added):
    """Findings for a block of added source. Walks /* */ block state and collects
    comment TEXT only, so a keyword inside code or a string literal cannot trip a
    check, and tracks the longest run of consecutive inline // comments."""
    comments = []
    in_block = False
    run = 0
    long_run = False
    commented_code = False

    for raw in added.splitlines():
        t = raw.lstrip()
        is_comment = False
        text = ''

        if in_block:
            is_comment, text = True, t
            if '*/' in raw:
                in_block = False
        elif t.startswith('/*'):
            is_comment, text = True, t
            if '*/' not in t:
                in_block = True
        elif t.startswith('*'):          # docblock continuation
            is_comment, text = True, t
        elif t.startswith('//'):         # line comment
            is_comment, text = True, t
        elif t.startswith('#') and not t.startswith('#['):   # #[...] is an attribute
            is_comment, text = True, t
        elif t.startswith('<!--'):       # vue/html template comment
            is_comment, text = True, t
        else:
            # Trailing comment. The lookbehind keeps a URL's "//" from reading as one.
            m = re.search(r'(?<!:)//', raw)
            if m:
                is_comment, text = True, raw[m.start():]

        # Consecutive inline // run only. Docblock /* and * styles do not count, and neither
        # does a # block, which is the idiomatic form in Python and Ruby.
        if t.startswith('//'):
            run += 1
            if run >= MAX_COMMENT_RUN:
                long_run = True
            if CODE_LINE_RE.match(t):
                commented_code = True
        else:
            run = 0

        if is_comment:
            comments.append(text)

    findings = []

    if long_run:
        findings.append(
            "An inline // block runs %d+ lines. Cut it shorter, or move it into a docblock "
            "on a shared definition." % MAX_COMMENT_RUN
        )

    if commented_code:
        findings.append(
            "Commented-out code added. Delete the line."
        )

    if comments:
        blob = '\n'.join(comments)
        for pattern, message in CHECKS:
            try:
                hit = re.search(pattern, blob, re.I)
            except re.error:
                continue
            if hit:
                findings.append(message)

        # Per-line, so an exempting phrase on one comment can't mask a violation on another.
        probes = [URL_RE.sub(' ', text) for text in comments]

        if any(DATE_RE.search(p) and not DATE_EXEMPT_RE.search(p) for p in probes):
            findings.append(
                "A calendar date or an \"as of\" claim. State the durable fact instead, "
                "or drop the comment."
            )

        if any(MEASURE_RE.search(p) for p in probes):
            findings.append(
                "A measured metric (timing, throughput, row count, speedup). Replace the "
                "number with the invariant that makes it matter."
            )

    return findings


# ---------------------------------------------------------------- the Bash arm

# A shell verb that writes the path that follows it. A read (cat, grep, less) matches
# nothing here and the path is dropped.
WRITE_HINT_RE = re.compile(
    r'(>>?|\btee\b|\bsed\b[^|;&]*-i|\bperl\b[^|;&]*-i|\bcp\b|\bmv\b|\bdd\b'
    r'|\binstall\b|\bpatch\b)'
)
# An interpreter one-liner writes through a call, not a redirect, so the window before
# the path holds no hint and the call can sit any distance away. Both halves are needed:
# the flag that makes it a one-liner, and a call that opens a file for writing. A
# one-liner that only reads matches the first and not the second.
INTERPRETER_FLAG_RE = re.compile(
    r'\b(?:python3?|node|ruby|perl|deno|bun|php)\b[^|;&]*?\s-(?:c|e|r)\b'
)
WRITE_CALL_RE = re.compile(
    r'\bwrite_?File(?:Sync)?\b|\bcreateWriteStream\b|\bwrite_text\b'
    r'|\bfile_put_contents\b|\bFile\.write\b'
    r'|\bopen\s*\([^)]*[\'"][wax]'
)
# A whole-file write. `>>` and `sed -i` change part of a file, so reading that file
# entire would report lines the command never touched.
FULL_WRITE_RE = re.compile(r'(?<![>\d])>(?!>)|<<|\bcp\b|\bmv\b|\binstall\b')
PATH_RE = re.compile(r'[\w./@~+-]*\.(?:%s)\b' % EXT_ALT, re.I)

MAX_BASH_FILES = 5
READ_CAP = 256 * 1024

STATE_DIR = os.path.join(
    os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache'),
    'claude-comment-rule-%d' % os.getuid())
STATE_TTL = 3 * 24 * 3600


def git(args):
    """A completed git run, or None when git cannot answer."""
    try:
        return subprocess.run(['git'] + args, cwd=cwd or None,
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None


def tracked(path):
    """True, False, or None when the path sits outside a repository."""
    r = git(['ls-files', '--error-unmatch', '--', path])
    if r is None or 'not a git repository' in (r.stderr or '').lower():
        return None
    return r.returncode == 0


def diff_added(path):
    """Uncommitted added lines for a tracked path, staged and unstaged both."""
    r = git(['diff', 'HEAD', '-U0', '--', path])
    if r is None or r.returncode != 0:
        return ''
    return '\n'.join(line[1:] for line in r.stdout.splitlines()
                     if line.startswith('+') and not line.startswith('+++'))


def read_capped(abspath):
    try:
        if os.path.getsize(abspath) > READ_CAP:
            return ''
        with open(abspath, errors='replace') as fh:
            return fh.read()
    except OSError:
        return ''


def bash_units(command):
    """(path, added text) for each code file the command writes."""
    if not command:
        return []
    interpreter = bool(INTERPRETER_FLAG_RE.search(command)
                       and WRITE_CALL_RE.search(command))
    # An interpreter write replaces the file through the call, so it is whole by
    # definition and carries no redirect for FULL_WRITE_RE to find.
    full_write = interpreter or bool(FULL_WRITE_RE.search(command))
    seen = set()
    units = []
    for m in PATH_RE.finditer(command):
        path = m.group(0).strip('.')
        if not eligible(path) or path in seen:
            continue
        window = command[max(0, m.start() - 80):m.start()]
        if not interpreter and not WRITE_HINT_RE.search(window) and '<<' not in window:
            continue
        seen.add(path)
        abspath = path if os.path.isabs(path) else os.path.join(cwd or '.', path)
        if not os.path.isfile(abspath):
            continue
        state = tracked(path)
        if state is True:
            added = diff_added(path)
        elif full_write:
            # Untracked, or no repository at all. The whole file counts as new text
            # only because the command wrote it whole.
            added = read_capped(abspath)
        else:
            added = ''
        if added.strip():
            units.append((path, added))
        if len(units) >= MAX_BASH_FILES:
            break
    return units


def claim(key):
    """True the first time this session reports `key`, False on every repeat. Keyed on
    the findings themselves, so a re-run of one command stays silent while a new
    finding still lands."""
    safe = re.sub(r'[^A-Za-z0-9_-]', '_', session or 'nosession')[:64]
    path = os.path.join(STATE_DIR, safe)
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(path):
            with open(path) as fh:
                seen = fh.read().split('\n')
        else:
            cutoff = time.time() - STATE_TTL
            for entry in os.scandir(STATE_DIR):
                # is_file() follows a symlink, so it reports a link to somebody else's
                # file as a plain file and unlinks it. Ask about the entry.
                st = entry.stat(follow_symlinks=False)
                if entry.is_file(follow_symlinks=False) and st.st_mtime < cutoff:
                    os.unlink(entry.path)
            seen = []
        if key in seen:
            return False
        with open(path, 'a') as fh:
            fh.write(('\n' if seen else '') + key)
        return True
    except OSError:
        # An unwritable cache must not silence a finding.
        return True


# ---------------------------------------------------------------- dispatch

if tool == 'Bash':
    units = bash_units(tool_input.get('command') or '')
elif tool in ('Edit', 'Write'):
    file_path = tool_input.get('file_path') or ''
    added = tool_input.get('new_string')
    if added is None:
        added = tool_input.get('content')
    units = [(file_path, added)] if eligible(file_path) and added else []
else:
    units = []

if not units:
    passthrough()

blocks = []
for path, added in units:
    found = scan(added)
    if not found:
        continue
    if tool == 'Bash':
        digest = hashlib.sha256(
            ('\n'.join([os.path.abspath(path)] + found)).encode()).hexdigest()[:16]
        if not claim(digest):
            continue
    blocks.append("%s:\n- %s" % (os.path.basename(path), "\n- ".join(found)))

if not blocks:
    passthrough()

note = (
    "Comment-rule check (advisory, not blocking):\n%s\n"
    "Rewrite the real ones to state what is true now. Ignore any that are deliberate."
    % "\n".join(blocks)
)

# Hook output strings are capped at 10000 characters. A rules file of your own can carry
# any finding text, so the note is bounded here.
MAX_CONTEXT = 9500
if len(note) > MAX_CONTEXT:
    note = note[:MAX_CONTEXT].rstrip() + "\n[findings truncated]"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": note,
    }
}))
sys.exit(0)
PYEOF

printf '%s' "$INPUT" | python3 -c "$PYCODE"
