#!/bin/bash
# The authorization prompt nobody answers. polkit agents do not time out, so
# an unattended rebuild raised a password dialog and the applet sat behind it
# in "Connecting…" -- a state the watchdog does not run in -- until somebody
# came back to the machine. signin-timeout bounds the browser half of a
# sign-in; this is the half after it, which nothing bounded at all.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_PKEXEC_HANG=1
CONF="$SB/home/.config/asuvpn/asuvpn.conf"
"$A" --write-config sslvpn.asu.edu > "$CONF"
# 60 is the floor the schema allows, not a number this scenario invented:
# the deadline has no off switch, so the shortest legal wait is what a test
# of it has to sit through.
sed -i 's/^signin-timeout = .*/signin-timeout = 60/
        s/^health-interval = .*/health-interval = 3/' "$CONF"
echo "  config: $(grep -E '^(signin-timeout|health-interval) =' "$CONF" | tr '\n' ' ')"
start_tray
"$A" connect >/dev/null 2>&1
await_status "Connecting" 40 "the sign-in finished and the prompt went up"
hung=$(pgrep -f "^sleep 3600$" | head -1)
[ -n "$hung" ] || { echo "  FAIL: no stand-in prompt is waiting" >&2; exit 1; }
# The deadline is 60s and the tick runs every 3s; 100 is margin for a loaded
# machine, not more behaviour.
await_status "Not connected" 100 "the applet stopped waiting on the prompt"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- what it did ---"
grep -hE 'authorization|Connecting|starting openconnect' "$LOG" 2>/dev/null \
  | sed 's/^/    /' | tail -8
said=$(grep -cF 'authorization was not answered' "$LOG" 2>/dev/null || true)
[ "$said" -ge 1 ] || { echo "  FAIL: it gave up without saying why" >&2; exit 1; }
# The dialog is dismissed, not merely abandoned: an orphaned prompt is what
# the quit path already learned to avoid, and a deadline that leaves one is
# only half a fix.
if kill -0 "$hung" 2>/dev/null; then
  echo "  FAIL: the prompt ($hung) is still up after the deadline" >&2; exit 1
fi
echo "  PASS: the unanswered prompt was ended and dismissed, and said so"
exit 0
