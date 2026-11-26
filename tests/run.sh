#!/bin/sh
# Tests of the addon with the game faked (tests/harness.lua), no game needed. Each tests/test_*.lua
# runs alone. The solver has its own test bench: tools/bench.lua (see tools/bench_compare.sh).
cd "$(dirname "$0")/.." || exit 1
status=0
for t in tests/test_*.lua; do
  out=$(lua5.1 "$t" 2>&1) || status=1
  printf '%s: %s\n' "$t" "$(printf '%s\n' "$out" | tail -n 1)"
  printf '%s\n' "$out" | grep -v ' checks, ' | grep -E 'FAIL|lua5\.1:|stack traceback' | sed 's/^/  /'
done
[ $status = 0 ] && echo "OK"
exit $status
