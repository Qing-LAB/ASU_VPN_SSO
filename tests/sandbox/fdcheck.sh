#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard
export HOME="$SB/home"
mkfifo "$SB/ctl" 2>/dev/null; exec 9<>"$SB/ctl"
printf 'FAKECOOKIE\n' >&9
"$SB/app/asuvpn-helper" --host https://x --fingerprint pin-sha256:x <"$SB/ctl" >/dev/null 2>&1 &
H=$!; sleep 1.5
OC=$(pgrep -P "$H" -f openconnect | head -1)
if [ -z "$OC" ]; then
  # Without a subject the comparison below reads an empty path and prints a
  # reassuring "distinct" verdict about nothing — a pass that proves nothing.
  echo "  FAIL: no openconnect child of the helper was found to inspect" >&2
  kill -9 "$H" 2>/dev/null; exec 9>&-; rm -f "$SB/ctl"; exit 1
fi
echo "  helper pid=$H  openconnect pid=$OC"
echo "  helper      fd0 -> $(readlink /proc/"$H"/fd/0)"
echo "  openconnect fd0 -> $(readlink /proc/"$OC"/fd/0)"
rc=0
if [ "$(readlink /proc/"$H"/fd/0)" = "$(readlink /proc/"$OC"/fd/0)" ]; then
  echo "  *** SHARED -- openconnect could inject control verbs ***"
  rc=1
else
  echo "  distinct: openconnect cannot reach the control channel"
fi
echo "  can openconnect write to its own fd0? $(grep -o 'flags:.*' /proc/"$OC"/fdinfo/0 2>/dev/null | head -1)"
kill -9 "$H" ${OC:+"$OC"} 2>/dev/null; exec 9>&-; rm -f "$SB/ctl"; exit $rc
