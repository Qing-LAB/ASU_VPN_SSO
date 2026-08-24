#!/bin/bash
# Shared plumbing for the scenarios that drive the real tray. Sourced, not
# executed. Three jobs, each of which every display scenario used to restate:
# the sandbox guard, a freshly staged HOME, and a tray start that is PROVEN
# up before any verb is sent — the old readiness loop timed out silently, so
# a scenario could "pass" against an applet that never started at all.

sandbox_guard() {
    grep -qa SANDBOX-MARKER /usr/bin/pkexec 2>/dev/null && return 0
    echo "not inside the sandbox; run: tests/sandbox/enter.sh ${0##*/}" >&2
    exit 90
}

fresh_home() {
    rm -rf "${SB:?}/home"
    mkdir -p "$SB/home/.cache" "$SB/home/.config/asuvpn"
    export HOME="$SB/home" XDG_CACHE_HOME="$SB/home/.cache" \
           XDG_CONFIG_HOME="$SB/home/.config"
    export XDG_RUNTIME_DIR=/run/user/1000 GDK_BACKEND=x11 DISPLAY=:0 \
           XAUTHORITY="$SB/xauth"
    unset WAYLAND_DISPLAY
    chmod 700 /run/user/1000 2>/dev/null
    # shellcheck disable=SC2034  # read by the sourcing scenario
    LOG="$SB/home/.cache/asuvpn/session.log"
}

start_tray() {
    "$A" --foreground tray >"$SB/tray.err" 2>&1 &
    # shellcheck disable=SC2034  # the tray's pid, waited on by the scenario
    T=$!
    # "Answered" means any exit but 3: status exits 0 connected, 1 up-but-
    # disconnected — the state right after start — and 3 not running. The
    # old loop tested plain success, so it NEVER saw a freshly started tray
    # as up; it burned its window silently every run and the scenarios' long
    # sleeps hid that. 30s is generous — with a session bus present (enter.sh
    # provides one) the applet answers in about a second.
    for _ in $(seq 300); do
        "$A" status >/dev/null 2>&1
        [ $? -ne 3 ] && return 0
        sleep 0.1
    done
    echo "  FAIL: the tray never answered on its socket; its stderr:" >&2
    sed 's/^/    /' "$SB/tray.err" >&2
    exit 1
}

# Wait for `asuvpn status` to contain $1, up to $2 seconds. Polling beats a
# fixed sleep: it passes as soon as the state arrives and fails with the last
# status in hand instead of asserting against a race.
await_status() { # substring, deadline-seconds, label
    _deadline=$((SECONDS + $2))
    _last=""
    while [ "$SECONDS" -lt "$_deadline" ]; do
        _last="$("$A" status 2>/dev/null)"
        case "$_last" in *"$1"*) echo "  ok: $3 ($_last)"; return 0 ;; esac
        sleep 0.5
    done
    echo "  FAIL: $3 — last status: $_last" >&2
    exit 1
}

must_contain() { # label, haystack, needle
    case "$2" in
        *"$3"*) echo "  ok: $1" ;;
        *) echo "  FAIL: $1 — wanted '$3' in: $2" >&2; exit 1 ;;
    esac
}
