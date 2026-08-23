#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"
export HOME="$SB/home"; mkdir -p "$SB/home"
mkfifo "$SB/ctl" 2>/dev/null; exec 9<>"$SB/ctl"
printf 'FAKECOOKIE\n' >&9
"$SB/app/asuvpn-helper" --host https://x --fingerprint pin-sha256:x <"$SB/ctl" >/dev/null 2>&1 &
H=$!; sleep 1.5
OC=$(pgrep -P "$H" -f openconnect | head -1)
echo "  helper pid=$H  openconnect pid=$OC"
echo "  helper      fd0 -> $(readlink /proc/"$H"/fd/0)"
echo "  openconnect fd0 -> $(readlink /proc/"$OC"/fd/0)"
if [ "$(readlink /proc/"$H"/fd/0)" = "$(readlink /proc/"$OC"/fd/0)" ]; then
  echo "  *** SHARED -- openconnect could inject control verbs ***"
else
  echo "  distinct: openconnect cannot reach the control channel"
fi
echo "  can openconnect write to its own fd0? $(grep -o 'flags:.*' /proc/"$OC"/fdinfo/0 2>/dev/null | head -1)"
kill -9 "$H" ${OC:+"$OC"} 2>/dev/null; exec 9>&-; rm -f "$SB/ctl"; exit 0
