#!/bin/bash
# The teardown ladder's order, held to: SIGINT first with its full grace,
# SIGTERM only after, and no SIGKILL against a peer that yields to SIGTERM.
# Escalating early is the one thing guaranteed to stop vpnc-script putting
# the routes back, so the order is the safety property — and until this
# scenario, nothing could fail if it changed: the ordinary fake dies on the
# first signal, so every teardown looked the same whichever came first.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard
export HOME="$SB/home"
export FAKE_STUBBORN=1
echo "  a stand-in that ignores SIGINT; teardown must wait out the grace"
# The sleep holds the control pipe open while the stand-in boots: an instant
# EOF starts teardown before python has installed the signal handlers, and
# the SIGINT then kills the not-yet-stubborn process mid-startup.
began=$SECONDS
out=$( { printf 'COOKIE\n'; sleep 2; } | timeout 40 "$A/asuvpn-helper" \
      --host https://x --fingerprint pin-sha256:x 2>&1); rc=$?
elapsed=$(( SECONDS - began ))
printf '%s\n' "$out" | grep -E 'SIGINT|SIGTERM|SIGKILL|killing|exited' | sed 's/^/      /'
[ "$rc" -eq 0 ] || { echo "  FAIL: the helper exited $rc" >&2; exit 1; }
must_contain "SIGTERM was sent at all" "$out" "sending SIGTERM"
# The grace itself, which the line above does not prove and this scenario
# used to claim anyway: with the SIGINT grace shortened to 0 the whole run
# finished in 2s and still printed "followed after the grace". The floor is
# the helper's own first rung (15s) less the 2s the pipe is held open, and
# is a floor rather than a window so a loaded machine cannot fail it.
if [ "$elapsed" -lt 15 ]; then
  echo "  FAIL: the whole teardown took ${elapsed}s; the SIGINT grace alone" >&2
  echo "  is 15s, so it was not waited out" >&2; exit 1
fi
echo "  ok: SIGTERM followed a full grace (${elapsed}s elapsed)"
case "$out" in *SIGKILL*|*"killing it"*)
  echo "  FAIL: escalated to SIGKILL against a peer that yields to SIGTERM" >&2; exit 1;;
esac
must_contain "openconnect still exited cleanly" "$out" "openconnect exited with status 0"
# The order, not just the members: the first signal line must be SIGINT.
first=$(printf '%s\n' "$out" | grep -E 'sending SIG(INT|TERM)' | head -1)
case "$first" in *SIGINT*) echo "  ok: SIGINT precedes SIGTERM" ;;
  *) echo "  FAIL: the ladder did not start with SIGINT: $first" >&2; exit 1 ;;
esac
echo "  PASS: SIGINT, then SIGTERM, never SIGKILL — the ladder in order"
exit 0
