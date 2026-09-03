#!/bin/bash
# The other direction of crash safety: the HELPER dies, not the tray. The
# control pipe cannot help — it is the helper that holds it — so the kernel
# itself must signal openconnect (the helper registers for that before the
# spawn). Without it, a helper killed by the OOM killer or a bug leaves a
# root openconnect running forever with nothing able to reach it. The
# stand-in exits through its signal handler, so its death within the window
# proves the kernel wiring end to end.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard
export HOME="$SB/home"
mkfifo "$SB/ctl" 2>/dev/null; exec 9<>"$SB/ctl"
printf 'FAKECOOKIE\n' >&9
# Kept, not discarded: the helper warns on stderr when it cannot arm the
# parent-death signal, and that warning is the first thing worth reading when
# this scenario fails. Throwing it away is why an earlier failure could only
# be answered with "poll longer".
HLOG="$SB/pdeath.helper.log"; : > "$HLOG"
# The stand-in's own log, on disk rather than down the pipe it shares with the
# helper. After the kill that pipe is dead, so this file is the only way to
# tell "the kernel never delivered the signal" from "it arrived and the
# shutdown stalled" — the two failures this scenario could not distinguish.
export FAKE_LOG="$SB/pdeath.standin.log"; : > "$FAKE_LOG"
"$A/asuvpn-helper" --host https://x --fingerprint pin-sha256:x \
    <"$SB/ctl" >"$HLOG" 2>&1 &
H=$!; sleep 1.5
OC=$(pgrep -P "$H" -f openconnect | head -1)
if [ -z "$OC" ]; then
  echo "  FAIL: no openconnect child of the helper was found to watch" >&2
  kill -9 "$H" 2>/dev/null; exec 9>&-; rm -f "$SB/ctl"; exit 1
fi
kill -0 "$OC" 2>/dev/null || { echo "  FAIL: the subject died before the test began" >&2; exit 1; }
echo "  helper pid=$H  openconnect pid=$OC — killing the helper with SIGKILL"
kill -9 "$H"
# The kernel delivers the death signal immediately; the stand-in's handler
# runs the disconnect script and exits. Poll rather than sleep-and-hope,
# and generously: a loaded machine's exit can straggle.
# `kill -0` was the wrong question. It succeeds for a *zombie* — a process
# that has already exited but has not been reaped — and a zombie is exactly
# what this scenario manufactures: it kills the parent, so when the child
# exits there is nobody left to reap it. Whether the process that adopts an
# orphan reaps it promptly differs between machines, which is why this passed
# here and failed on GitHub's runners for the same code. Ask the kernel what
# state the process is in instead of whether the pid is addressable.
still_running() {
    local state
    state=$(awk '/^State:/{print $2}' "/proc/$1/status" 2>/dev/null) || return 1
    [ -n "$state" ] && [ "$state" != "Z" ]
}
for _ in $(seq 100); do
    still_running "$OC" || { survived=0; break; }
    survived=1; sleep 0.1
done
exec 9>&-; rm -f "$SB/ctl"
if [ "$survived" -ne 0 ]; then
  echo "  FAIL: openconnect outlived its dead helper — as root, unreachable" >&2
  # The verdict, from evidence rather than from the absence of a corpse.
  if grep -q "signal .* received" "$FAKE_LOG" 2>/dev/null; then
    echo "  the death signal WAS delivered — the shutdown itself stalled" >&2
  else
    echo "  the death signal was NEVER delivered — the kernel did not act on" >&2
    echo "  PR_SET_PDEATHSIG, even though the helper armed it without error" >&2
  fi
  echo "  --- what the stand-in recorded (survives the dead pipe) ---" >&2
  sed 's/^/    /' "$FAKE_LOG" >&2 || true
  echo "  --- what the helper said on its way up ---" >&2
  sed 's/^/    /' "$HLOG" >&2 || true
  echo "  --- the survivor, for the record ---" >&2
  tr '\0' ' ' < "/proc/$OC/cmdline" >&2; echo >&2
  grep -E '^(Name|State|PPid|SigCgt|SigIgn|SigBlk|Uid)' "/proc/$OC/status" \
    | sed 's/^/    /' >&2
  kill -9 "$OC" 2>/dev/null
  exit 1
fi
echo "  PASS: the helper's death took openconnect down with it"
exit 0
