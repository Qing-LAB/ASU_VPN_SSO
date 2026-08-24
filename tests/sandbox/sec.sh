#!/bin/bash
# The helper's permission refusals, exercised on the real helper rather than
# proved about the predicate. Cases (b) and (b2) stage a file owned by a
# second group — possible only because enter.sh maps this user's /etc/subgid
# block; an earlier version chgrp'd into the void with the error silenced and
# ran the helper against an unchanged file, a test that passed while testing
# nothing. Every case asserts: a refusal must happen, must say why, and must
# happen before anything executed — and the normal contrast case must NOT be
# refused, or the refusals above prove nothing.
SB="$(cd "$(dirname "$0")" && pwd)"
grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null || { echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2; exit 90; }
export HOME="$SB/home"; mkdir -p "$SB/home"
A="$SB/app"
run_raw() { printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x \
        --fingerprint pin-sha256:x "$@" 2>&1; }
# The framed pre-spawn line; its absence is what "nothing executed" means.
SPAWNED='[helper] NOTE running as uid'
refused() { # label, rc, output — assert a refusal that ran nothing
  if [ "$2" -eq 0 ] || ! printf '%s' "$3" | grep -q 'refusing' \
      || printf '%s' "$3" | grep -qF "$SPAWNED"; then
    echo "      FAIL: $1 was not refused before execution (exit=$2)" >&2
    exit 1
  fi
  echo "      refused (exit=$2) without executing anything"
}
echo "  euid inside the namespace: $(id -u)  (the privileged paths are live)"
echo
echo "--- a) contract world-writable ---"
chmod 0666 "$A/asuvpn_contract.py"
out="$(run_raw)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chmod 0644 "$A/asuvpn_contract.py"
refused "a world-writable contract" "$rc" "$out"
echo "--- b) contract group-shared (gid != uid) ---"
chgrp 65534 "$A/asuvpn_contract.py" \
    || { echo "      FAIL: cannot stage a second group; is enter.sh mapping subgids?"; exit 1; }
chmod 0664 "$A/asuvpn_contract.py"
out="$(run_raw)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chgrp 0 "$A/asuvpn_contract.py"; chmod 0644 "$A/asuvpn_contract.py"
refused "a group-shared contract" "$rc" "$out"
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
chmod 0777 "$A"
out="$(run_raw)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chmod 0755 "$A"
refused "a world-writable directory" "$rc" "$out"
echo "--- d) contract replaced by a symlink to a writable file ---"
cp "$A/asuvpn_contract.py" "$SB/evil_contract.py"; chmod 0666 "$SB/evil_contract.py"
mv "$A/asuvpn_contract.py" "$A/real_contract.py"
ln -s "$SB/evil_contract.py" "$A/asuvpn_contract.py"
out="$(run_raw)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
rm -f "$A/asuvpn_contract.py"; mv "$A/real_contract.py" "$A/asuvpn_contract.py"
rm -f "$SB/evil_contract.py"  # a 0666 file has no business outliving its case
refused "a symlink to a writable contract" "$rc" "$out"
echo "--- f) normal, for contrast ---"
out="$(run_raw --dpd=0)"; rc=$?
printf '%s\n' "$out" | grep -F "$SPAWNED" | head -1 | cut -c1-96 | sed 's/^/      /'
if ! printf '%s' "$out" | grep -qF "$SPAWNED"; then
    echo "      FAIL: the normal case never reached the spawn (exit=$rc), so" >&2
    echo "      the refusals above prove nothing" >&2
    exit 1
fi
echo
echo "--- g) the event socket directory, as root ---"
# shellcheck disable=SC2012  # ls output is displayed for the reader, not parsed
ls -ld /run/asuvpn 2>/dev/null | sed 's/^/      /' || echo "      (none left behind)"
echo "  PASS: every refusal refused before anything ran; the normal case ran"
exit 0
