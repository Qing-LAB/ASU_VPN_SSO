#!/bin/bash
# Enter the scenario sandbox: an unprivileged user + mount namespace in which
# every binary a scenario could reach outside this repository is covered by a
# stand-in, and a guard refuses to run anything unless all of them are.
#
#   tests/sandbox/enter.sh sec.sh          # run one scenario
#   tests/sandbox/enter.sh /bin/bash       # look around by hand
#
# Isolation is structural, not careful: bind mounts inside a namespace leave
# the real filesystem untouched and cannot be forgotten on the way out. An
# earlier symlink-based arrangement let tests reach real binaries twice — once
# opening the real ASU sign-in browser. Do not go back to that.
set -euo pipefail
SB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SB/../.." && pwd)"

REAL_SSO="$(command -v openconnect-sso || true)"
if [ -z "$REAL_SSO" ]; then
    echo "openconnect-sso is not on PATH; it must exist for the fake to cover it" >&2
    exit 91
fi
REAL_SSO="$(realpath "$REAL_SSO")"

# Stage what the scenarios run (asuvpn-selftest comes along for hand
# sessions, not for any scenario). app/ is refreshed from the repository
# every time so a scenario can never test stale code. rbin/ holds runtime copies of
# the fakes because the fake openconnect-sso needs a shebang naming an
# absolute path on *this* machine: the tray reads that shebang to find the
# venv python, so it has to point at the stand-in interpreter.
rm -rf "$SB/app" "$SB/rbin"
mkdir -p "$SB/app" "$SB/rbin" "$SB/home"
for f in asuvpn-tray asuvpn-helper asuvpn-notify asuvpn-selftest; do
    install -m 0755 "$REPO/$f" "$SB/app/$f"
done
install -m 0644 "$REPO/asuvpn_contract.py" "$SB/app/asuvpn_contract.py"
for f in openconnect pkexec sso-python vpnc-script resolvectl; do
    install -m 0755 "$SB/bin/$f" "$SB/rbin/$f"
done
{ printf '#!%s\n' "$SB/rbin/sso-python"; tail -n +2 "$SB/bin/openconnect-sso"; } \
    > "$SB/rbin/openconnect-sso"
chmod 0755 "$SB/rbin/openconnect-sso"

# Scenarios that drive the tray need an X display; /run is a fresh tmpfs
# inside the namespace, so the session's X cookie must be copied out of it
# beforehand.
if [ -n "${XAUTHORITY:-}" ] && [ -r "$XAUTHORITY" ]; then
    install -m 0600 "$XAUTHORITY" "$SB/xauth"
else
    # Nothing to copy: remove any stale cookie too, or display scenarios
    # would keep authenticating with a credential from a previous session.
    rm -f "$SB/xauth"
fi

# A bare scenario name is resolved against this directory.
if [ "$#" -ge 1 ] && [ -x "$SB/$1" ]; then
    first="$SB/$1"; shift; set -- "$first" "$@"
fi

# --map-root-user makes the helper's privileged paths live (euid 0 inside);
# --map-auto maps this user's /etc/subgid block as well, so gids other than
# our own exist inside. That second mapping is what lets sec.sh stage a file
# owned by a *second* group and watch the real helper refuse it — a predicate
# truth table cannot prove that end to end; only a second principal can.
# 3<&0 duplicates the caller's real stdin before the heredoc replaces fd 0,
# so the inner exec can hand it back to the command it runs.
exec unshare -Urm --map-root-user --map-auto /bin/bash -s -- \
    "$SB" "$REAL_SSO" "$@" 3<&0 <<'INNER'
set -euo pipefail
SB="$1"; REAL_SSO="$2"; shift 2
export PATH="$SB/rbin:$PATH"
mount -t tmpfs tmpfs /run
mkdir -p /run/user/1000
chmod 700 /run/user/1000  # dbus refuses a runtime dir other uids could write
mount --bind "$SB/rbin/openconnect" /usr/sbin/openconnect
[ -e /usr/bin/openconnect ] && mount --bind "$SB/rbin/openconnect" /usr/bin/openconnect
mount --bind "$SB/rbin/pkexec" /usr/bin/pkexec
mount --bind "$SB/rbin/openconnect-sso" "$REAL_SSO"
mount --bind "$SB/rbin/vpnc-script" /usr/share/vpnc-scripts/vpnc-script
# resolvectl is reached by absolute path (asuvpn_contract.RESOLVECTL_PATHS),
# and the tmpfs on /run above hides the bus a real one needs -- so without a
# stand-in the DNS source silently answers "cannot tell" in every scenario.
[ -e /usr/bin/resolvectl ] && mount --bind "$SB/rbin/resolvectl" /usr/bin/resolvectl
fail=0
check(){ grep -qa 'SANDBOX-MARKER' "$1" 2>/dev/null || { echo "GUARD FAIL: $2" >&2; fail=1; }; }
check /usr/sbin/openconnect openconnect
[ ! -e /usr/bin/openconnect ] || check /usr/bin/openconnect "openconnect (/usr/bin)"
check /usr/bin/pkexec pkexec
check "$REAL_SSO" openconnect-sso
check /usr/share/vpnc-scripts/vpnc-script vpnc-script
[ ! -e /usr/bin/resolvectl ] || check /usr/bin/resolvectl resolvectl
for b in openconnect openconnect-sso pkexec; do
    p="$(command -v "$b" || true)"
    case "$p" in "$SB/rbin/$b") ;; *) echo "GUARD FAIL: PATH resolves $b to ${p:-nothing}" >&2; fail=1;; esac
done
[ "$fail" -eq 0 ] || { echo "ABORTING: isolation incomplete" >&2; exit 90; }
echo "guard: every binary a scenario could reach is a stand-in" >&2
# A private session bus for the fake world. The tmpfs over /run hides the
# user's real bus, leaving GTK's autolaunch fallback — a detour that is at
# best slow and at worst reached the real session bus through the abstract
# namespace, which is how scenario runs used to raise notifications on the
# real desktop. A throwaway bus makes startup deterministic and keeps the
# fake world's notifications inside it. The system binary by absolute path:
# a conda install shadows it on PATH with one that may pull the wrong
# dbus-daemon.
runner=()
if [ -x /usr/bin/dbus-run-session ]; then
    runner=(/usr/bin/dbus-run-session --)
elif command -v dbus-run-session >/dev/null 2>&1; then
    runner=("$(command -v dbus-run-session)" --)
fi
# The heredoc that carried this script consumed fd 0 and is at EOF; hand the
# caller's real stdin (saved as fd 3 outside) to the command. Without this,
# `enter.sh /bin/bash` printed the guard line and exited instantly — dropping
# the user back into their REAL shell right after saying all is a stand-in.
exec "${runner[@]}" "$@" 0<&3 3<&-
INNER
