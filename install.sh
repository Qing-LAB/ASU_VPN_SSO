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
APP_DIR="$HOME/.local/share/asuvpn"
APPS_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
BIN_DIR="$HOME/.local/bin"
DESKTOP_FILE="$APPS_DIR/asuvpn.desktop"
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
                  "$SRC_DIR/asuvpn-notify" "$INSTALL_DIR/"
  install -m 0644 "$SRC_DIR/asuvpn.svg" "$INSTALL_DIR/"
fi

TRAY="$INSTALL_DIR/asuvpn-tray"
# Already 0755 in copy mode; in --link mode the checkout may be read-only, and
# a failure here must not be fatal now that the files are otherwise in place.
chmod +x "$TRAY" "$INSTALL_DIR/asuvpn-helper" "$INSTALL_DIR/asuvpn-notify" 2>/dev/null || true

# The helper and the notify script are executed as root. The helper refuses to
# run if either is group- or world-writable, so make sure they are not: a stray
# umask or an unpacked archive can easily leave 0775 behind.
chmod 0755 "$INSTALL_DIR" 2>/dev/null || true
chmod go-w "$INSTALL_DIR" "$TRAY" "$INSTALL_DIR/asuvpn-helper" \
           "$INSTALL_DIR/asuvpn-notify" 2>/dev/null || true
install -m 0644 "$SRC_DIR/asuvpn.svg" "$ICON_DIR/asuvpn.svg"

# `asuvpn` is a symlink to the same script, not a separate program.
ln -sfn "$TRAY" "$BIN_DIR/asuvpn"

# The launcher carries the server on its Exec line, but the bare `asuvpn`
# command has no such context. Record it so both agree on the endpoint.
CONFIG_DIR="$CONFIG_HOME/asuvpn"
mkdir -p "$CONFIG_DIR"
chmod 0700 "$CONFIG_DIR"
printf '%s\n' "$SERVER" > "$CONFIG_DIR/server"
chmod 0600 "$CONFIG_DIR/server"

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
  awk -v line="Exec=\"$TRAY\" --server $SERVER tray" \
    '/^Exec=/ { print line; next } { print }' \
    "$AUTOSTART_FILE" > "$AUTOSTART_FILE.tmp" &&
    mv "$AUTOSTART_FILE.tmp" "$AUTOSTART_FILE"
  echo "  autostart entry repointed at $TRAY"
fi

command -v update-desktop-database >/dev/null && update-desktop-database "$APPS_DIR" || true
command -v gtk-update-icon-cache >/dev/null &&
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

echo "Installed:"
echo "  program   $INSTALL_DIR  (0755, not group-writable)"
echo "  launcher  $DESKTOP_FILE"
echo "  icon      $ICON_DIR/asuvpn.svg"
echo "  command   $BIN_DIR/asuvpn"
echo "  server    $SERVER  ($CONFIG_DIR/server, 0600)"
echo "  log       $CACHE_DIR/session.log  (0600)"
[ "$INSTALL_DIR" = "$SRC_DIR" ] &&
  echo "  (running from this checkout; do not move or delete it)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo; echo "note: $BIN_DIR is not on your PATH; add it to use the asuvpn command." ;;
esac
