#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"
grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null || { echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2; exit 90; }
rm -rf "${SB:?}/home"; mkdir -p "$SB/home/.cache" "$SB/home/.config/asuvpn"
export HOME="$SB/home" XDG_CACHE_HOME="$SB/home/.cache" XDG_CONFIG_HOME="$SB/home/.config"
export XDG_RUNTIME_DIR=/run/user/1000 GDK_BACKEND=x11 DISPLAY=:0 XAUTHORITY="$SB/xauth"
unset WAYLAND_DISPLAY; chmod 700 /run/user/1000 2>/dev/null
A="$SB/app/asuvpn-tray"
"$A" --foreground tray >"$SB/tray.err" 2>&1 & T=$!
for _ in $(seq 80); do "$A" status >/dev/null 2>&1 && break; sleep 0.1; done
"$A" connect >/dev/null 2>&1; sleep 2
echo "  t+2s   $("$A" status)"
sleep 22; echo "  t+24s  $("$A" status)"
sleep 22; echo "  t+46s  $("$A" status)"
sleep 22; echo "  t+68s  $("$A" status)"
"$A" quit >/dev/null 2>&1; wait $T 2>/dev/null
echo "  --- log ---"
grep -E 'force-dpd|not usable|re-establish|SIGUSR2|tunnel check|healthy again|STATE' \
  "$SB/home/.cache/asuvpn/session.log" 2>/dev/null | sed 's/^/    /'
exit 0
