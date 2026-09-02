#!/bin/bash
# One whole life through the real tray: connect, reconnect, a probe window,
# disconnect, quit — the state asserted at every step. FAKE_TUNDEV=lo and a
# probe target that replies keep every check healthy, so the log must also
# show that a healthy tunnel was never demoted.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_TUNDEV=lo FAKE_DNS=127.0.0.1  # healthy device, target that replies (RST)
start_tray
"$A" connect >/dev/null 2>&1
await_status "Connected" 30 "connected after connect"
"$A" reconnect >/dev/null 2>&1
await_status "Connected" 60 "connected again after reconnect"
sleep 65
s="$("$A" status)"; echo "  after probes : $s"
"$A" disconnect >/dev/null 2>&1
await_status "Disconnected" 60 "disconnected on request"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- anything the watchdog complained about? ---"
complaints=$(grep -E 'check |not usable|FATAL|previous tunnel|signing in' "$LOG")
if [ -n "$complaints" ]; then printf '%s\n' "$complaints" | sed 's/^/    /'
else echo "    nothing (healthy throughout)"; fi
must_contain "still connected across the probe window" "$s" "Connected"
# A negative grep over a missing file passes vacuously, so the log's
# existence is asserted first — and the reconnect above rotated it, so the
# first connect's lines live in .1: both files are evidence.
[ -s "$LOG" ] || { echo "  FAIL: no session log was written" >&2; exit 1; }
if cat "$LOG" "$LOG.1" 2>/dev/null | grep -q 'not usable'; then
    echo "  FAIL: a healthy tunnel was demoted" >&2; exit 1
fi
# A clean run must not cry wolf: the event channel closing at teardown is
# deliberate and must stay silent. (The flag that keeps it silent is pinned
# deterministically by the selftest; this grep is the end-to-end net.)
if cat "$LOG" "$LOG.1" 2>/dev/null | grep -q 'event channel stopped'; then
    echo "  FAIL: a clean teardown warned about the event channel" >&2; exit 1
fi
echo "  PASS: whole lifecycle, healthy throughout"
exit 0
