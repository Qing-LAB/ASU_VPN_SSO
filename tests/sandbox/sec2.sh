#!/bin/bash
# Positive control for sec.sh: prove the staging mechanics themselves work, so
# a refusal there means the helper refused and not that the stage fell over.
# (The dpd edge cases that used to live here are sec3.sh's job, which shows
# them against the helper's documented exit codes.)
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"
grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null || { echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2; exit 90; }
export HOME="$SB/home"
echo "--- staging control: does chgrp to a second group actually take? ---"
chgrp 65534 "$A/asuvpn_contract.py" 2>&1 | sed 's/^/      chgrp: /'
gid="$(stat -c %g "$A/asuvpn_contract.py")"
stat -c '      after chgrp: uid=%u gid=%g mode=%a' "$A/asuvpn_contract.py"
chgrp 0 "$A/asuvpn_contract.py" 2>/dev/null; chmod 0644 "$A/asuvpn_contract.py"
if [ "$gid" = "65534" ]; then
  echo "      -> gid 65534 is real here: enter.sh maps this user's /etc/subgid"
  echo "         block, which is what lets sec.sh (b) run the refusal end to end."
  exit 0
fi
# A positive control that announces success unconditionally is not a control.
echo "      FAIL: the chgrp did not take (gid=$gid); the subgid mapping is" >&2
echo "      broken, and sec.sh (b) would be staging nothing" >&2
exit 1
