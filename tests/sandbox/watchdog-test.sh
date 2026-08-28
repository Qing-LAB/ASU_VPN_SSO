#!/bin/bash
# A gone device: strikes, demotion, exactly one nudge — and a badge that
# stays demoted while the device never returns, whatever the reconnect event
# the nudge produced claims.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
# Pinned off, not left to the default: this scenario is about the nudge-only
# path, and a default that permits the sign-in rung would change what it
# proves without changing a line of it.
"$A" autoreconnect off >/dev/null
start_tray
"$A" connect >/dev/null 2>&1; sleep 2
echo "  t+2s   $("$A" status)"
await_status "not carrying traffic" 90 "the tunnel was demoted"
sleep 25
s="$("$A" status)"; echo "  later  $s"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- log ---"
grep -E 'force-dpd|not usable|re-establish|SIGUSR2|tunnel check|healthy again|STATE' \
  "$LOG" | sed 's/^/    /'
nudges=$(grep -cF '[tray] asked openconnect to re-establish' "$LOG")
must_contain "the badge stayed demoted" "$s" "not carrying traffic"
[ "$nudges" = 1 ] || { echo "  FAIL: expected exactly one nudge, got $nudges" >&2; exit 1; }
echo "  PASS: demoted on a gone device, one nudge, and demoted it stayed"
exit 0
