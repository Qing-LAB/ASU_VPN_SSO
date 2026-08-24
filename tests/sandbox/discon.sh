#!/bin/bash
# A demoted tunnel is still an established one. FAKE_DEAF makes the nudge do
# nothing and the fake names a device that does not exist, so the watchdog
# demotes — and then Disconnect must still tear it down cleanly: exit 0 from
# the CLI, Disconnected on the badge.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_DEAF=1
start_tray
"$A" connect >/dev/null 2>&1
await_status "not carrying traffic" 90 "the tunnel was demoted"
"$A" disconnect >/dev/null 2>&1; drc=$?
s="$("$A" status)"
echo "  after disconnect (disconnect exited $drc): $s"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
[ "$drc" -eq 0 ] || { echo "  FAIL: disconnect exited $drc on a demoted tunnel" >&2; exit 1; }
must_contain "disconnected at the end" "$s" "Disconnected"
echo "  PASS: a demoted tunnel disconnects cleanly"
exit 0
