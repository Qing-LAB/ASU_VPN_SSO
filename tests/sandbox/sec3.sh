#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"; export HOME="$SB/home"
run(){ printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x --fingerprint pin-sha256:x "$@" 2>&1; }
echo "--- a negative interval is now refused, with an exit code ---"
out=$(run --dpd=-5); rc=$?
echo "$out" | head -1 | sed 's/^/      /'; echo "      exit=$rc"
echo "--- 0 still means 'leave the server alone' ---"
run --dpd=0 | grep -c 'force-dpd' | sed 's/^/      --force-dpd occurrences: /'
echo "--- a normal value still reaches openconnect ---"
run --dpd=45 | grep -oE '\-\-force-dpd [0-9]+' | head -1 | sed 's/^/      /'
echo "--- the runtime check now names the contract too ---"
chmod 0666 "$A/asuvpn_contract.py"
run | head -1 | sed 's/^/      /'
chmod 0644 "$A/asuvpn_contract.py"
exit 0
