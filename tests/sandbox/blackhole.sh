#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${SB:?}/home"; mkdir -p "$SB/home/.cache" "$SB/home/.config/asuvpn"
export HOME="$SB/home" XDG_CACHE_HOME="$SB/home/.cache" XDG_CONFIG_HOME="$SB/home/.config"
export XDG_RUNTIME_DIR=/run/user/1000 GDK_BACKEND=x11 DISPLAY=:0 XAUTHORITY="$SB/xauth"
unset WAYLAND_DISPLAY; chmod 700 /run/user/1000 2>/dev/null
# device that is genuinely healthy, target that will never answer
export FAKE_TUNDEV=lo FAKE_DNS=198.51.100.1
echo sslvpn.asu.edu > "$SB/home/.config/asuvpn/server"
A="$SB/app/asuvpn-tray"
"$A" --foreground tray >"$SB/tray.err" 2>&1 & T=$!
for _ in $(seq 80); do "$A" status >/dev/null 2>&1 && break; sleep 0.1; done
"$A" connect >/dev/null 2>&1
for t in 30 45 45 45; do sleep $t; echo "  +$((SECONDS))s  $("$A" status)"; done
"$A" quit >/dev/null 2>&1; wait $T 2>/dev/null
echo "  --- log ---"
grep -E 'STATE|device check|probe|not usable|re-establish' "$SB/home/.cache/asuvpn/session.log" | sed 's/^/    /'
exit 0
