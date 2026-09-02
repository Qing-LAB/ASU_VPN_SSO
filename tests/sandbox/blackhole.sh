#!/bin/bash
# Healthy device, silent probe target: only the probe can see this break, so
# only the probe may promote. Expect a demotion blamed on the probe, exactly
# one nudge, and a badge that stays demoted however healthy the device looks.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
# device that is genuinely healthy, target that will never answer (RFC 5737)
export FAKE_TUNDEV=lo FAKE_DNS=198.51.100.1
# This scenario needs the documentation address to time out. On a network
# whose router answers or rejects it instead, the probe comes back
# inconclusive by design and no demotion can ever land — say that up front
# rather than failing 240 seconds later with no explanation.
if /usr/bin/python3 -c '
import socket, sys
try:
    socket.create_connection(("198.51.100.1", 53), timeout=3).close()
    sys.exit(1)          # answered: cannot stage a black hole here
except socket.timeout:
    sys.exit(0)          # silence: the black hole is real
except OSError:
    sys.exit(1)          # rejected: the probe would be inconclusive
'; then :; else
  echo "  FAIL: this network answers or rejects RFC 5737 space, so a black" >&2
  echo "  hole cannot be staged here; the probe verdicts it produces are" >&2
  echo "  inconclusive by design and this scenario cannot mean anything" >&2
  exit 1
fi
# Pinned off, not left to the default: this scenario is about the nudge-only
# path, and a default that permits the sign-in rung would change what it
# proves without changing a line of it.
"$A" autoreconnect off >/dev/null
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
