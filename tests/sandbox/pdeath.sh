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
"$A/asuvpn-helper" --host https://x --fingerprint pin-sha256:x \
    <"$SB/ctl" >/dev/null 2>&1 &
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
for _ in $(seq 100); do
    kill -0 "$OC" 2>/dev/null || { survived=0; break; }
    survived=1; sleep 0.1
done
exec 9>&-; rm -f "$SB/ctl"
if [ "$survived" -ne 0 ]; then
  echo "  FAIL: openconnect outlived its dead helper — as root, unreachable" >&2
  echo "  --- the survivor, for the record ---" >&2
  tr '\0' ' ' < "/proc/$OC/cmdline" >&2; echo >&2
  grep -E '^(Name|PPid|SigCgt|SigIgn|SigBlk|Uid)' "/proc/$OC/status" \
    | sed 's/^/    /' >&2
  kill -9 "$OC" 2>/dev/null
  exit 1
fi
echo "  PASS: the helper's death took openconnect down with it"
exit 0
