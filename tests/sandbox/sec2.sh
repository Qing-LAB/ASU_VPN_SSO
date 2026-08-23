#!/bin/bash
# Positive control for sec.sh: prove the staging mechanics themselves work, so
# a refusal there means the helper refused and not that the stage fell over.
# (The dpd edge cases that used to live here are sec3.sh's job, which shows
# them against the helper's documented exit codes.)
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"
export HOME="$SB/home"
echo "--- staging control: does chgrp to a second group actually take? ---"
chgrp 65534 "$A/asuvpn_contract.py" 2>&1 | sed 's/^/      chgrp: /'
stat -c '      after chgrp: uid=%u gid=%g mode=%a' "$A/asuvpn_contract.py"
chgrp 0 "$A/asuvpn_contract.py" 2>/dev/null; chmod 0644 "$A/asuvpn_contract.py"
echo "      -> gid 65534 is real here: enter.sh maps this user's /etc/subgid"
echo "         block, which is what lets sec.sh (b) run the refusal end to end."
exit 0
