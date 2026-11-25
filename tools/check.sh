#!/bin/sh
# Static check of the addon files (no game needed):
# - every file listed in the .toc compiles with Lua 5.1;
# - no file reads or writes a global missing from tools/globals.txt
#   (usually a name from another file that was not imported from ns, or a typo);
# A real new WoW API / global: add it to tools/globals.txt.
cd "$(dirname "$0")/.." || exit 1
status=0
for f in $(grep -v '^#' ForeverQuestPlanner.toc | grep '\.lua' | tr '\\' '/' | tr -d '\r'); do
  out=$(luac5.1 -p -l "$f" 2>&1) || { echo "$out"; status=1; continue; }
  echo "$out" | grep -oE '[GS]ETGLOBAL.*; [A-Za-z_0-9]+' | awk '{print $NF}' | sort -u |
    grep -vxF -f tools/globals.txt -e GetLocale | sed "s|^|$f: unknown global |" | grep . && status=1
done
# - every ns.X imported at the top of a file is exported by a file loaded before it,
#   and no file is listed twice in the .toc.
lua5.1 tools/check_imports.lua || status=1
[ $status = 0 ] && echo "OK"
exit $status
