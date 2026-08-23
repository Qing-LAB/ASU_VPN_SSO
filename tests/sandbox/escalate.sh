#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${SB:?}/home"; mkdir -p "$SB/home/.cache" "$SB/home/.config/asuvpn"
export HOME="$SB/home" XDG_CACHE_HOME="$SB/home/.cache" XDG_CONFIG_HOME="$SB/home/.config"
export XDG_RUNTIME_DIR=/run/user/1000 GDK_BACKEND=x11 DISPLAY=:0 XAUTHORITY="$SB/xauth"
unset WAYLAND_DISPLAY; chmod 700 /run/user/1000 2>/dev/null
export FAKE_DEAF=1
echo sslvpn.asu.edu > "$SB/home/.config/asuvpn/server"
A="$SB/app/asuvpn-tray"
"$A" autoreconnect on >/dev/null
"$A" --foreground tray >"$SB/tray.err" 2>&1 & T=$!
for _ in $(seq 80); do "$A" status >/dev/null 2>&1 && break; sleep 0.1; done
"$A" connect >/dev/null 2>&1
for t in 25 25 25 25; do sleep $t; echo "  $(date +%M:%S)  $("$A" status)"; done
"$A" quit >/dev/null 2>&1; wait $T 2>/dev/null
echo "  --- what it did ---"
grep -E 'not usable|re-establish|SIGUSR2|signing in again|tunnel check|authenticating' \
  "$SB/home/.cache/asuvpn/session.log" 2>/dev/null | sed 's/^/    /'
exit 0
