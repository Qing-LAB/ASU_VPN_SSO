#!/bin/bash
# A tunnel that dies outright is rebuilt unasked — the break the escalation
# ladder cannot reach, because there is no tunnel left to nudge. The
# stand-in gives up the way the real binary does after its own
# --reconnect-timeout, which is what any suspend or WiFi outage longer than
# five minutes produces, and the applet must sign in again by itself and
# come back. Then the bound: a tunnel that keeps falling over must not buy
# an unbounded run of Duo pushes by touching "connected" each time round.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_TUNDEV=lo FAKE_DNS=127.0.0.1 FAKE_DIE_AFTER=6
CONF="$SB/home/.config/asuvpn/asuvpn.conf"
"$A" --write-config sslvpn.asu.edu > "$CONF"
# The gaps compressed, not removed: the scenario has to see the limit bite,
# and at the shipped 300s that is a twenty-minute test. autoreconnect is
# pinned on rather than left to the default, so this proves the behaviour
# and not the current value of a setting.
sed -i 's/^autoreconnect = .*/autoreconnect = on/
        s/^autoreconnect-min-gap = .*/autoreconnect-min-gap = 10/
        s/^health-interval = .*/health-interval = 3/' "$CONF"
echo "  config: $(grep -E '^(autoreconnect|autoreconnect-min-gap|health-interval) =' "$CONF" | tr '\n' ' ')"
start_tray
"$A" connect >/dev/null 2>&1
await_status "Connected" 30 "the tunnel came up"
# It dies at +6s, and nothing the user does asks for what happens next.
await_status "Not connected" 30 "the tunnel died on its own"
await_status "Connected" 40 "the applet rebuilt it without being asked"
# Every rebuilt tunnel dies again at +6s, so this run is the flap: each one
# reaches Connected, which is exactly how an unbounded loop would look.
sleep 75
s="$("$A" status)"; echo "  later  $s"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- what it did ---"
grep -hE 'rebuilding|did not come back|gave up|dropped' "$LOG" "$LOG".[0-9] 2>/dev/null \
  | sed 's/^/    /' | tail -12
# Counted across the rotated logs too: keep_log=True means a rebuild does not
# rotate, but the first connect did, so .1 can hold the earliest lines.
tries=$(cat "$LOG" "$LOG".[0-9] 2>/dev/null | grep -cF '[tray] rebuilding the dropped tunnel')
gave=$(cat "$LOG" "$LOG".[0-9] 2>/dev/null | grep -cF 'did not come back')
[ "$tries" -ge 1 ] || { echo "  FAIL: a tunnel that died on its own was never rebuilt" >&2; exit 1; }
[ "$tries" -le 3 ] || { echo "  FAIL: rebuilt $tries times; the limit is 3" >&2; exit 1; }
[ "$gave" -ge 1 ] || { echo "  FAIL: the limit was reached but never reported" >&2; exit 1; }
must_contain "it stopped at Not connected rather than looping" "$s" "Not connected"
echo "  PASS: rebuilt unasked, capped at $tries attempts, and said so when it gave up"
exit 0
