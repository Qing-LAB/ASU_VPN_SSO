#!/bin/bash
# The watchdog's ladder, end to end: one free nudge, then — with
# autoreconnect on — one full sign-in, and never more of either inside the
# window. The counts are the design, so they are asserted, not just printed.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_DEAF=1
"$A" autoreconnect on >/dev/null
start_tray
"$A" connect >/dev/null 2>&1
for t in 25 25 25 25; do sleep $t; echo "  $(date +%M:%S)  $("$A" status)"; done
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- what it did ---"
grep -E 'not usable|re-establish|SIGUSR2|signing in again|tunnel check|authenticating' \
  "$LOG" 2>/dev/null | sed 's/^/    /'
# -F and the [tray] prefix: the helper echoes a similar sentence for the same
# nudge, and a loose substring counted the one nudge twice.
nudges=$(grep -cF '[tray] asked openconnect to re-establish' "$LOG" 2>/dev/null || true)
signins=$(grep -cF '[tray] signing in again to rebuild' "$LOG" 2>/dev/null || true)
if [ "$nudges" = 1 ] && [ "$signins" = 1 ]; then
  echo "  PASS: exactly one free nudge and one sign-in over the window"
  exit 0
fi
echo "  FAIL: expected one nudge and one sign-in; got nudges=$nudges signins=$signins" >&2
exit 1
