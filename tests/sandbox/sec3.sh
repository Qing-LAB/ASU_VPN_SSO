#!/bin/bash
# The dpd contract, held to the helper's documented exit codes: a negative
# interval is refused with exit 27 — before anything is allocated, so no
# session channel is left behind in /run — 0 means "leave the server's choice
# alone" (no --force-dpd at all), and a normal value reaches openconnect's
# command line. All three assert. The world-writable-contract case that used
# to sit here was sec.sh case (a) said twice, and is gone.
SB="$(cd "$(dirname "$0")" && pwd)"; A="$SB/app"; export HOME="$SB/home"
# shellcheck source=tests/sandbox/lib.sh
. "$SB/lib.sh"; sandbox_guard
run(){ printf 'COOKIE\n' | timeout 8 "$A/asuvpn-helper" --host https://x --fingerprint pin-sha256:x "$@" 2>&1; }
# The framed pre-spawn line: present means the helper got as far as running
# openconnect, absent means it refused first. Both directions are asserted
# below — a case that expects a spawn must see it, or it proves nothing.
SPAWNED='[helper] NOTE running as uid'
echo "--- a negative interval is refused, with its documented exit code ---"
out=$(run --dpd=-5); rc=$?
echo "$out" | head -1 | sed 's/^/      /'; echo "      exit=$rc"
[ "$rc" -eq 27 ] || { echo "      FAIL: expected the documented exit 27, got $rc" >&2; exit 1; }
printf '%s' "$out" | grep -qF "$SPAWNED" && { echo "      FAIL: the refusal ran openconnect first" >&2; exit 1; }
# Refused before allocation: the helper must not have opened its event
# channel, so this fresh namespace's /run holds no session directory at all.
leftovers=$(find /run/asuvpn -mindepth 1 -maxdepth 1 2>/dev/null)
[ -z "$leftovers" ] || { echo "      FAIL: the refusal leaked a session channel: $leftovers" >&2; exit 1; }
echo "      refused before anything was allocated"
echo "--- 0 still means 'leave the server alone' ---"
out=$(run --dpd=0)
printf '%s' "$out" | grep -qF "$SPAWNED" || { echo "      FAIL: the helper never reached the spawn, so the count below proves nothing" >&2; exit 1; }
count=$(printf '%s' "$out" | grep -c 'force-dpd')
echo "      --force-dpd occurrences: $count"
[ "$count" -eq 0 ] || { echo "      FAIL: --dpd=0 still forced dead peer detection" >&2; exit 1; }
echo "--- a normal value still reaches openconnect ---"
forced=$(run --dpd=45 | grep -oE '\-\-force-dpd [0-9]+' | head -1)
echo "      ${forced:-no --force-dpd found}"
[ "$forced" = "--force-dpd 45" ] || { echo "      FAIL: expected --force-dpd 45, got '$forced'" >&2; exit 1; }
echo "  PASS: refused, omitted, and forwarded — each as documented"
exit 0
