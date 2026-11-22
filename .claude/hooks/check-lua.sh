#!/bin/sh
# Stop hook: when .lua files differ from HEAD, run tools/check.sh.
# On failure the errors go back to Claude (exit 2) so it fixes them;
# a second failure in a row only warns, to never loop.
cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}" || exit 0
input=$(cat)
git status --porcelain -- '*.lua' | grep -q . || exit 0
out=$(tools/check.sh 2>&1) && exit 0
if echo "$input" | grep -q '"stop_hook_active": *true'; then
  echo "tools/check.sh still fails:" >&2; echo "$out" >&2; exit 1
fi
echo "tools/check.sh failed, fix these errors:" >&2
echo "$out" >&2
exit 2
