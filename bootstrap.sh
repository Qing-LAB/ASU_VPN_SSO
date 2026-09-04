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
# Whether the missing pieces are ours to have installed. Set when the
# dependency pass is skipped -- by --no-deps, or because this distribution is
# not one this script installs for -- and read by verify_bindings, which must
# not treat a gap the user was just told about as a failure of its own.
# Declared here, above the option parsing that sets it: the first version of
# this sat beside verify_bindings, three hundred lines below --no-deps, and
# quietly reset it to 0 on every run.
DEPS_SKIPPED=0

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

# README says "Uses sudo", and a reader can take that as "run it with sudo".
# That installs everything into /root: the programs, the launcher, the CLI
# symlink, a root-owned pipx venv, and an edited /root/.bashrc -- then prints
# "Launch ASU VPN from the Activities overview" to a user whose own session
# has none of it. The script asks for sudo where it needs it, per command.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  printf '\033[1;31merror\033[0m %s\n' \
    "run this as yourself, not with sudo." >&2
  printf '  %s\n' \
    "It installs into your own home directory and asks for sudo only for" \
    "the system packages. Under sudo, \$HOME is /root and everything would" \
    "land there instead:" \
    "" \
    "    ./bootstrap.sh${*:+ $*}" >&2
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="${2:?--server needs a value}"; shift 2 ;;
    --server=*) SERVER="${1#*=}"; shift ;;
    --no-deps) INSTALL_DEPS=0; DEPS_SKIPPED=1; shift ;;
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

is_gnome() {
  # XDG_CURRENT_DESKTOP alone was the test, and it is unset over ssh and on a
  # VT -- so `ssh host ./bootstrap.sh` on a GNOME desktop decided it was not
  # GNOME and skipped the extension the tray icon needs, silently.
  case "${XDG_CURRENT_DESKTOP:-}" in *GNOME*) return 0 ;; esac
  command -v gnome-shell >/dev/null 2>&1
}

have_tray_extension() {
  # GNOME hides AppIndicator icons without an extension, so on GNOME this is a
  # dependency like any other and belongs in the capability list. It was not
  # in it, which is how the "everything is already present" fast path could
  # finish with a cheerful "done" on a machine whose tray icon would never
  # appear. Any appindicator extension counts, not only Ubuntu's.
  is_gnome || return 0
  [ -d /usr/share/gnome-shell/extensions/ubuntu-appindicators@ubuntu.com ] && return 0
  gnome-extensions list 2>/dev/null | grep -qi appindicator
}
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
    tray-extension:apt)    echo "gnome-shell-extension-appindicator" ;;
    tray-extension:dnf)    echo "gnome-shell-extension-appindicator" ;;
    tray-extension:pacman) echo "gnome-shell-extension-appindicator" ;;
    tray-extension:zypper) echo "gnome-shell-extension-appindicator" ;;
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
  have_gtk_bindings   || missing+=("gtk")
  have_openconnect    || missing+=("openconnect")
  have_pkexec         || missing+=("pkexec")
  have_tray_extension || missing+=("tray-extension")
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
  warn "the app itself is being installed now; nothing above needs this script"
  warn "to be run again."
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

is_ubuntu() {
  # ID_LIKE is deliberately not consulted: Mint and Pop!_OS are Ubuntu
  # derivatives that carry Ubuntu's own suites and can take the PPA, and they
  # say so in ID_LIKE -- but so does every Debian derivative that cannot.
  # UBUNTU_CODENAME is the field only an Ubuntu-suite system sets.
  [ -r /etc/os-release ] || return 1
  grep -q '^UBUNTU_CODENAME=' /etc/os-release
}

ensure_python() {
  if [ -x "$PYBIN" ]; then
    say "python$PY present ($("$PYBIN" -V 2>&1))"
    return
  fi
  if ! apt_known "python$PY"; then
    # A PPA is Launchpad, which is Ubuntu. detect_manager says "apt" for
    # Debian too, and add-apt-repository there either refuses or -- worse --
    # writes a source pinned to a suite deadsnakes does not publish, after
    # which *every* apt update on the machine fails until someone finds and
    # deletes the file. Nothing here removes it, and set -e means install.sh
    # is never reached, so the run leaves a broken package manager and no app.
    if ! is_ubuntu; then
      warn "python$PY is not in this distribution's archive, and"
      warn "$DEADSNAKES_PPA is an Ubuntu PPA -- adding it here would break apt."
      warn "Install python$PY however this distribution provides one, then:"
      warn "  pipx install --python python$PY '$SSO_SPEC'"
      warn "  pipx inject openconnect-sso '$SETUPTOOLS_PIN' --force"
      die "python$PY is required and cannot be installed automatically here."
    fi
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

  maintain_openconnect_sso "$sso"
}


maintain_openconnect_sso() {
  # The half the header promises runs every time: the setuptools pin, and the
  # PATH check. Split out because it used to live inside the install-if-absent
  # function, so the "everything is already present" fast path skipped both --
  # and the pin is the documented repair for a venv that a later
  # `pipx upgrade-all` rebuilt with a current setuptools, which is precisely
  # the machine that reaches that fast path.
  local sso="${1:-}"
  command -v pipx >/dev/null || return 0
  [ -n "$sso" ] || sso="$(command -v openconnect-sso || true)"
  [ -n "$sso" ] || { [ -x "$HOME/.local/bin/openconnect-sso" ] && sso="$HOME/.local/bin/openconnect-sso"; }
  [ -n "$sso" ] || return 0
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
  if ! have_gtk_bindings; then
    # A hard error only when we just tried and failed. Otherwise the CLI, the
    # config and the self-check all still install and all still work: the tray
    # is the only part that needs these, and saying so beats refusing to
    # install anything.
    [ "$DEPS_SKIPPED" -eq 1 ] || die "the system python3 is missing GTK bindings after installing them; this is a bug -- please report it"
    warn "no GTK bindings for the system python3: the tray applet will not"
    warn "start until they are installed. The asuvpn command line and"
    warn "'asuvpn selftest' work without them."
    return 0
  fi
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
    # The header promises the setuptools pin and the PATH check run every
    # time, and they live inside install_openconnect_sso -- which this path
    # skips. So a venv rebuilt by `pipx upgrade-all`, or a first run that died
    # between the install and the inject, was met with "nothing to install"
    # and repaired nothing, while the pin is the documented fix for exactly
    # that state.
    maintain_openconnect_sso
    INSTALL_DEPS=0
  elif [ "$MANAGER" != "apt" ]; then
    # Report, then carry on rather than dying. Everything below this point is
    # the user's own half -- ~/.local, no root, no distribution knowledge --
    # and it works on any Linux. Stopping here left a Fedora or Arch user with
    # nothing at all installed, and told them to re-run with --no-deps, which
    # then died telling them to re-run *without* it: the two messages pointed
    # at each other. One run now leaves `asuvpn` and `asuvpn selftest` in
    # place, and the self-check is a far better guide to what this machine
    # still needs than a list printed by a script that never looked at it.
    report_missing "$MANAGER"
    DEPS_SKIPPED=1
    INSTALL_DEPS=0
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
  if ! have_tray_extension; then
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

# Everything above this line can abort under set -e -- a compile failure in
# lxml, a transient archive error, a `confirm` that cannot prompt because
# there is no tty. All of it happens *after* apt has already changed the
# system, and none of it is needed by the half below, which touches only
# ~/.local. Dying silently there left a machine with two dozen new packages
# and no application, and nothing said what to do next.
explain_if_it_died() {
  [ "$1" -eq 0 ] && return 0
  warn "the dependency phase failed (exit $1)."
  warn "The app itself was not installed. Nothing above is needed to install"
  warn "it -- only to connect -- so this puts the app in place:"
  warn "    ./bootstrap.sh --no-deps --server $SERVER"
  warn "and 'asuvpn selftest' then says what is still missing."
}
trap 'explain_if_it_died $?' EXIT

verify_bindings

say "installing the app, the launcher and the asuvpn command"
bash "$SRC_DIR/install.sh" --server "$SERVER" "${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}"

if [ "$DEPS_SKIPPED" -eq 1 ] && [ -n "$(missing_capabilities)" ]; then
  cat <<EOF

$(say "the app is installed; the system packages above are not")

  What works right now:

      asuvpn selftest       # what this machine still needs, checked live
      asuvpn --write-config # print a settings file

  The tray applet and connecting need the packages listed above. Install them
  with your own package manager -- nothing here has to be run again afterwards.

EOF
  exit 0
fi

trap - EXIT

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
