#!/usr/bin/env bash
# One-shot setup for the ASU VPN tray applet on a fresh Ubuntu system.
# Safe to re-run; every step is skipped if it is already satisfied.
#
#   ./bootstrap.sh                          # install everything, then register
#   ./bootstrap.sh --server vpn.other.edu   # a different endpoint
#   ./bootstrap.sh --yes                    # never prompt (adds the PPA silently)
#   ./bootstrap.sh --no-deps                # only install the app, skip packages
#   ./bootstrap.sh --link                   # run from this checkout, do not copy
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="sslvpn.asu.edu"
INSTALL_DEPS=1
ASSUME_YES=0
INSTALL_ARGS=()
NEEDS_RELOGIN=0

# openconnect-sso needs Python 3.12: it pins lxml <5 and PyQt6-WebEngine <7,
# and neither has wheels for 3.13+. Ubuntu 26.04 ships only 3.14, so 3.12 comes
# from deadsnakes. The applet itself runs on the system python3, not this one.
PY=3.12
PYBIN="/usr/bin/python$PY"
DEADSNAKES_PPA="ppa:deadsnakes/ppa"

# The [full] extra pulls in keyring support. setuptools must stay below 71:
# openconnect-sso still imports pkg_resources, which 71 dropped.
SSO_SPEC='openconnect-sso[full]'
SETUPTOOLS_PIN='setuptools<71'

# What the applet itself imports, from the *system* python3.
APT_RUNTIME=(python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 openconnect pipx)
# lxml 4.x compiles from source on 3.12, which needs a toolchain and headers.
APT_BUILD=(build-essential libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev pkg-config)
# Shared libraries Qt6 WebEngine dlopens for the sign-in browser window.
APT_QT=(libnss3 libxcomposite1 libxdamage1 libxrandr2 libxkbcommon-x11-0 libxcb-cursor0
        libgl1 libegl1 libxtst6 libdbus-1-3 fontconfig)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || { warn "not a terminal; re-run with --yes to accept: $1"; return 1; }
  read -r -p "$1 [y/N] " reply
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="${2:?--server needs a value}"; shift 2 ;;
    --server=*) SERVER="${1#*=}"; shift ;;
    --no-deps) INSTALL_DEPS=0; shift ;;
    --link) INSTALL_ARGS+=(--link); shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -f "$SRC_DIR/asuvpn-tray" ] || die "run this from a checkout of the repository"

# --------------------------------------------------------------- apt helpers

apt_known()   { apt-cache show "$1" >/dev/null 2>&1; }
apt_present() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = "installed" ]; }

# Some package names differ across releases; take the first one this one has.
apt_first_available() {
  local pkg
  for pkg in "$@"; do
    if apt_known "$pkg"; then printf '%s\n' "$pkg"; return 0; fi
  done
  return 1
}

APT_UPDATED=0
apt_refresh() { [ "$APT_UPDATED" -eq 1 ] || { sudo apt-get update -qq; APT_UPDATED=1; }; }

apt_install_missing() {
  local pkg missing=()
  for pkg in "$@"; do
    [ -n "$pkg" ] && ! apt_present "$pkg" && missing+=("$pkg")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  say "installing: ${missing[*]}"
  apt_refresh
  sudo apt-get install -y "${missing[@]}"
}

# ------------------------------------------------------------------ python312

ensure_python() {
  if [ -x "$PYBIN" ]; then
    say "python$PY present ($("$PYBIN" -V 2>&1))"
    return
  fi
  if ! apt_known "python$PY"; then
    say "python$PY is not in the archive; it comes from deadsnakes"
    confirm "Add $DEADSNAKES_PPA?" ||
      die "python$PY is required. Add $DEADSNAKES_PPA yourself, or install python$PY another way."
    apt_install_missing software-properties-common
    sudo add-apt-repository -y "$DEADSNAKES_PPA"
    APT_UPDATED=0
    apt_refresh
  fi
  apt_install_missing "python$PY" "python$PY-venv" "python$PY-dev"
  [ -x "$PYBIN" ] || die "python$PY still missing after installation"
}

# ------------------------------------------------------------- openconnect-sso

install_openconnect_sso() {
  local sso
  command -v pipx >/dev/null || die "pipx is missing and could not be installed"
  sso="$(command -v openconnect-sso || true)"
  [ -n "$sso" ] || { [ -x "$HOME/.local/bin/openconnect-sso" ] && sso="$HOME/.local/bin/openconnect-sso"; }

  if [ -n "$sso" ]; then
    say "openconnect-sso already installed ($sso)"
  else
    say "installing $SSO_SPEC on python$PY (compiles lxml, so give it a few minutes)"
    pipx install --python "$PYBIN" "$SSO_SPEC"
    # Re-resolve: $sso was empty precisely because it was not installed yet, and
    # the verification below needs the console script to read its shebang from.
    # Without this the check is skipped on a *fresh* install — the one case it
    # matters most for.
    sso="$(command -v openconnect-sso || true)"
    [ -n "$sso" ] || { [ -x "$HOME/.local/bin/openconnect-sso" ] && sso="$HOME/.local/bin/openconnect-sso"; }
  fi

  # Always, never only on a fresh install: an earlier run that died between the
  # install and this pin leaves openconnect-sso needing a pkg_resources that a
  # current setuptools no longer ships. (Measured on this machine: setuptools
  # 78.1.1 still has pkg_resources, 83.0.0 does not. <71 is a known-good pin
  # rather than the exact boundary -- it is the bound that has been made to
  # work, so it is left alone.)
  #
  # --force is load-bearing, and this comment used to claim the opposite ("pipx
  # inject is idempotent, so re-running is free"). It is not idempotent, it is
  # inert: pipx's skip test is `venv.has_package("setuptools")`, which only asks
  # whether *a* setuptools is present — and one always is. So without --force
  # pipx prints "already seems to be injected", installs nothing, and still
  # returns 0. The pin silently never applied, set -e saw success, and the
  # >/dev/null below hid even that notice.
  #
  # The `pipx list` guard is a separate matter: an openconnect-sso installed
  # with `pip install --user` lands in the same ~/.local/bin and satisfies the
  # check above, and `pipx inject` then exits 1 and killed the whole bootstrap
  # under set -e, before the app was ever installed.
  if pipx list --short 2>/dev/null | grep -q "^openconnect-sso "; then
    say "pinning $SETUPTOOLS_PIN inside its venv"
    pipx inject openconnect-sso "$SETUPTOOLS_PIN" --force >/dev/null
    verify_sso_venv "$sso"
  else
    warn "openconnect-sso is not managed by pipx; make sure its environment has $SETUPTOOLS_PIN"
  fi
  pipx ensurepath >/dev/null 2>&1 || true
}

# Check the outcome, not the exit status. The whole reason the pin needs --force
# is that pipx reported success while doing nothing, so taking a second
# command's word for it would repeat the mistake exactly. What actually matters
# is whether openconnect-sso can still import pkg_resources, so ask that.
#
# The interpreter is read from the console script's shebang rather than guessed
# from PIPX_HOME — the same way the applet finds it.
verify_sso_venv() {
  local sso="${1:-}" py version
  [ -n "$sso" ] && [ -r "$sso" ] || return 0
  py="$(head -1 "$sso" | sed 's|^#!||' | awk '{print $1}')"
  [ -n "$py" ] && [ -x "$py" ] || return 0
  version="$("$py" -c 'import importlib.metadata as m; print(m.version("setuptools"))' \
             2>/dev/null || echo unknown)"
  if "$py" -c 'import pkg_resources' >/dev/null 2>&1; then
    say "openconnect-sso venv OK (setuptools $version, pkg_resources imports)"
  else
    warn "openconnect-sso cannot import pkg_resources (setuptools $version)."
    warn "Sign-in will fail. Try: pipx inject openconnect-sso '$SETUPTOOLS_PIN' --force"
  fi
}

# ------------------------------------------------------------------- checking

verify_bindings() {
  /usr/bin/python3 - <<'PY' || die "the system python3 is missing GTK bindings; re-run without --no-deps"
import sys
import gi
missing = []
for name, version in (("Gtk", "3.0"), ("AyatanaAppIndicator3", "0.1"), ("Notify", "0.7")):
    try:
        gi.require_version(name, version)
    except ValueError:
        missing.append(f"{name} {version}")
if missing:
    print("missing typelibs: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PY
  say "GTK and AppIndicator bindings OK"
}

enable_extension() {
  command -v gnome-extensions >/dev/null || return 0
  gnome-extensions list --enabled 2>/dev/null | grep -q ubuntu-appindicators && return 0
  # gnome-shell does not notice an extension installed moments ago, so this
  # lists nothing on the very run that installed it. Say so instead of
  # silently doing nothing and leaving the user without a tray icon.
  if ! gnome-extensions list 2>/dev/null | grep -q ubuntu-appindicators; then
    [ "$NEEDS_RELOGIN" -eq 1 ] &&
      warn "the AppIndicator extension was just installed; log out and back in, then re-run this script"
    return 0
  fi
  say "enabling the AppIndicator GNOME extension (a dconf setting)"
  gnome-extensions enable ubuntu-appindicators@ubuntu.com 2>/dev/null ||
    warn "could not enable it; turn on AppIndicator in the Extensions app"
}

# ----------------------------------------------------------------------- main

if [ "$INSTALL_DEPS" -eq 1 ]; then
  if ! command -v apt-get >/dev/null; then
    warn "not a Debian/Ubuntu system; install these yourself, then re-run with --no-deps:"
    printf '        %s\n' "${APT_RUNTIME[@]}" "${APT_BUILD[@]}" "${APT_QT[@]}" \
                          "polkit (pkexec)" "python$PY" >&2
    # Everything past here assumes $PYBIN exists, and pipx would fail with a far
    # less useful message than the list just printed.
    die "cannot continue automatically on this distribution"
  fi

  # Package metadata has to be current before anything is looked up: on a
  # machine whose lists are empty or stale, apt-cache reports real packages as
  # unknown and pkexec would be silently skipped.
  apt_refresh

  polkit_pkg=""
  command -v pkexec >/dev/null || polkit_pkg="$(apt_first_available pkexec policykit-1 || true)"
  alsa_pkg="$(apt_first_available libasound2t64 libasound2 || true)"

  tray_ext=""
  desktop="${XDG_CURRENT_DESKTOP:-}"   # both sides need the fallback under set -u
  if [ "$desktop" != "${desktop#*GNOME}" ] &&
     [ ! -d /usr/share/gnome-shell/extensions/ubuntu-appindicators@ubuntu.com ]; then
    tray_ext="$(apt_first_available gnome-shell-ubuntu-extensions gnome-shell-extension-appindicator || true)"
  fi

  apt_install_missing "${APT_RUNTIME[@]}" "${APT_BUILD[@]}" "${APT_QT[@]}" \
                      "$polkit_pkg" "$alsa_pkg" "$tray_ext"
  ensure_python
  install_openconnect_sso
  [ -n "$tray_ext" ] && NEEDS_RELOGIN=1
fi

verify_bindings
enable_extension

say "installing the app, the launcher and the asuvpn command"
bash "$SRC_DIR/install.sh" --server "$SERVER" "${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}"

cat <<EOF

$(say "done")

  Launch "ASU VPN" from the Activities overview, or from a terminal:

      asuvpn connect        # sign in and connect
      asuvpn status         # what state is it in
      asuvpn disconnect

      asuvpn selftest       # check this install against this machine

  One-time step, if you have never signed in with openconnect-sso on this
  machine: run it once in a terminal so it can save your password to the
  keyring. The applet refuses to guess a blank password.

      openconnect-sso --server $SERVER --authenticate=shell

EOF
