#!/bin/bash
# Covers the Bash arm of both doc guards: the path a command names must resolve
# against the directory a leading `cd` selects, and git must run in the repository
# that holds the file. Resolving against the payload cwd instead makes every
# `cd <dir> && <write>` command silent, which is invisible without this test —
# the hooks stay quiet by design when they find nothing.
#
# Run: hooks/test-bash-arm.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
printf 'const a = 1;\n' > "$REPO/demo.js"
printf 'x\n' > "$REPO/CLAUDE.md"
git -C "$REPO" add demo.js CLAUDE.md
git -C "$REPO" commit -qm base
cat >> "$REPO/demo.js" <<'EOF'
// This used to call the old endpoint before it was fixed.
// It previously returned a different shape.
// Currently the fallback stays temporarily.
EOF
printf 'y\n' >> "$REPO/CLAUDE.md"
git -C "$REPO" add CLAUDE.md

# expect: FIRED or silent. hook: script name. cwd: payload cwd. cmd: tool_input.command
check() {
  local expect=$1 label=$2 hook=$3 pcwd=$4 cmd=$5 out actual
  out=$(python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2],
                  "tool_name": "Bash", "tool_input": {"command": sys.argv[3]}}))
' "t$RANDOM$FAIL$PASS" "$pcwd" "$cmd" | "$HERE/$hook" 2>&1)
  [ -n "$out" ] && actual=FIRED || actual=silent
  if [ "$actual" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-44s expected %s, got %s\n' "$label" "$expect" "$actual"
  fi
}

C=comment-rule-check.sh
check FIRED  "comment: relative path, cwd is the repo"   $C "$REPO"          "cat > demo.js <<EOF"
check FIRED  "comment: absolute path, cwd elsewhere"     $C "$TMP"           "sed -i s/a/b/ $REPO/demo.js"
check FIRED  "comment: cd then a heredoc"                $C "$TMP"           "cd $REPO && cat > demo.js <<EOF"
check FIRED  "comment: cd then sed -i"                   $C "$TMP"           "cd $REPO && sed -i 's/a/b/' demo.js"
check FIRED  "comment: cd then an interpreter write"     $C "$TMP"           "cd $REPO && python3 -c \"open('demo.js','w').write('')\""
check FIRED  "comment: a cd chain"                       $C "$TMP"           "cd $(dirname "$REPO") && cd repo && sed -i s/a/b/ demo.js"
check FIRED  "comment: a quoted cd argument"             $C "$TMP"           "cd \"$REPO\" && sed -i s/a/b/ demo.js"
check silent "comment: cd holds a variable"              $C "$TMP"           'cd $TARGET && sed -i s/a/b/ demo.js'
check silent "comment: the file does not exist"          $C "$TMP"           "cd $REPO && sed -i s/a/b/ nosuch.js"
check silent "comment: a read, not a write"              $C "$REPO"          "cat demo.js"

D=docs-brevity-guard.sh
check FIRED  "brevity: commit, cwd is the repo"          $D "$REPO"          "git commit -m x"
check FIRED  "brevity: commit behind a cd"               $D "$TMP"           "cd $REPO && git commit -m x"
check silent "brevity: commit, cd holds a variable"      $D "$TMP"           'cd $TARGET && git commit -m x'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
