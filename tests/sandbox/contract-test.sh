#!/bin/bash
SB="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${SB:?}/home"; mkdir -p "$SB/home/.cache" "$SB/home/.config/asuvpn"
export HOME="$SB/home" XDG_CACHE_HOME="$SB/home/.cache" XDG_CONFIG_HOME="$SB/home/.config"
export XDG_RUNTIME_DIR=/run/user/1000 GDK_BACKEND=x11 DISPLAY=:0 XAUTHORITY="$SB/xauth"
unset WAYLAND_DISPLAY; chmod 700 /run/user/1000 2>/dev/null
export FAKE_TUNDEV=lo FAKE_DNS=127.0.0.1
A="$SB/app/asuvpn-tray"
# the config file is the driving mechanism: generate it, then change it
"$A" --write-config sslvpn.asu.edu > "$SB/home/.config/asuvpn/asuvpn.conf"
sed -i 's/^dpd = 30/dpd = 45/; s/^health-interval = 20/health-interval = 5/' \
    "$SB/home/.config/asuvpn/asuvpn.conf"
echo "  config says: $(grep -E '^(dpd|health-interval|probe) =' "$SB/home/.config/asuvpn/asuvpn.conf" | tr '\n' ' ')"
"$A" --foreground tray >"$SB/tray.err" 2>&1 & T=$!
for _ in $(seq 80); do "$A" status >/dev/null 2>&1 && break; sleep 0.1; done
"$A" connect >/dev/null 2>&1; sleep 3; echo "  connect    : $("$A" status)"
echo "  autoreconnect via CLI: $("$A" autoreconnect on) then $("$A" autoreconnect)"
sleep 20;                       echo "  after 20s  : $("$A" status)"
"$A" disconnect >/dev/null 2>&1; echo "  disconnect : $("$A" status)"
"$A" quit >/dev/null 2>&1; wait $T 2>/dev/null
echo "  --- did the config drive the helper? ---"
grep -oE '\-\-force-dpd [0-9]+' "$SB/home/.cache/asuvpn/session.log" | head -1 | sed 's/^/    /'
grep -E 'DEVICE|STATE|check ' "$SB/home/.cache/asuvpn/session.log" | head -4 | sed 's/^/    /'
echo "  --- autoreconnect landed in the file? ---"
grep -E '^autoreconnect' "$SB/home/.config/asuvpn/asuvpn.conf" | sed 's/^/    /'
exit 0
