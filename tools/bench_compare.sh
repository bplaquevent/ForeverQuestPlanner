#!/bin/sh
# The solver bench on the saved cases (tools/cases/), in the working tree and in another revision
# (default: main): for a change that must not alter the Roadbooks computed. A run without a computed
# route fails too (both sides failing alike would otherwise look identical), as does a service step not
# planned first. Both revisions run the cases of the working tree.
# usage: tools/bench_compare.sh [revision]
cd "$(dirname "$0")/.." || exit 1
ref=${1:-main}
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/ref" && git archive "$ref" | tar -x -C "$work/ref" || exit 1
n=0; bad=0; empty=0; wrong=0
for f in tools/cases/*.lua; do
  b=$(basename "$f" .lua)
  for opts in "--goal time:7200" "--goal level:38" "--custom 14" "--custom 14 --service" \
    "--list 8 --goal time:3600" "--list 0 --goal time:3600"; do
    n=$((n + 1))
    # $opts is split on purpose (sh). The computing time, which varies, is cut off.
    (cd "$work/ref" && lua5.1 tools/bench.lua "$OLDPWD/$f" $opts --evals 1500 --steps 2>&1 | sed -E 's/, [0-9]+\.[0-9] s$//') > "$work/old.txt"
    lua5.1 tools/bench.lua "$f" $opts --evals 1500 --steps 2>&1 | sed -E 's/, [0-9]+\.[0-9] s$//' > "$work/new.txt"
    if ! grep -q 'evaluations' "$work/new.txt" || grep -qE 'lua5.1:|traceback|unexpected argument' "$work/new.txt"; then
      empty=$((empty + 1)); echo "NO RESULT $b $opts: $(head -2 "$work/new.txt")"
    fi
    if grep -q 'service first: WRONG' "$work/new.txt"; then
      wrong=$((wrong + 1)); echo "SERVICE NOT FIRST $b $opts"
    fi
    if ! cmp -s "$work/old.txt" "$work/new.txt"; then
      bad=$((bad + 1)); echo "DIFF $b $opts"; diff "$work/old.txt" "$work/new.txt" | head -6
    fi
  done
done
echo "$n runs, $empty without result, $wrong with the service not first, $bad differences with $ref"
[ $bad = 0 ] && [ $empty = 0 ] && [ $wrong = 0 ]
