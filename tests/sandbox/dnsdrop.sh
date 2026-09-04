#!/bin/bash
# The third health source, end to end. A tunnel whose device is up, whose
# routes are installed and whose packets cross -- and whose resolver has been
# taken back off the link, which is what systemd-resolved rewriting its own
# stub file does. Every other check passes throughout; only this one sees it.
#
# No scenario had ever exercised it. The sandbox mounts a fresh tmpfs on /run,
# which hides the bus a real resolvectl needs, so the DNS source answered
# "cannot tell" on every tick of every scenario and the tray discarded it.
# tests/sandbox/bin/resolvectl is the stand-in that makes the question
# answerable; this drives it.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_TUNDEV=lo FAKE_DNS=192.0.2.53
export FAKE_LINK_DNS="$SB/home/link-dns"
export FAKE_RESOLVECTL_LOG="$SB/home/resolvectl.log"
# The resolver the tunnel pushed is on the link, so the source is healthy.
echo "192.0.2.53" > "$FAKE_LINK_DNS"
CONF="$SB/home/.config/asuvpn/asuvpn.conf"
"$A" --write-config sslvpn.asu.edu > "$CONF"
sed -i 's/^health-interval = .*/health-interval = 3/
        s/^health-strikes = .*/health-strikes = 2/
        s/^autoreconnect = .*/autoreconnect = off/
        s/^probe = .*/probe = off/' "$CONF"
echo "  config: $(grep -E '^(health-interval|health-strikes|probe) =' "$CONF" | tr '\n' ' ')"
start_tray
"$A" connect >/dev/null 2>&1
await_status "Connected" 40 "the tunnel came up with its resolver in force"
# Nothing else changes: the device is still up, the routes are still there,
# and the probe is off. Only the resolver leaves the link.
: > "$FAKE_LINK_DNS"
echo "  --- the resolver has been taken off the link ---"
await_status "DNS not configured" 60 "the DNS source alone demoted the tunnel"
# And back: the demoting source is the only one that can clear it.
echo "192.0.2.53" > "$FAKE_LINK_DNS"
await_status "Connected" 60 "the same source cleared its own demotion"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- what it did ---"
grep -hE 'dns check|not usable|carrying traffic again' "$SB/home/.cache/asuvpn/session.log" \
  2>/dev/null | sed 's/^/    /' | tail -6
# The stand-in was really asked, so the assertions above are about the applet
# and not about a question nobody put.
asked=$(grep -c '^dns lo$' "$FAKE_RESOLVECTL_LOG" 2>/dev/null || true)
[ "$asked" -ge 2 ] || {
  echo "  FAIL: resolvectl was asked $asked times; the source never ran" >&2
  exit 1
}
echo "  PASS: a resolver leaving the link demotes, and returning promotes"
exit 0
