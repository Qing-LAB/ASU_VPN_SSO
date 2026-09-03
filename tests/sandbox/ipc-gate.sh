#!/bin/bash
# The control socket's uid gate, defeated on purpose. An abstract socket has
# no file permissions, so SO_PEERCRED is the only thing between another local
# user and this applet — connect (a polkit prompt on this desktop at will),
# disconnect (drop the tunnel), status (read the assigned address). A foreign
# uid must be refused and logged; the same raw poke from our own uid must be
# answered, or the refusal proves nothing. Staging a real second uid is
# possible here because enter.sh maps this user's /etc/subuid block.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
command -v setpriv >/dev/null 2>&1 || {
  echo "  FAIL: setpriv is missing; a second uid cannot be staged" >&2; exit 1; }
start_tray
poke() { # run the raw client under "$@"; it targets the applet's own socket
  "$@" /usr/bin/python3 -c '
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("\0asuvpn-tray-0")   # the applet is uid 0 in this namespace
try:
    s.sendall(b"status")
    s.shutdown(socket.SHUT_WR)
    data = s.recv(256)
except OSError:
    # A refusal closes the connection with our bytes unread, which is a RST.
    # Which call trips over it -- sendall, shutdown or recv -- is a race with
    # how quickly the applet accepts and closes, and on a loaded machine it is
    # usually the first. Guarding only recv made this scenario fail with an
    # empty string and a BrokenPipeError traceback *because the gate worked*.
    # All three outcomes mean the one thing being asserted: no reply.
    data = b""
print(data.decode() or "<no reply>", end="")
'
}
ours=$(poke env)
must_contain "our own uid is answered (the gate is not just closed)" \
  "$ours" "disconnected"
foreign=$(poke setpriv --reuid 65534 --regid 65534 --clear-groups)
[ "$foreign" = "<no reply>" ] || {
  echo "  FAIL: a foreign uid got an answer: '$foreign'" >&2; exit 1; }
echo "  ok: uid 65534 got no answer"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
must_contain "the refusal was logged with the peer's uid" \
  "$(cat "$LOG")" "refused a control connection from uid 65534"
echo "  PASS: a foreign uid is refused and logged; our own is answered"
exit 0
