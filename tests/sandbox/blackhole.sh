#!/bin/bash
# Healthy device, silent probe target: only the probe can see this break, so
# only the probe may promote. Expect a demotion blamed on the probe, exactly
# one nudge, and a badge that stays demoted however healthy the device looks.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
# device that is genuinely healthy, target that will never answer (RFC 5737)
export FAKE_TUNDEV=lo FAKE_DNS=198.51.100.1
start_tray
"$A" connect >/dev/null 2>&1
await_status "not carrying traffic" 240 "the probe demoted the tunnel"
sleep 45
s="$("$A" status)"; echo "  later  $s"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- log ---"
grep -E 'STATE|device check|probe|not usable|re-establish' "$LOG" | sed 's/^/    /'
nudges=$(grep -cF '[tray] asked openconnect to re-establish' "$LOG")
must_contain "the badge stayed demoted" "$s" "not carrying traffic"
must_contain "the verdict names the probe" \
  "$(grep 'not usable' "$LOG" | head -1)" "nothing answers"
[ "$nudges" = 1 ] || { echo "  FAIL: expected exactly one nudge, got $nudges" >&2; exit 1; }
echo "  PASS: a black hole is caught by the probe alone; one nudge; badge honest"
exit 0
