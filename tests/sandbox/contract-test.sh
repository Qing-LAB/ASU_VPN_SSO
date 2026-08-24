#!/bin/bash
# The config file is the driving mechanism, end to end: dpd = 45 written
# there must surface as --force-dpd 45 on openconnect's real command line,
# and the CLI autoreconnect toggle must land back in the file. Both asserted.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app/asuvpn-tray"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard; fresh_home
export FAKE_TUNDEV=lo FAKE_DNS=127.0.0.1
CONF="$SB/home/.config/asuvpn/asuvpn.conf"
# the config file is the driving mechanism: generate it, then change it
"$A" --write-config sslvpn.asu.edu > "$CONF"
sed -i 's/^dpd = 30/dpd = 45/; s/^health-interval = 20/health-interval = 5/' "$CONF"
echo "  config says: $(grep -E '^(dpd|health-interval|probe) =' "$CONF" | tr '\n' ' ')"
start_tray
"$A" connect >/dev/null 2>&1
await_status "Connected" 30 "the tunnel came up"
echo "  autoreconnect via CLI: $("$A" autoreconnect on) then $("$A" autoreconnect)"
sleep 20
echo "  after 20s  : $("$A" status)"
"$A" disconnect >/dev/null 2>&1
await_status "Disconnected" 60 "the tunnel tore down"
"$A" quit >/dev/null 2>&1; wait "$T" 2>/dev/null
echo "  --- did the config drive the helper? ---"
forced=$(grep -oE '\-\-force-dpd [0-9]+' "$LOG" | head -1)
echo "    ${forced:-no --force-dpd found}"
grep -E 'DEVICE|STATE|check ' "$LOG" | head -4 | sed 's/^/    /'
echo "  --- autoreconnect landed in the file? ---"
line=$(grep -E '^autoreconnect =' "$CONF")  # not autoreconnect-min-gap
echo "    $line"
[ "$forced" = "--force-dpd 45" ] || { echo "  FAIL: dpd = 45 never reached openconnect (got '$forced')" >&2; exit 1; }
[ "$line" = "autoreconnect = on" ] || { echo "  FAIL: the CLI toggle did not land in the file (got '$line')" >&2; exit 1; }
echo "  PASS: the file drove the helper, and the CLI drove the file"
exit 0
