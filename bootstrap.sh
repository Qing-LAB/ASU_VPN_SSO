#!/usr/bin/env bash
# Setup, and repair, for the ASU VPN tray applet. Safe to re-run: it asks the
# machine what is wrong and fixes only that. The sign-in tool is judged by
# whether it *works*, not by whether a file with its name exists, so an OS
# upgrade that leaves a dead environment behind is found and rebuilt.
#
#   ./bootstrap.sh                          # install or repair, then register
#   ./bootstrap.sh --reset                  # rebuild the sign-in environment anyway
#   ./bootstrap.sh --server vpn.other.edu   # a different endpoint
#   ./bootstrap.sh --yes                    # never prompt
#   ./bootstrap.sh --no-deps                # only install the app, skip packages
#   ./bootstrap.sh --link                   # run from this checkout, do not copy
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="sslvpn.asu.edu"
INSTALL_DEPS=1
ASSUME_YES=0
RESET=0
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
# and neither has wheels for 3.13+. The applet itself runs on the system
# python3 and never sees this one.
#
# uv provides it, and is the only tool that does. Not apt and not a PPA: the
# interpreter and the environment live under $HOME, so no distribution upgrade
# can take them away -- which is exactly what the upgrade to Ubuntu 26.04 did
# to the python3.12 and pipx this script used to depend on, leaving an
# environment that existed on disk and could not start. Not a system python3.12
# either (--managed-python below): a half-removed one is how that happened.
PY=3.12

# openconnect-sso 0.8.1 has no [full] extra (uv says so); keyring support is a
# hard dependency. setuptools must stay pinned: openconnect-sso still imports
# pkg_resources, which current setuptools no longer ships. <71 is the
# known-good bound, not the exact boundary -- measured: 78.1.1 still has it,
# 83.0.0 does not. --with makes the pin part of the install itself, so it
# cannot be skipped the way `pipx inject` skipped it (exit 0, nothing done).
SSO_SPEC='openconnect-sso'
SETUPTOOLS_PIN='setuptools<71'

# The uv this script fetches only when the machine has none. Pinned, with the
# checksum of each archive recorded here: the trust is in this file, not in a
# second download from the same host. Needs UV_MIN or newer when one is found.
UV_VERSION="0.11.19"
UV_MIN="0.5.0"
UV_SHA256_x86_64="7035608168e106375b36d0c818d537a889c51a8625fe7f8f7cad5e62b947c368"
UV_SHA256_aarch64="83b13ab184a45b7d9a3b0e4b10eaebd50ad41e66cb16dcce8e60aa7be13ae399"

# What the applet itself imports, from the *system* python3.
APT_RUNTIME=(python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 openconnect)
# Shared libraries Qt6 WebEngine dlopens for the sign-in browser window.
APT_QT=(libnss3 libxcomposite1 libxdamage1 libxrandr2 libxkbcommon-x11-0 libxcb-cursor0
        libgl1 libegl1 libxtst6 libdbus-1-3 fontconfig)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

# Whether a person is there to answer. confirm() would say "re-run with --yes"
# on no terminal, which is the wrong advice for the one question --yes must not
# answer (removing a third-party apt source), so that question asks this first.
can_ask() { [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; }

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
    --reset) RESET=1; shift ;;
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
# openconnect installs to /usr/sbin, which a normal user's PATH lacks on Debian;
# a PATH-only test called it missing on every run there, and went to sudo for a
# package that was installed. The applet looks in the sbin directories itself.
have_openconnect() {
  command -v openconnect >/dev/null 2>&1 ||
    [ -x /usr/sbin/openconnect ] || [ -x /sbin/openconnect ]
}

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
# The sign-in tool is asked whether it works, never whether a file is there.
# This used to be `[ -x ~/.local/bin/openconnect-sso ]`, and an OS upgrade that
# removed the interpreter behind it left a symlink that still passed: the script
# said "every dependency is already present" and repaired nothing, over an
# install that died at import. Same question `asuvpn selftest` asks, so the two
# cannot disagree.
find_sso() {
  command -v openconnect-sso 2>/dev/null && return 0
  [ -x "$HOME/.local/bin/openconnect-sso" ] && { echo "$HOME/.local/bin/openconnect-sso"; return 0; }
  return 1
}

# The interpreter that runs a console script. The python beside the real script
# first, because uv writes an `sh` stub instead of a shebang when the path is
# long or has a space in it; the shebang only for an install pip made.
sso_python() {                   # $1 = console script
  local real dir first py
  real="$(readlink -f "$1" 2>/dev/null)" || return 1
  dir="$(dirname "$real")"
  [ -x "$dir/python" ] && { echo "$dir/python"; return 0; }
  first="$(head -1 "$real" 2>/dev/null)"
  case "$first" in "#!"*) py="$(printf '%s' "${first#\#!}" | awk '{print $1}')" ;; *) return 1 ;; esac
  [ -n "$py" ] && [ -x "$py" ] && { echo "$py"; return 0; }
  return 1
}

sso_healthy() {                  # $1 = console script (default: whichever is found)
  local sso="${1:-}" py
  [ -n "$sso" ] || sso="$(find_sso)" || return 1
  py="$(sso_python "$sso")" || return 1
  "$py" -W ignore -c 'import openconnect_sso, pkg_resources' >/dev/null 2>&1
}
have_sso() { sso_healthy; }


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
  warn "openconnect-sso itself is built below by uv, on any distribution."
  warn "on GNOME, also enable the AppIndicator extension:"
  warn "    gnome-extensions enable ubuntu-appindicators@ubuntu.com"
  warn "the app itself is being installed now; nothing above needs this script"
  warn "to be run again."
}

# --------------------------------------------------------------- apt helpers

apt_known()   { apt-cache show "$1" >/dev/null 2>&1; }
# One status line per architecture, so a machine with multiarch enabled (i386
# for wine or steam) answers "installedinstalled" for a library present in both
# -- and an equality test on the whole string called those missing, and went to
# apt, and so to sudo, for packages that were already there. Any installed
# line counts.
apt_present() { dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed; }

# The fixed-name packages the sign-in window needs that dpkg says are absent.
# dpkg only, so asking costs neither a password nor a network round trip.
apt_gaps() {
  local pkg
  for pkg in "${APT_RUNTIME[@]}" "${APT_QT[@]}"; do
    apt_present "$pkg" || echo "$pkg"
  done
  apt_present libasound2t64 || apt_present libasound2 || echo libasound2t64
}

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

# ------------------------------------------------------------------------ uv

find_uv() {
  command -v uv 2>/dev/null && return 0
  [ -x "$HOME/.local/bin/uv" ] && { echo "$HOME/.local/bin/uv"; return 0; }
  return 1
}

version_at_least() {             # $1 have, $2 need
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# One tool, found or fetched into $HOME, so the starting point is known and
# nothing is added to the system. An existing uv is used as it is and never
# replaced -- it is the user's.
ensure_uv() {
  local have triple expect archive url tmp
  if UV="$(find_uv)"; then
    have="$("$UV" --version 2>/dev/null | awk '{print $2}')"
    version_at_least "${have:-0}" "$UV_MIN" ||
      die "uv $have at $UV is older than $UV_MIN; update it ('uv self update'), then re-run"
    say "uv ${have} ($UV)"
    return 0
  fi

  case "$(uname -m)-$(uname -s)" in
    x86_64-Linux)  triple=x86_64-unknown-linux-gnu;  expect="$UV_SHA256_x86_64" ;;
    aarch64-Linux) triple=aarch64-unknown-linux-gnu; expect="$UV_SHA256_aarch64" ;;
    *) die "no uv build is pinned for $(uname -m); install uv yourself (https://docs.astral.sh/uv/), then re-run" ;;
  esac
  command -v curl >/dev/null 2>&1 || {
    command -v apt-get >/dev/null 2>&1 || die "curl is needed to fetch uv; install it, then re-run"
    apt_install_missing curl ca-certificates
  }
  archive="uv-$triple.tar.gz"
  url="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$archive"
  confirm "Download uv $UV_VERSION (~20 MB) from github.com/astral-sh/uv into ~/.local/bin?" ||
    die "uv is required for the sign-in tool. Install it yourself (https://docs.astral.sh/uv/), then re-run."

  tmp="$(mktemp -d)"
  say "fetching $archive"
  if ! curl -fsSL --retry 2 --max-time 180 -o "$tmp/$archive" "$url"; then
    rm -rf "$tmp"
    die "could not download $url -- is the network up? (a proxy needs https_proxy set)"
  fi
  if [ "$(sha256sum "$tmp/$archive" | awk '{print $1}')" != "$expect" ]; then
    rm -rf "$tmp"
    die "$archive does not match the checksum pinned in this script; refusing to run it"
  fi
  tar -xzf "$tmp/$archive" -C "$tmp"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/uv-$triple/uv" "$tmp/uv-$triple/uvx" "$HOME/.local/bin/"
  rm -rf "$tmp"
  UV="$HOME/.local/bin/uv"
  # The pinned build is glibc. On a musl system the checksum matches, the file
  # installs, and the first use fails with an error about a missing loader.
  "$UV" --version >/dev/null 2>&1 ||
    die "the downloaded uv will not run here (a musl distribution, perhaps); install uv yourself (https://docs.astral.sh/uv/), then re-run"
  say "uv $UV_VERSION installed in ~/.local/bin"
}

# ------------------------------------------------------------- openconnect-sso

# Build or repair the sign-in environment. Judged by effect: healthy means it
# imports, so a working install -- whoever made it -- is left alone, and a dead
# one is replaced whatever killed it. --reset replaces it regardless.
install_openconnect_sso() {
  local sso target found
  # Ask first, fetch second. A working install -- a pipx one from an earlier
  # version of this script, say -- needs no uv, and downloading one to find
  # that out would be the exact surprise "leave a working install alone" rules
  # out.
  if [ "$RESET" -eq 0 ] && sso="$(find_sso)" && sso_healthy "$sso"; then
    say "openconnect-sso works ($sso)"
    return 0
  fi
  ensure_uv
  if sso="$(find_sso)"; then
    if [ "$RESET" -eq 1 ]; then
      say "--reset: rebuilding openconnect-sso ($sso) from scratch"
    else
      warn "openconnect-sso at $sso does not work; replacing it"
    fi
  fi
  # An old pipx environment that is already dead goes first: there is nothing in
  # it to lose, and `pipx uninstall` is only safe *before* uv's console script
  # exists, since it unlinks ~/.local/bin/openconnect-sso by name. A working
  # one stays until the replacement is verified (retire_legacy, below), so a
  # failed rebuild cannot leave a machine with neither.
  if [ -f "$(legacy_pipx_venv)/pipx_metadata.json" ] &&
     ! sso_healthy "$(legacy_pipx_venv)/bin/openconnect-sso"; then
    retire_pipx_env before
  fi

  say "building openconnect-sso on Python $PY with uv (a minute or two)"
  # --managed-python: a Python uv fetched and owns, never a system one -- a
  # half-removed system python3.12 is what this exists to stop depending on.
  # --force replaces a console script left by pipx or pip; --reinstall only on
  # an explicit reset, since a repair has no reason to trust the old files.
  local flags=(--force --managed-python --python "$PY" --with "$SETUPTOOLS_PIN")
  [ "$RESET" -eq 1 ] && flags+=(--reinstall)
  "$UV" tool install "${flags[@]}" "$SSO_SPEC"

  # Verified at the path uv just wrote, not at whatever PATH finds first: a
  # stale copy earlier on PATH must not be able to vouch for this one.
  target="$("$UV" tool dir --bin)/openconnect-sso"
  sso_healthy "$target" ||
    die "openconnect-sso was rebuilt but still cannot start; run: $target --help"
  say "openconnect-sso OK ($target)"
  # Where the applet will look: PATH, then ~/.local/bin. A custom uv bin dir
  # (UV_TOOL_BIN_DIR, XDG_BIN_HOME) outside both leaves it unfindable.
  found="$(find_sso || true)"
  if [ -z "$found" ]; then
    warn "$target is not on PATH or in ~/.local/bin, so the applet cannot find it"
  elif [ "$(readlink -f "$found")" != "$(readlink -f "$target")" ]; then
    warn "$found comes first and shadows it; remove that one"
  fi
  retire_legacy
}

# -------------------------------------------------------------- old installs

legacy_pipx_venv() {
  echo "${PIPX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pipx}/venvs/openconnect-sso"
}

# Remove the environment an earlier version of this script made with pipx.
# pipx_metadata.json is what says it is pipx's, so nothing else is ever touched.
#
#   before  the uv build has not run: `pipx uninstall` is allowed, and is the
#           clean way, because the console script it unlinks is still pipx's.
#   after   uv's script is in place under the same name, so pipx must not be
#           asked to unlink anything -- only the directory goes.
#
# Either way the directory is removed by hand at the end: pipx may be gone (the
# upgrade that broke this removed it), or may refuse a broken venv.
retire_pipx_env() {              # $1 = before | after
  local venv; venv="$(legacy_pipx_venv)"
  [ -f "$venv/pipx_metadata.json" ] || return 0
  say "removing the old pipx environment for openconnect-sso ($venv)"
  if [ "$1" = before ] && command -v pipx >/dev/null 2>&1; then
    pipx uninstall openconnect-sso >/dev/null 2>&1 || true
  fi
  rm -rf "$venv"
}

# What earlier versions of this script left behind, removed only once the
# replacement is verified -- never before, so a failed rebuild cannot leave a
# machine with neither. (A dead old environment is the exception and goes
# first; see install_openconnect_sso.) Everything here is a thing this script
# itself made. What it merely used (pipx, python3.12, a toolchain) stays: the
# user may use those for other work, so they are named, never removed.
retire_legacy() {
  local f stale=()

  retire_pipx_env after

  for f in "${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"/deadsnakes*; do
    [ -e "$f" ] && stale+=("$f")
  done
  if [ ${#stale[@]} -gt 0 ]; then
    say "an earlier version of this script added the deadsnakes PPA; nothing here uses it now:"
    printf '        %s\n' "${stale[@]}"
    # --yes does not reach this: it means "do not ask me about what I am
    # adding", and a third-party apt source that may be serving other Pythons
    # is not this script's to remove on a blanket yes. Only a typed y does.
    if can_ask && confirm "Remove ${#stale[@]} apt source file(s) listed above?"; then
      sudo rm -f -- "${stale[@]}"
      APT_UPDATED=0
    else
      warn "left in place. To remove it yourself: sudo rm -- ${stale[*]}"
    fi
  fi

  # pipx only. python3.12 is deliberately not named: on Ubuntu 24.04 it is the
  # system python3, and a line telling someone to remove it is how a desktop
  # gets uninstalled.
  apt_present pipx 2>/dev/null &&
    warn "pipx is still installed; this app no longer uses it (sudo apt remove pipx, if nothing else does)"
  return 0
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

# Sourced, not run, by tests/bootstrap-health.sh: the functions above are what
# it exercises, and nothing below should happen to the machine running it.
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0

# Armed for the dependency phase below, and disarmed the moment it ends --
# which is the whole point, and where the first version of this got it wrong.
# It was installed *after* that phase, so an abort inside it (a compile
# failure in lxml, a transient archive error, a `confirm` with no tty) still
# said nothing, while a failure of `install.sh` afterwards was reported as
# "the dependency phase failed" and the advice sent the user round in a
# circle: `--no-deps` re-runs the same install.sh and fails identically.
#
# All of the dependency phase happens after apt has already changed the
# system, and none of it is needed by the user half, which touches only
# ~/.local -- so dying silently there left a machine with two dozen new
# packages and no application.
explain_if_it_died() {
  [ "$1" -eq 0 ] && return 0
  warn "the dependency phase failed (exit $1)."
  warn "The app itself was not installed. Nothing above is needed to install"
  warn "it -- only to connect -- so this puts the app in place:"
  warn "    ./bootstrap.sh --no-deps --server $SERVER"
  warn "and 'asuvpn selftest' then says what is still missing."
}
trap 'explain_if_it_died $?' EXIT

if [ "$INSTALL_DEPS" -eq 1 ]; then
  MANAGER="$(detect_manager || true)"
  NEED_SSO=1
  if [ "$RESET" -eq 0 ] && sso_healthy; then NEED_SSO=0; fi

  # Before anything reaches for sudo: is there anything to do at all? On a
  # desktop that already has GTK, polkit and openconnect this costs no password
  # on any distribution. The sign-in tool being broken is not a reason to ask
  # for one -- uv rebuilds it in $HOME -- but a rebuild is when the Qt libraries
  # it needs are worth checking, so they are looked at then, by dpkg alone.
  GAPS="$(missing_capabilities)"
  if [ "$NEED_SSO" -eq 1 ] && [ "$MANAGER" = "apt" ]; then GAPS="$GAPS$(apt_gaps)"; fi
  if [ -z "$GAPS" ]; then
    say "no system package is missing -- nothing to install, no password needed"
    # Still done: it writes a dconf setting and asks for no password, so
    # skipping it would quietly cost a user with the extension installed-but-off
    # their tray icon.
    enable_extension
  elif [ "$MANAGER" = "apt" ]; then
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

    apt_install_missing "${APT_RUNTIME[@]}" "${APT_QT[@]}" \
                        "$polkit_pkg" "$alsa_pkg" "$tray_ext"
    [ -n "$tray_ext" ] && NEEDS_RELOGIN=1
    # Inside the dependency pass on purpose: this writes a dconf setting, and
    # the README promises that --no-deps changes nothing on the system -- the
    # binding check below only reads, so it stays outside.
    enable_extension
  else
    # Report, then carry on rather than dying. The sign-in tool below needs no
    # distribution knowledge, and neither does the user's half after it, so one
    # run still leaves `asuvpn` and `asuvpn selftest` in place.
    report_missing "$MANAGER"
    DEPS_SKIPPED=1
  fi

  # Every distribution: this half lives in $HOME and asks for no privileges.
  install_openconnect_sso
fi

# The dependency phase is over; everything below installs into ~/.local and
# owns its own failures.
trap - EXIT

verify_bindings

say "installing the app, the launcher and the asuvpn command"
# --strict: the self-check's verdict comes back as an exit status, so the
# ending below reports what it found instead of announcing "done" over a
# failure. Status 3 is that verdict; any other non-zero is install.sh itself.
SELFTEST_RC=0
bash "$SRC_DIR/install.sh" --strict --server "$SERVER" "${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}" || SELFTEST_RC=$?
[ "$SELFTEST_RC" -eq 0 ] || [ "$SELFTEST_RC" -eq 3 ] || exit "$SELFTEST_RC"

if [ "$DEPS_SKIPPED" -eq 1 ] && [ -n "$(missing_capabilities)" ]; then
  cat <<EOF

$(say "the app is installed; the system packages above are not")

  What works right now:

      asuvpn selftest       # what this machine still needs, checked live
      asuvpn --write-config "$SERVER"   # print a settings file

  The tray applet and connecting need the packages listed above. Install them
  with your own package manager -- nothing here has to be run again afterwards.

EOF
  exit 0
fi

if [ "$SELFTEST_RC" -eq 3 ]; then
  warn "installed, but the self-check above found problems -- this is not a working"
  warn "install yet. 'asuvpn selftest' repeats the report. If it names"
  warn "openconnect-sso, './bootstrap.sh --reset' rebuilds that from nothing."
  exit 1
fi

cat <<EOF

$(say "done")

  Launch "ASU VPN" from the Activities overview, or from a terminal:

      asuvpn connect        # sign in and connect
      asuvpn status         # what state is it in
      asuvpn disconnect

      asuvpn selftest       # check this install against this machine

  Nothing else to set up: signing in happens in your browser, on ASU's own
  login page with Duo, and no password is stored anywhere.

  The one exception is if you have told openconnect-sso a username, so it can
  fill that page in for you. It then wants the matching password in your login
  keyring, and this applet will not guess a blank one. "asuvpn selftest" says
  so plainly if that applies to you; this is how to store it:

      openconnect-sso --server $SERVER --user YOUR_ASURITE --authenticate=shell

EOF
