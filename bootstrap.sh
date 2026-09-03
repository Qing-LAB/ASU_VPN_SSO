#!/usr/bin/env bash
# One-shot setup for the ASU VPN tray applet on a fresh Ubuntu system.
# Safe to re-run; anything already satisfied is skipped, except the setuptools
# pin and the PATH check, which run every time on purpose — their comments say
# why.
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

# The [full] extra pulls in keyring support. setuptools must stay pinned:
# openconnect-sso still imports pkg_resources, which current setuptools no
# longer ships. <71 is the known-good bound, not the exact boundary — the
# long comment inside install_openconnect_sso() has the measured versions.
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

# --------------------------------------------------- what is actually needed
#
# Asked as capabilities, not as package names, and asked before anything is
# installed. Two reasons:
#
#   1. A machine that already has these needs no packages, and therefore no
#      password. That is the common case on any GNOME desktop -- python3-gi and
#      polkit ship with the desktop -- so often the only gap is openconnect, and
#      sometimes there is no gap at all. "Is it there" is free to ask; "is this
#      Ubuntu" is not the same question and gets that case wrong.
#   2. The names differ per distribution and the capability does not. Naming the
#      capability lets a Fedora user be told `python3-gobject` instead of a
#      Debian name that means nothing to them.
#
# These are the same questions `asuvpn selftest` asks afterwards, so bootstrap
# and the self-check cannot disagree about whether an install is complete.

have_gtk_bindings() {
  /usr/bin/python3 - >/dev/null 2>&1 <<'GI_CHECK'
import gi
for name, version in (("Gtk", "3.0"), ("AyatanaAppIndicator3", "0.1"),
                      ("Notify", "0.7")):
    gi.require_version(name, version)
GI_CHECK
}
have_openconnect() { command -v openconnect >/dev/null 2>&1; }
have_pkexec()      { command -v pkexec >/dev/null 2>&1; }
have_sso() {
  command -v openconnect-sso >/dev/null 2>&1 ||
    [ -x "$HOME/.local/bin/openconnect-sso" ]
}

# What provides each capability, per package manager. Reporting only: nothing
# outside the apt path is installed automatically, because only the apt path is
# exercised in CI and a wrong package name run through sudo on someone's
# machine is a worse outcome than a list they paste themselves.
capability_packages() {          # $1 capability, $2 manager
  case "$1:$2" in
    gtk:apt)    echo "python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7" ;;
    gtk:dnf)    echo "python3-gobject gtk3 libappindicator-gtk3 libnotify" ;;
    gtk:pacman) echo "python-gobject gtk3 libappindicator-gtk3 libnotify" ;;
    gtk:zypper) echo "python3-gobject typelib-1_0-Gtk-3_0 libappindicator3-1 typelib-1_0-Notify-0_7" ;;
    openconnect:*) echo "openconnect" ;;
    pkexec:apt) echo "policykit-1" ;;
    pkexec:*)   echo "polkit" ;;
    *) echo "" ;;
  esac
}

missing_capabilities() {
  local missing=()
  have_gtk_bindings || missing+=("gtk")
  have_openconnect  || missing+=("openconnect")
  have_pkexec       || missing+=("pkexec")
  printf '%s\n' "${missing[@]+"${missing[@]}"}"
}

# apt first, so a Debian derivative carrying another manager still takes the
# path this project tests.
detect_manager() {
  command -v apt-get >/dev/null 2>&1 && { echo apt;    return 0; }
  command -v dnf     >/dev/null 2>&1 && { echo dnf;    return 0; }
  command -v pacman  >/dev/null 2>&1 && { echo pacman; return 0; }
  command -v zypper  >/dev/null 2>&1 && { echo zypper; return 0; }
  echo ""; return 1
}

install_command() {              # $1 manager, rest: packages
  local manager="$1"; shift
  case "$manager" in
    dnf)    echo "sudo dnf install $*" ;;
    pacman) echo "sudo pacman -S --needed $*" ;;
    zypper) echo "sudo zypper install $*" ;;
    apt)    echo "sudo apt install $*" ;;
    *)      echo "install these with your package manager: $*" ;;
  esac
}

# What to say on a distribution this script does not install for. Only the gaps
# are listed: a machine already carrying GTK and polkit should be told about
# openconnect and nothing else.
report_missing() {               # $1 manager (may be empty)
  local manager="$1" cap pkgs all=() split=()
  warn "this script only installs packages automatically on Debian/Ubuntu."
  warn "what is missing here, and how to get it:"
  while read -r cap; do
    [ -n "$cap" ] || continue
    pkgs="$(capability_packages "$cap" "${manager:-unknown}")"
    # Splitting on whitespace is the intent -- capability_packages returns a
    # space-separated list -- so it is done deliberately rather than by leaving
    # an expansion unquoted and hoping the reader knows which it was.
    if [ -n "$pkgs" ]; then
      read -ra split <<<"$pkgs"
      all+=("${split[@]}")
    fi
    printf "        %-12s %s\n" "$cap" "${pkgs:-<name unknown for this distribution>}" >&2
  done < <(missing_capabilities)
  [ ${#all[@]} -gt 0 ] &&
    warn "  $(install_command "${manager:-unknown}" "${all[@]}")"
  if ! have_sso; then
    warn "openconnect-sso is also missing. It needs Python 3.12 -- it pins"
    warn "lxml<5 and PyQt6-WebEngine<7, and neither builds on 3.13 or newer,"
    warn "which is what Fedora and Arch ship as their system python. Install a"
    warn "3.12 however your distribution provides one, then:"
    warn "  pipx install --python python3.12 'openconnect-sso[full]'"
    warn "  pipx inject openconnect-sso 'setuptools<71' --force"
  fi
  warn "on GNOME, also enable the AppIndicator extension:"
  warn "    gnome-extensions enable ubuntu-appindicators@ubuntu.com"
  warn "then re-run this script with --no-deps, which installs only the app."
}

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
  # Said out loud because it edits a shell rc file the user owns; hiding a
  # write to someone's dotfiles behind /dev/null is how surprises are made.
  say "pipx ensurepath (may add ~/.local/bin to your shell's PATH setup)"
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
  MANAGER="$(detect_manager || true)"

  # Before anything reaches for sudo: is there anything to do at all? On a
  # desktop that already has GTK, polkit and openconnect this is the whole of
  # the dependency phase, and it costs no password on any distribution. The old
  # order asked for one first and looked for work second.
  if [ -z "$(missing_capabilities)" ] && have_sso; then
    say "every dependency is already present -- nothing to install, no password needed"
    # Still done, because reaching here used to mean walking the apt block and
    # arriving at this line with everything already satisfied. It writes a
    # dconf setting and asks for no password, so skipping it would quietly cost
    # a user with the extension installed-but-off their tray icon.
    enable_extension
    INSTALL_DEPS=0
  elif [ "$MANAGER" != "apt" ]; then
    report_missing "$MANAGER"
    die "cannot install automatically on this distribution"
  fi
fi

if [ "$INSTALL_DEPS" -eq 1 ]; then
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
  # Inside the dependency pass on purpose: this writes a dconf setting, and
  # the README promises that --no-deps changes nothing on the system — the
  # binding check below only reads, so it stays outside.
  enable_extension
fi

verify_bindings

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
