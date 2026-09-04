#!/usr/bin/env bash
# Installs the ASU VPN tray applet for the current user: the program itself into
# ~/.local/share/asuvpn, plus a launcher, an icon, and an `asuvpn` command.
# Nothing is written outside $HOME and no system settings are touched.
# Dependencies are bootstrap.sh's job.
#
#   ./install.sh [--server HOST] [--link]
#
#   --link   run from this checkout instead of copying into ~/.local, so edits
#            take effect immediately. The checkout then has to stay put.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# XDG_DATA_HOME, on the same terms as XDG_CONFIG_HOME and XDG_CACHE_HOME
# below: absolute or ignored, which is what the spec says. It was the one of
# the three not honoured, so on a relocated data dir (home-manager, Nix, Guix)
# the launcher and the icon landed outside the session's search path -- no
# "ASU VPN" in the overview, no icon, and install.sh printing both paths as
# though it had succeeded.
case "${XDG_DATA_HOME:-}" in
  /*) DATA_HOME="$XDG_DATA_HOME" ;;
  *)  DATA_HOME="$HOME/.local/share" ;;
esac
APP_DIR="$DATA_HOME/asuvpn"
APPS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
BIN_DIR="$HOME/.local/bin"
DESKTOP_FILE="$APPS_DIR/asuvpn.desktop"
# Kept in sync by hand with the contract's `server` default: bash cannot load
# asuvpn_contract.py, and this value must exist before the tray is installed.
SERVER="sslvpn.asu.edu"
LINK_MODE=0
REMOVE_STALE_COPY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="${2:?--server needs a value}"; shift 2 ;;
    --server=*) SERVER="${1#*=}"; shift ;;
    --link) LINK_MODE=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# A hostname, nothing else. This value is written into a .desktop Exec line, a
# config file and an autostart entry, and later becomes an argument to a command
# run under pkexec — so it is checked once, here, rather than trusted three times.
case "$SERVER" in
  *[!A-Za-z0-9.-]* | "" | -* | *..*)
    echo "invalid --server value: $SERVER" >&2
    echo "expected a hostname, e.g. sslvpn.asu.edu" >&2
    exit 1 ;;
esac

# Resolved the same way the applet resolves it (GLib ignores a relative value),
# so both agree on where the autostart entry and the server file live.
case "${XDG_CONFIG_HOME:-}" in
  /*) CONFIG_HOME="$XDG_CONFIG_HOME" ;;
  *)  CONFIG_HOME="$HOME/.config" ;;
esac
AUTOSTART_DIR="$CONFIG_HOME/autostart"

mkdir -p "$APPS_DIR" "$ICON_DIR" "$BIN_DIR"

if [ "$LINK_MODE" -eq 1 ] || [ "$SRC_DIR" = "$APP_DIR" ]; then
  # Run in place. asuvpn-tray finds asuvpn-helper next to itself, so the two
  # only ever have to stay together.
  INSTALL_DIR="$SRC_DIR"
  # The earlier copy is removed at the very end, once everything that can fail
  # has succeeded. Deleting first meant a read-only checkout aborted on the
  # chmod below and left no working install at all.
  #
  # Containment, not inequality: with the checkout *inside* $APP_DIR — say
  # ~/.local/share/asuvpn/checkout — an exact `!=` test passes and the rm -rf
  # then deletes the checkout itself, after printing that the install succeeded.
  case "$SRC_DIR" in
    "$APP_DIR" | "$APP_DIR"/*) REMOVE_STALE_COPY=0 ;;
    *) REMOVE_STALE_COPY=1 ;;
  esac
else
  INSTALL_DIR="$APP_DIR"
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$SRC_DIR/asuvpn-tray" "$SRC_DIR/asuvpn-helper" \
                  "$SRC_DIR/asuvpn-notify" "$SRC_DIR/asuvpn-selftest" "$INSTALL_DIR/"
  # Not executable: it is loaded, not run. Every program reads it by explicit
  # path, so it has to sit beside them. The icon is deliberately not copied
  # here — every consumer resolves the theme name against the hicolor copy
  # installed below, and a second copy beside the programs was read by nothing.
  install -m 0644 "$SRC_DIR/asuvpn_contract.py" "$INSTALL_DIR/"
  # Earlier installs copied the icon here too. Nothing ever read that copy,
  # so an upgrade removes it. Copy mode only: in --link mode this directory
  # is the checkout, where asuvpn.svg is the real source file.
  rm -f "$INSTALL_DIR/asuvpn.svg"
fi

TRAY="$INSTALL_DIR/asuvpn-tray"
# Already 0755 in copy mode; in --link mode the checkout may be read-only, and
# a failure here must not be fatal now that the files are otherwise in place.
chmod +x "$TRAY" "$INSTALL_DIR/asuvpn-helper" "$INSTALL_DIR/asuvpn-notify" \
         "$INSTALL_DIR/asuvpn-selftest" 2>/dev/null || true

# The helper and the notify script are executed as root. The helper refuses to
# run if either is group- or world-writable, so make sure they are not: a stray
# umask or an unpacked archive can easily leave 0775 behind. go-w only — in
# --link mode this directory is the user's own checkout, and an earlier
# unconditional 0755 here silently widened a deliberately private 0700.
chmod go-w "$INSTALL_DIR" "$TRAY" "$INSTALL_DIR/asuvpn-helper" \
           "$INSTALL_DIR/asuvpn-notify" "$INSTALL_DIR/asuvpn-selftest" \
           "$INSTALL_DIR/asuvpn_contract.py" 2>/dev/null || true
install -m 0644 "$SRC_DIR/asuvpn.svg" "$ICON_DIR/asuvpn.svg"

# `asuvpn` is a symlink to the same script, not a separate program.
ln -sfn "$TRAY" "$BIN_DIR/asuvpn"

# One config file, generated from the contract's own schema so the file is the
# reference for what can be changed. Created complete the first time; after
# that only the server line is touched, because the rest belongs to the user.
CONFIG_DIR="$CONFIG_HOME/asuvpn"
CONFIG_FILE="$CONFIG_DIR/asuvpn.conf"
mkdir -p "$CONFIG_DIR"
chmod 0700 "$CONFIG_DIR"
# `-s` and a settings line, not just `-f`. The redirection in the else branch
# used to truncate the file before asuvpn-tray ran, so a --write-config that
# failed for any reason -- a broken system python3, a payload left
# non-executable by --link -- left a zero-byte config that every later run
# then took the edit branch on, appending one `server =` line to nothing and
# reporting success. The write below is staged through a scratch file now, so
# that state cannot be created again; this test is what recovers a machine
# that already has one. A file with real settings in it is the user's and is
# only ever edited, never replaced.
if [ -s "$CONFIG_FILE" ] && grep -q '=' "$CONFIG_FILE"; then
  # awk with the value passed as data, never interpolated into an expression:
  # `--server 'x|w /etc/passwd'` was an arbitrary file write once already.
  # END appends when no server line exists — a half-written file from an
  # interrupted first install used to swallow --server silently, forever —
  # and the mv is a separate command so set -e catches an awk failure
  # instead of skipping the mv and reporting success. The scratch name
  # carries this pid because the applet and the CLI write the same file with
  # their own scratches; umask 077 births it 0600 instead of fixing the mode
  # after the content is already on disk.
  ( umask 077; awk -v line="server = $SERVER" \
    '{ split($0, f, "#"); split(f[1], kv, "="); k=kv[1]; gsub(/^[ \t]+|[ \t]+$/, "", k)
       if (k == "server") { print line; found=1 } else { print } }
     END { if (!found) print line }' \
    "$CONFIG_FILE" > "$CONFIG_FILE.$$.tmp" )
  mv "$CONFIG_FILE.$$.tmp" "$CONFIG_FILE"
else
  ( umask 077; "$INSTALL_DIR/asuvpn-tray" --write-config "$SERVER" \
      > "$CONFIG_FILE.$$.tmp" )
  mv "$CONFIG_FILE.$$.tmp" "$CONFIG_FILE"
fi
chmod 0600 "$CONFIG_FILE"

# Superseded by the file above; left behind they would be two sources of truth.
rm -f "$CONFIG_DIR/server" "$CONFIG_DIR/autoreconnect"

# The session log records the address the VPN assigned you, the routes it
# installed and the DNS servers it used. None of that belongs to other accounts
# on the machine, and it was previously created 0644 by default umask.
case "${XDG_CACHE_HOME:-}" in /*) CACHE_DIR="$XDG_CACHE_HOME/asuvpn" ;; *) CACHE_DIR="$HOME/.cache/asuvpn" ;; esac
mkdir -p "$CACHE_DIR"
chmod 0700 "$CACHE_DIR"
[ -f "$CACHE_DIR/session.log" ] && chmod 0600 "$CACHE_DIR/session.log"

# StartupNotify is off deliberately: this app has no window, so GNOME would sit
# on a launch spinner until it timed out.
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=ASU VPN
GenericName=VPN Client
Comment=Connect to the ASU SSL VPN ($SERVER)
Exec="$TRAY" --server $SERVER connect
Icon=asuvpn
Terminal=false
Categories=Network;
Keywords=VPN;ASU;OpenConnect;SSO;
StartupNotify=false
SingleMainWindow=true
Actions=Disconnect;Reconnect;

[Desktop Action Disconnect]
Name=Disconnect
Exec="$TRAY" --server $SERVER disconnect

[Desktop Action Reconnect]
Name=Reconnect
Exec="$TRAY" --server $SERVER reconnect
EOF
chmod 0644 "$DESKTOP_FILE"

# Safe now: everything that could fail has succeeded.
if [ "$REMOVE_STALE_COPY" -eq 1 ] && [ -d "$APP_DIR" ]; then
  echo "removing the previous copy in $APP_DIR"
  rm -rf "$APP_DIR"
fi

# An autostart entry written earlier has the old path frozen into its Exec line.
# Rewritten with awk passing the value as data, not interpolated into a sed
# expression: `--server 'x|w /etc/passwd'` was an arbitrary file write, and GNU
# sed's `e` command made it arbitrary command execution. A checkout path
# containing & or | corrupted the line silently for the same reason.
AUTOSTART_FILE="$AUTOSTART_DIR/asuvpn-tray.desktop"
if [ -f "$AUTOSTART_FILE" ]; then
  # Two commands, not an && list: under set -e an awk failure in an && list
  # is exempt, so the mv was skipped and the "repointed" line below lied.
  awk -v line="Exec=\"$TRAY\" --server $SERVER tray" \
    '/^Exec=/ { print line; next } { print }' \
    "$AUTOSTART_FILE" > "$AUTOSTART_FILE.tmp"
  mv "$AUTOSTART_FILE.tmp" "$AUTOSTART_FILE"
  echo "  autostart entry repointed at $TRAY"
fi

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" || true
command -v gtk-update-icon-cache >/dev/null &&
  gtk-update-icon-cache -f -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true

echo "Installed:"
# No mode claim here: the go-w above is allowed to fail on a read-only
# checkout, and the self-check below is what actually verifies writability.
echo "  program   $INSTALL_DIR"
echo "  launcher  $DESKTOP_FILE"
echo "  icon      $ICON_DIR/asuvpn.svg"
echo "  command   $BIN_DIR/asuvpn"
echo "  settings  $CONFIG_FILE  (0600, server = $SERVER)"
echo "  log       $CACHE_DIR/session.log  (0600)"
[ "$INSTALL_DIR" = "$SRC_DIR" ] &&
  echo "  (running from this checkout; do not move or delete it)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo; echo "note: $BIN_DIR is not on your PATH; add it to use the asuvpn command." ;;
esac

# Check what was just installed against this machine, now rather than at the
# first connect. The logic and wiring tiers need nothing but the files; the
# environment tier is what catches a missing openconnect, absent GTK bindings,
# or a vpnc-script this distribution keeps somewhere else. Advisory on purpose:
# installing before ./bootstrap.sh has run is a legitimate order to do this in,
# and the report says what is still missing.
if [ -x "$INSTALL_DIR/asuvpn-selftest" ]; then
  echo
  if "$INSTALL_DIR/asuvpn-selftest" --quiet; then
    echo "self-check passed"
  else
    echo "self-check found problems; run 'asuvpn selftest' for the full report." >&2
  fi
fi
