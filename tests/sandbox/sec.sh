#!/bin/bash
# The helper's permission refusals, exercised on the real helper rather than
# proved about the predicate. Cases (b) and (b2) stage a file owned by a
# second group — possible only because enter.sh maps this user's /etc/subgid
# block; an earlier version chgrp'd into the void with the error silenced and
# ran the helper against an unchanged file, a test that passed while testing
# nothing. Those two cases assert and exit 1 on the wrong outcome; the rest
# print what happened for the reader.
SB="$(cd "$(dirname "$0")" && pwd)"
grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null || { echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2; exit 90; }
export HOME="$SB/home"; mkdir -p "$SB/home"
A="$SB/app"
run_raw() { printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x \
        --fingerprint pin-sha256:x "$@" 2>&1; }
run() { run_raw "$@" | head -2; }
echo "  euid inside the namespace: $(id -u)  (the privileged paths are live)"
echo
echo "--- a) contract world-writable ---"
chmod 0666 "$A/asuvpn_contract.py"; run | sed 's/^/      /'; chmod 0644 "$A/asuvpn_contract.py"
echo "--- b) contract group-shared (gid != uid) ---"
chgrp 65534 "$A/asuvpn_contract.py" \
    || { echo "      FAIL: cannot stage a second group; is enter.sh mapping subgids?"; exit 1; }
chmod 0664 "$A/asuvpn_contract.py"
out="$(run_raw)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chgrp 0 "$A/asuvpn_contract.py"; chmod 0644 "$A/asuvpn_contract.py"
if [ "$rc" -eq 0 ] || printf '%s' "$out" | grep -q "running as uid"; then
    echo "      FAIL: a group-shared contract was not refused (exit=$rc)"; exit 1
fi
echo "      refused (exit=$rc) without executing anything"
echo "--- b2) the helper itself group-shared ---"
chgrp 65534 "$A/asuvpn-helper" \
    || { echo "      FAIL: cannot stage a second group; is enter.sh mapping subgids?"; exit 1; }
chmod 0775 "$A/asuvpn-helper"
out="$(run_raw)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chgrp 0 "$A/asuvpn-helper"; chmod 0755 "$A/asuvpn-helper"
if [ "$rc" -ne 26 ]; then
    echo "      FAIL: expected the documented exit 26, got $rc"; exit 1
fi
echo "      refused with exit 26, the documented code"
echo "--- c) the directory world-writable ---"
chmod 0777 "$A"; run | sed 's/^/      /'; chmod 0755 "$A"
echo "--- d) contract replaced by a symlink to a writable file ---"
cp "$A/asuvpn_contract.py" "$SB/evil_contract.py"; chmod 0666 "$SB/evil_contract.py"
mv "$A/asuvpn_contract.py" "$A/real_contract.py"
ln -s "$SB/evil_contract.py" "$A/asuvpn_contract.py"
run | sed 's/^/      /'
rm -f "$A/asuvpn_contract.py"; mv "$A/real_contract.py" "$A/asuvpn_contract.py"
echo "--- f) normal, for contrast ---"
run --dpd=0 | grep -oE 'running as uid [0-9]+|force-dpd [0-9]+' | head -1 | sed 's/^/      /'
echo
echo "--- g) the event socket directory, as root ---"
# shellcheck disable=SC2012  # ls output is displayed for the reader, not parsed
ls -ld /run/asuvpn 2>/dev/null | sed 's/^/      /' || echo "      (none left behind)"
exit 0
