#!/bin/bash
# The dpd contract, held to the helper's documented exit codes: a negative
# interval is refused with exit 27, 0 means "leave the server's choice alone"
# (no --force-dpd at all), and a normal value reaches openconnect's command
# line. All three assert. The world-writable-contract case that used to sit
# here was sec.sh case (a) said twice, and is gone.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"; export HOME="$SB/home"
grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null || { echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2; exit 90; }
run(){ printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x --fingerprint pin-sha256:x "$@" 2>&1; }
echo "--- a negative interval is refused, with its documented exit code ---"
out=$(run --dpd=-5); rc=$?
echo "$out" | head -1 | sed 's/^/      /'; echo "      exit=$rc"
[ "$rc" -eq 27 ] || { echo "      FAIL: expected the documented exit 27, got $rc" >&2; exit 1; }
echo "--- 0 still means 'leave the server alone' ---"
count=$(run --dpd=0 | grep -c 'force-dpd')
echo "      --force-dpd occurrences: $count"
[ "$count" -eq 0 ] || { echo "      FAIL: --dpd=0 still forced dead peer detection" >&2; exit 1; }
echo "--- a normal value still reaches openconnect ---"
forced=$(run --dpd=45 | grep -oE '\-\-force-dpd [0-9]+' | head -1)
echo "      ${forced:-no --force-dpd found}"
[ "$forced" = "--force-dpd 45" ] || { echo "      FAIL: expected --force-dpd 45, got '$forced'" >&2; exit 1; }
echo "  PASS: refused, omitted, and forwarded — each as documented"
exit 0
