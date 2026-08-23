#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"; export HOME="$SB/home"
grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null || { echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2; exit 90; }
run(){ printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x --fingerprint pin-sha256:x "$@" 2>&1; }
echo "--- a negative interval is now refused, with an exit code ---"
out=$(run --dpd=-5); rc=$?
echo "$out" | head -1 | sed 's/^/      /'; echo "      exit=$rc"
echo "--- 0 still means 'leave the server alone' ---"
run --dpd=0 | grep -c 'force-dpd' | sed 's/^/      --force-dpd occurrences: /'
echo "--- a normal value still reaches openconnect ---"
run --dpd=45 | grep -oE '\-\-force-dpd [0-9]+' | head -1 | sed 's/^/      /'
echo "--- a world-writable contract is refused before it executes (the loader fires first) ---"
chmod 0666 "$A/asuvpn_contract.py"
run | head -1 | sed 's/^/      /'
chmod 0644 "$A/asuvpn_contract.py"
exit 0
