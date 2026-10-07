#!/usr/bin/env bash
# bootstrap.sh decides whether to rebuild the sign-in tool by asking whether it
# works. These cases are the ones that decision got wrong: an OS upgrade
# removes the interpreter an environment was built on and leaves the console
# script behind, so "is the file there" says yes over an install that cannot
# start. Hermetic: fake environments in a scratch directory, no network, no
# sudo, nothing outside it touched. Needs only a python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILED=0
check() {                        # $1 description, rest: command that must succeed
  local what="$1"; shift
  if "$@"; then echo "  ok   $what"; else echo "  FAIL $what"; FAILED=1; fi
}
no() { ! "$@"; }

# shellcheck source=bootstrap.sh
. "$HERE/../bootstrap.sh"
set +e  # the functions under test report by status; this script asserts on it
PY3="$(command -v python3)"

# A minimal "environment": bin/python, a console script, and (optionally) the
# two modules sso_healthy imports, made importable through PYTHONPATH.
mkenv() {                        # $1 name, $2 interpreter-kind: ok | missing-modules | dangling | stub
  local d="$T/$1" kind="$2"
  mkdir -p "$d/bin" "$d/mods"
  case "$kind" in
    dangling) ln -s "$T/nonexistent/python3" "$d/bin/python" ;;
    *)        ln -s "$PY3" "$d/bin/python" ;;
  esac
  case "$kind" in
    stub) printf '#!/bin/sh\n'"'''exec' /x/python \"\$0\" \"\$@\"\n' '''"'\n' > "$d/bin/openconnect-sso" ;;
    *)    printf '#!%s\nprint(1)\n' "$d/bin/python" > "$d/bin/openconnect-sso" ;;
  esac
  chmod +x "$d/bin/openconnect-sso"
  echo "$d/bin/openconnect-sso"
}
withmods() { mkdir -p "$T/mods"; : > "$T/mods/openconnect_sso.py"; : > "$T/mods/pkg_resources.py"; }
nomods()   { rm -rf "$T/mods"; mkdir -p "$T/mods"; }

echo "sso_healthy"
withmods; export PYTHONPATH="$T/mods"
check "a working environment is healthy"            sso_healthy "$(mkenv good ok)"
check "a console script behind uv's sh stub still resolves" sso_healthy "$(mkenv stub stub)"
nomods
check "THE UPGRADE CASE: interpreter exists, modules gone -> unhealthy" no sso_healthy "$(mkenv gone missing-modules)"
withmods
check "an interpreter that no longer exists -> unhealthy" no sso_healthy "$(mkenv dangling dangling)"
check "a script that does not exist -> unhealthy"        no sso_healthy "$T/nope"
# Raises rather than being absent: a host python may ship the real one.
echo 'raise ImportError("no pkg_resources")' > "$T/mods/pkg_resources.py"
check "setuptools without pkg_resources -> unhealthy"    no sso_healthy "$(mkenv nopkg ok)"
unset PYTHONPATH

echo "have_openconnect"
# A Debian user's PATH has no sbin. Skipped on a machine with no openconnect at
# all, where there is nothing for the lookup to find.
if [ -x /usr/sbin/openconnect ] || [ -x /sbin/openconnect ]; then
  SAVED="$PATH"; PATH=/usr/bin:/bin
  # shellcheck disable=SC2016  # expanded by the inner shell, on purpose
  check "openconnect in /usr/sbin counts although PATH lacks it" \
    bash -c 'p=$1; set --; . "$p"; have_openconnect' _ "$HERE/../bootstrap.sh"
  PATH="$SAVED"
fi

echo "apt_present (multiarch)"
# dpkg-query answers once per architecture; stubbed so no real dpkg is needed.
# shellcheck disable=SC2329  # called by apt_present, which shellcheck cannot see
dpkg-query() { printf 'installed\ninstalled\n'; }
check "a library installed for two architectures counts as present" apt_present libgl1
# shellcheck disable=SC2329
dpkg-query() { printf 'not-installed\n'; }
check "a package that is not installed does not"  no apt_present libgl1
unset -f dpkg-query

echo "retire_legacy"
can_ask() { return 0; }
confirm() { return 1; }
export HOME="$T/home" PIPX_HOME="$T/pipx" APT_SOURCES_DIR="$T/apt"
mkdir -p "$HOME/.local/bin" "$PIPX_HOME/venvs/openconnect-sso" "$PIPX_HOME/venvs/other" "$APT_SOURCES_DIR"
: > "$PIPX_HOME/venvs/openconnect-sso/pipx_metadata.json"
: > "$PIPX_HOME/venvs/other/pipx_metadata.json"
ln -s "$T/uv-tool/openconnect-sso" "$HOME/.local/bin/openconnect-sso"
: > "$APT_SOURCES_DIR/deadsnakes-ubuntu-ppa-noble.sources"
: > "$APT_SOURCES_DIR/google-chrome.sources"
SUDO_LOG="$T/sudo.log"; : > "$SUDO_LOG"
sudo() { echo "$*" >> "$SUDO_LOG"; command rm "${@:2}" 2>/dev/null; return 0; }
retire_legacy >/dev/null 2>&1
check "the old pipx environment for this package is removed" no test -e "$PIPX_HOME/venvs/openconnect-sso"
check "another pipx package is left alone"           test -e "$PIPX_HOME/venvs/other"
check "uv's console script link is not unlinked"     test -L "$HOME/.local/bin/openconnect-sso"
check "declining leaves the apt source in place"     test -e "$APT_SOURCES_DIR/deadsnakes-ubuntu-ppa-noble.sources"
check "...and runs nothing as root"                  test ! -s "$SUDO_LOG"
confirm() { return 0; }
retire_legacy >/dev/null 2>&1
check "accepting removes the deadsnakes source"      no test -e "$APT_SOURCES_DIR/deadsnakes-ubuntu-ppa-noble.sources"
check "an unrelated apt source is never touched"     test -e "$APT_SOURCES_DIR/google-chrome.sources"
can_ask() { return 1; }
: > "$APT_SOURCES_DIR/deadsnakes-ubuntu-ppa-noble.sources"
retire_legacy >/dev/null 2>&1
check "--yes never removes a third-party apt source"  test -e "$APT_SOURCES_DIR/deadsnakes-ubuntu-ppa-noble.sources"
can_ask() { return 0; }
retire_legacy 2>&1 | grep -q 'python3.12' && { echo "  FAIL never advise removing python3.12"; FAILED=1; } || echo "  ok   never advises removing python3.12 (it is the system python on 24.04)"

echo "ensure_uv: the user's choice"
export HOME="$T/uvhome"; mkdir -p "$HOME"
CURL_LOG="$T/curl.log"; INST_LOG="$T/installer.log"
reset_uv() { rm -rf "$HOME/.local" "$CURL_LOG" "$INST_LOG"; mkdir -p "$HOME"; }
# A stand-in for curl that "downloads" an installer which records its
# environment and makes a uv reporting $FAKE_UV_VERSION.
# shellcheck disable=SC2329  # called by install_uv_official
curl() {
  local out="" url=""
  while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
  echo "$url" >> "$CURL_LOG"
  cat > "$out" <<INSTEOF
#!/bin/sh
echo "UNMANAGED=\$UV_UNMANAGED_INSTALL NOPATH=\$UV_NO_MODIFY_PATH" >> "$INST_LOG"
mkdir -p "\$UV_UNMANAGED_INSTALL"
printf '#!/bin/sh\necho "uv %s (fake)"\n' "$FAKE_UV_VERSION" > "\$UV_UNMANAGED_INSTALL/uv"
chmod +x "\$UV_UNMANAGED_INSTALL/uv"
INSTEOF
}
find_uv() { return 1; }               # a machine with no uv
FAKE_UV_VERSION=9.9.9

reset_uv; ASSUME_YES=0
check "no terminal and no --yes: the answer is manual"        test "$(ask_uv_choice </dev/null 2>/dev/null)" = manual
ASSUME_YES=1
check "--yes: the answer is install"                          test "$(ask_uv_choice 2>/dev/null)" = install
ASSUME_YES=0

ask_uv_choice() { echo manual; }
# shellcheck disable=SC2218  # defined by the sourced bootstrap.sh; stubbed again further down
( ensure_uv ) >"$T/out.txt" 2>&1; rc=$?
check "choosing to install it yourself stops the run"         test "$rc" -ne 0
check "...and tells you how, with the official installer"     grep -q 'astral.sh/uv/install.sh' "$T/out.txt"
check "...and where every other option is listed"             grep -q 'docs.astral.sh' "$T/out.txt"
check "...and downloads nothing at all"                       test ! -e "$CURL_LOG"

ask_uv_choice() { echo install; }
reset_uv
# shellcheck disable=SC2218  # defined by the sourced bootstrap.sh; stubbed again further down
( ensure_uv; echo "UV=$UV" > "$T/uvvar.txt" ) >/dev/null 2>&1; rc=$?
check "choosing the official installer succeeds"              test "$rc" -eq 0
check "...fetching uv's own installer URL"                    grep -qx 'https://astral.sh/uv/install.sh' "$CURL_LOG"
check "...into ~/.local/bin, with PATH editing off"           grep -qx "UNMANAGED=$HOME/.local/bin NOPATH=1" "$INST_LOG"
check "...and uv is where ensure_uv says it is"               grep -qx "UV=$HOME/.local/bin/uv" "$T/uvvar.txt"
check "...touching no shell startup file"                     test ! -e "$HOME/.bashrc" -a ! -e "$HOME/.profile" -a ! -e "$HOME/.zshrc"

reset_uv; FAKE_UV_VERSION=0.1.0
# shellcheck disable=SC2218  # defined by the sourced bootstrap.sh; stubbed again further down
( ensure_uv ) >"$T/out.txt" 2>&1; rc=$?
check "an installed uv that is too old is refused"            test "$rc" -ne 0
FAKE_UV_VERSION=9.9.9

reset_uv
# shellcheck disable=SC2329
find_uv() { echo "$T/present-uv"; }
printf '#!/bin/sh\necho "uv 9.9.9"\n' > "$T/present-uv"; chmod +x "$T/present-uv"
ask_uv_choice() { echo "ASKED" >> "$T/asked.log"; echo install; }
rm -f "$T/asked.log"
# shellcheck disable=SC2218  # defined by the sourced bootstrap.sh; stubbed again further down
( ensure_uv ) >/dev/null 2>&1
check "a uv that is already there is used without asking"     test ! -e "$T/asked.log"
check "...and nothing is downloaded"                          test ! -e "$CURL_LOG"
unset -f curl find_uv ask_uv_choice
export HOME="$T/home"

echo "ordering: when the old pipx environment goes"
# A fake uv that records whether the old environment still existed at the
# moment it was asked to build, then builds a working one.
PIPXENV="$PIPX_HOME/venvs/openconnect-sso"
FAKEUV="$T/fakeuv"
cat > "$FAKEUV" <<UVEOF
#!/bin/sh
case "\$1 \$2" in
  "tool dir") echo "$HOME/.local/bin" ;;
  "tool install")
    if [ -e "$PIPXENV" ]; then echo "old-env-present" >> "$T/order.log"; else echo "old-env-absent" >> "$T/order.log"; fi
    mkdir -p "$T/uvtool/bin"; ln -sf "$PY3" "$T/uvtool/bin/python"
    printf '#!/bin/sh\n' > "$T/uvtool/bin/openconnect-sso"; chmod +x "$T/uvtool/bin/openconnect-sso"
    ln -sfn "$T/uvtool/bin/openconnect-sso" "$HOME/.local/bin/openconnect-sso" ;;
esac
UVEOF
chmod +x "$FAKEUV"
ensure_uv() { UV="$FAKEUV"; }
PIPX_CALLS="$T/pipx.log"
# shellcheck disable=SC2329
pipx() { echo "$*" >> "$PIPX_CALLS"; command rm -rf "$PIPXENV"; command rm -f "$HOME/.local/bin/openconnect-sso"; }
confirm() { return 1; }
rm -rf "$APT_SOURCES_DIR"; mkdir -p "$APT_SOURCES_DIR"
withmods; export PYTHONPATH="$T/mods"; SAVED_PATH="$PATH"; PATH=/usr/bin:/bin

reset_world() {                  # $1 = kind of the old pipx env: dangling | ok
  rm -rf "$PIPX_HOME" "$T/uvtool" "$HOME/.local/bin/openconnect-sso" "$T/order.log" "$PIPX_CALLS"
  mkdir -p "$PIPX_HOME/venvs"
  mkenv "pipx/venvs/openconnect-sso" "$1" >/dev/null
  : > "$PIPXENV/pipx_metadata.json"
  ln -s "$PIPXENV/bin/openconnect-sso" "$HOME/.local/bin/openconnect-sso"
}

RESET=0; reset_world dangling
install_openconnect_sso >/dev/null 2>&1
check "a DEAD old environment is gone before uv builds"   grep -qx old-env-absent "$T/order.log"
check "...removed with pipx while pipx's link was still its own" grep -q 'uninstall openconnect-sso' "$PIPX_CALLS"
check "...and the new install is the one now linked"      sso_healthy "$HOME/.local/bin/openconnect-sso"

RESET=1; reset_world ok
install_openconnect_sso >/dev/null 2>&1
check "a WORKING old environment is still there when uv builds" grep -qx old-env-present "$T/order.log"
check "...and removed once the new one is verified"       no test -e "$PIPXENV"
check "...WITHOUT pipx, which would unlink uv's script"   test ! -e "$PIPX_CALLS"
check "...so uv's console script survives"                sso_healthy "$HOME/.local/bin/openconnect-sso"

RESET=0; reset_world ok
UV_FETCHED=0; ensure_uv() { UV_FETCHED=1; UV="$FAKEUV"; }
install_openconnect_sso >/dev/null 2>&1
check "a working install with no reset is left entirely alone" test -e "$PIPXENV"
check "...and uv is never asked to build"                 test ! -e "$T/order.log"
check "...and uv is not even downloaded to find that out" test "$UV_FETCHED" -eq 0
ensure_uv() { UV="$FAKEUV"; }
PATH="$SAVED_PATH"; unset PYTHONPATH; unset -f pipx

echo
if [ "$FAILED" -eq 0 ]; then echo "bootstrap-health: all passed"; else echo "bootstrap-health: FAILED"; exit 1; fi
