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
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard
export HOME="$SB/home"
A="$SB/app"
# helper_run and SPAWNED come from lib.sh; the pre-spawn line's absence is
# what "nothing executed" means below.
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
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chmod 0644 "$A/asuvpn_contract.py"
refused "a world-writable contract" "$rc" "$out"
echo "--- b) contract group-shared (gid != uid) ---"
chgrp 65534 "$A/asuvpn_contract.py" \
    || { echo "      FAIL: cannot stage a second group; is enter.sh mapping subgids?"; exit 1; }
chmod 0664 "$A/asuvpn_contract.py"
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chgrp 0 "$A/asuvpn_contract.py"; chmod 0644 "$A/asuvpn_contract.py"
refused "a group-shared contract" "$rc" "$out"
echo "--- b2) the helper itself group-shared ---"
chgrp 65534 "$A/asuvpn-helper" \
    || { echo "      FAIL: cannot stage a second group; is enter.sh mapping subgids?"; exit 1; }
chmod 0775 "$A/asuvpn-helper"
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chgrp 0 "$A/asuvpn-helper"; chmod 0755 "$A/asuvpn-helper"
if [ "$rc" -ne 26 ]; then
    echo "      FAIL: expected the documented exit 26, got $rc"; exit 1
fi
echo "      refused with exit 26, the documented code"
echo "--- c) the directory world-writable ---"
chmod 0777 "$A"
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chmod 0755 "$A"
refused "a world-writable directory" "$rc" "$out"
echo "--- d) contract replaced by a symlink to a writable file ---"
cp "$A/asuvpn_contract.py" "$SB/evil_contract.py"; chmod 0666 "$SB/evil_contract.py"
mv "$A/asuvpn_contract.py" "$A/real_contract.py"
ln -s "$SB/evil_contract.py" "$A/asuvpn_contract.py"
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
rm -f "$A/asuvpn_contract.py"; mv "$A/real_contract.py" "$A/asuvpn_contract.py"
rm -f "$SB/evil_contract.py"  # a 0666 file has no business outliving its case
refused "a symlink to a writable contract" "$rc" "$out"
echo "--- e2) asuvpn-notify world-writable ---"
# The one file openconnect itself executes as root, via --script. It was
# the only member of the helper's refusal list no case ever staged —
# dropping it from that list passed every test while a writable notify
# would have run as root.
chmod 0666 "$A/asuvpn-notify"
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
chmod 0755 "$A/asuvpn-notify"
refused "a world-writable asuvpn-notify" "$rc" "$out"
echo "--- e3) contract owned by another uid, writable by nobody else ---"
# The mode bits say who may write a file *besides* its owner; they say nothing
# about who the owner is, and an owner rewrites their own file whenever they
# like. install.sh --link from a checkout somebody else owns is a documented
# way to arrive here.
#
# Staged with a payload, and that is the point of this case rather than a
# neater one: the ownership question used to be asked in main(), which runs
# long after _contract() has already executed the file as root at import. A
# case that only checked the exit code would have passed against that. The
# marker is what tells "refused" from "refused afterwards".
marker="$SB/e3-executed"
rm -f "$marker"
cp "$A/asuvpn_contract.py" "$A/real_contract.py"
{ printf 'import pathlib; pathlib.Path(%s).write_text("ran")\n' "\"$marker\"";
  cat "$A/real_contract.py"; } > "$A/asuvpn_contract.py"
chown 65534 "$A/asuvpn_contract.py" \
    || { echo "      FAIL: cannot stage a second uid; is enter.sh mapping subuids?"; exit 1; }
chmod 0644 "$A/asuvpn_contract.py"
out="$(helper_run)"; rc=$?
echo "$out" | head -2 | sed 's/^/      /'
rm -f "$A/asuvpn_contract.py"; mv "$A/real_contract.py" "$A/asuvpn_contract.py"
if [ -e "$marker" ]; then
    rm -f "$marker"
    echo "      FAIL: the foreign-owned contract RAN as root before being refused" >&2
    exit 1
fi
refused "a contract owned by another uid" "$rc" "$out"
echo "--- e4) the same, against asuvpn-notify, the other program root runs ---"
# The loader guard is duplicated in every program that loads the contract,
# because code cannot be shared before the mechanism that shares it is
# loaded. That duplication is irreducible, so the four copies drifting is a
# standing risk -- and they had: the ownership half was missing from all of
# them until today. asuvpn-notify is the second program that runs as root
# (openconnect executes it, not pkexec), and nothing exercised its copy.
rm -f "$marker"
cp "$A/asuvpn_contract.py" "$A/real_contract.py"
{ printf 'import pathlib; pathlib.Path(%s).write_text("ran")\n' "\"$marker\"";
  cat "$A/real_contract.py"; } > "$A/asuvpn_contract.py"
chown 65534 "$A/asuvpn_contract.py"; chmod 0644 "$A/asuvpn_contract.py"
out="$(env reason=pre-init TUNDEV=lo "$A/asuvpn-notify" 2>&1)"; rc=$?
printf '%s\n' "$out" | head -1 | sed 's/^/      /'
rm -f "$A/asuvpn_contract.py"; mv "$A/real_contract.py" "$A/asuvpn_contract.py"
if [ -e "$marker" ]; then
    rm -f "$marker"
    echo "      FAIL: asuvpn-notify RAN a foreign-owned contract as root" >&2
    exit 1
fi
if [ "$rc" -eq 0 ] || ! printf '%s' "$out" | grep -q 'refusing'; then
    echo "      FAIL: asuvpn-notify did not refuse it (exit=$rc)" >&2; exit 1
fi
echo "      refused (exit=$rc) without executing anything"
# There is no case (e): the dpd refusals that carried the letter moved to
# sec3.sh, and the letters after it are cross-referenced from sec2.sh and
# the design notes, so they keep their names; e2 fills the hole with the
# file the original lettering missed.
echo "--- f) normal, for contrast ---"
out="$(helper_run --dpd=0)"; rc=$?
printf '%s\n' "$out" | grep -F "$SPAWNED" | head -1 | cut -c1-96 | sed 's/^/      /'
if ! printf '%s' "$out" | grep -qF "$SPAWNED"; then
    echo "      FAIL: the normal case never reached the spawn (exit=$rc), so" >&2
    echo "      the refusals above prove nothing" >&2
    exit 1
fi
echo
echo "--- g) the event socket directory, as root: no session leftovers ---"
if [ -e /run/asuvpn ]; then
  # shellcheck disable=SC2012  # ls output is displayed for the reader, not parsed
  ls -ld /run/asuvpn | sed 's/^/      /'
else
  echo "      (never created)"
fi
# Asserted, not just shown: the clean run in (f) opened a session channel
# under /run/asuvpn, and its teardown must have removed it. This case used
# to print whatever was there and could not fail.
# The precondition, asserted rather than assumed: an empty find is also what
# a directory that was never created looks like, so with event_channel()
# stubbed out to fail this case passed while reporting "(never created)".
if [ ! -d /run/asuvpn ]; then
  echo "      FAIL: the clean run in (f) opened no event channel at all," >&2
  echo "      so this case has nothing to say about teardown" >&2; exit 1
fi
leftovers=$(find /run/asuvpn -mindepth 1 -maxdepth 1 2>/dev/null)
if [ -n "$leftovers" ]; then
  echo "      FAIL: session channels left behind in /run/asuvpn: $leftovers" >&2
  exit 1
fi
echo "      clean: every session removed its channel directory"
echo "  PASS: every refusal refused before anything ran; the normal case ran"
exit 0
