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
# Delivery, not just intent: the tray logs its line on a successful pipe
# write, before the helper acts. The stand-in's telemetry proves the verb
# crossed the pipe, became SIGUSR2, and arrived — with that line absent,
# the free rung of the ladder is dead and every incident costs a Duo push.
delivered=$(grep -cF '[stand-in] SIGUSR2 received' "$LOG")
must_contain "the badge stayed demoted" "$s" "not carrying traffic"
[ "$nudges" = 1 ] || { echo "  FAIL: expected exactly one nudge, got $nudges" >&2; exit 1; }
[ "$delivered" -ge 1 ] || { echo "  FAIL: the nudge was logged but never reached openconnect" >&2; exit 1; }
echo "  PASS: demoted on a gone device, one nudge — delivered — and demoted it stayed"
exit 0
