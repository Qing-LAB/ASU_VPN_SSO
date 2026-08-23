#!/bin/bash
# Positive controls for sec.sh: prove the staging mechanics themselves work,
# so a refusal there means the helper refused and not that the stage fell
# over. Then the dpd edge cases, watched at the level of what openconnect is
# actually handed.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"
export HOME="$SB/home"
echo "--- (b) staging control: does chgrp to a second group actually take? ---"
chgrp 65534 "$A/asuvpn_contract.py" 2>&1 | sed 's/^/      chgrp: /'
stat -c '      after chgrp: uid=%u gid=%g mode=%a' "$A/asuvpn_contract.py"
chgrp 0 "$A/asuvpn_contract.py" 2>/dev/null; chmod 0644 "$A/asuvpn_contract.py"
echo "      -> gid 65534 is real here: enter.sh maps this user's /etc/subgid"
echo "         block, which is what lets sec.sh (b) run the refusal end to end."
echo
echo "--- (e) what a negative dpd actually does ---"
printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x \
  --fingerprint pin-sha256:x --dpd=-5 2>&1 | grep -E 'force-dpd|NOTE forcing|running as uid' | head -2 | sed 's/^/      /'
echo
echo "--- (e2) and what openconnect is handed ---"
printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x \
  --fingerprint pin-sha256:x --dpd=-5 2>&1 | grep -oE '\-\-force-dpd [-0-9]+' | head -1 | sed 's/^/      /' || echo "      --force-dpd not passed"
exit 0
