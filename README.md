# ASU VPN SSO

[![checks](https://github.com/Qing-LAB/ASU_VPN_SSO/actions/workflows/checks.yml/badge.svg)](https://github.com/Qing-LAB/ASU_VPN_SSO/actions/workflows/checks.yml)
[![scenarios](https://github.com/Qing-LAB/ASU_VPN_SSO/actions/workflows/scenarios.yml/badge.svg)](https://github.com/Qing-LAB/ASU_VPN_SSO/actions/workflows/scenarios.yml)

**Click-to-connect for the ASU VPN on Linux.** A GNOME panel applet and an
`asuvpn` command line client for Arizona State University's SSL VPN
(`sslvpn.asu.edu`), wrapping [`openconnect`](https://www.infradead.org/openconnect/)
and [`openconnect-sso`](https://github.com/vlaci/openconnect-sso).

## Why

ASU's VPN uses Cisco AnyConnect with SAML single sign-on and Duo. There is no
official Linux client, so the practical route is `openconnect-sso` — which works
well, but is a foreground terminal program. It wants a terminal for its prompts
and for `sudo`, it dies with the shell you started it in, and if it is stopped
the wrong way it can leave your routing table and DNS in pieces, with no network
until you reboot or bounce the interface.

This turns that into something you click. Launch it, finish the ASU sign-in in
the browser window that appears, and the tunnel stays up in the background with
an icon in the notification area for disconnect, reconnect and the log.
Everything the icon does is also available from the command line, so it scripts
as well as it clicks.

It also fixes something the usual setup gets quietly wrong. A split tunnel
needs split DNS — ASU's names resolved by ASU's resolver, every other name left
on the resolver you already had — and the stock `vpnc-script` cannot arrange
that on a machine running `systemd-resolved`, which is to say on Ubuntu. It
writes the VPN's resolver into `/etc/resolv.conf`, a file `systemd-resolved`
owns and rewrites at the next network change, and internal names quietly stop
resolving while the tunnel still looks perfectly healthy — `ssh` to a machine
you were on ten minutes ago just hangs. This applet configures the resolver on
the tunnel's own link instead, correctly scoped and nobody else's to overwrite,
and the watchdog checks every twenty seconds that it is still there. See
[DNS, and why it is not written to `/etc/resolv.conf`](#dns-and-why-it-is-not-written-to-etcresolvconf).

Most of the engineering here is in the part nobody enjoys: making sure that
however the tunnel ends — you disconnect, you log out, the applet crashes, the
helper is killed — `openconnect` still gets to put your routes and DNS back.

## Who it is for

Built and tested for **ASU on Ubuntu/Debian with GNOME**. If that is you, the
[Quick start](#quick-start) should be the whole story.

Outside that, treat it as a starting point rather than a supported
configuration:

- **Another university or company VPN.** Anything that `openconnect-sso` can
  sign in to should work — pass `--server your.vpn.edu`. Untested beyond ASU.
- **Another desktop.** The tray icon needs a StatusNotifier host. KDE has one
  built in; GNOME needs the AppIndicator extension, which `bootstrap.sh`
  installs. Untested outside GNOME.
- **Another distribution.** Honestly: **only Ubuntu/Debian is tested end to
  end**, and only there does anyone run the tray, connect a tunnel and tear it
  down. What *is* checked on Fedora, Arch, Debian and Ubuntu 22.04 on every
  push is the portable half — the contract, the state machine and the split-DNS
  rules, which are pure Python and need no desktop. That has already earned its
  keep: its first run found a Python 3.12-only construct that made the shipped
  self-check unparseable on Ubuntu 22.04 and Debian 12, both of which this
  project claims to support.

  Everything above that line — GTK, the tray icon, `openconnect`, `pkexec` —
  is unverified outside Ubuntu/Debian. It is expected to work, since none of it
  is Debian-specific, but expected is not tested. **If you run Fedora, Arch or
  openSUSE and it works, or does not, please open an issue or a PR** — a report
  from someone with the machine is worth more than any amount of guessing here,
  and the package names below were written from each distribution's index
  rather than from experience.

  `bootstrap.sh` checks what is *present* rather than
  which Linux you are on, so a machine that already has GTK, `polkit` and
  `openconnect` installs with no packages and no password at all. Where
  something is missing it names the gap and the packages that fill it for
  `dnf`, `pacman` or `zypper`, and installs none of them: only the apt path is
  exercised in CI, and running a guessed package name through `sudo` on someone
  else's machine is worse than a list they can read first.

  It does not stop there, though. Everything after that point is your own half
  — `~/.local`, no root, no distribution knowledge — so it carries on and
  installs it, and one run leaves you with `asuvpn` and `asuvpn selftest` even
  where the packages are missing. Run the self-check: it inspects *this*
  machine and is a better list than anything printed by a script that has not
  looked at it. Install what it names with your own package manager; nothing
  needs re-running afterwards. The applet itself is plain Python and GTK 3.

> [!NOTE]
> On a machine that is missing them, `bootstrap.sh` installs around thirty apt
> packages including a build toolchain, compiles `lxml` from source, may add the
> deadsnakes PPA for Python 3.12, and enables a GNOME extension. It checks first
> and installs only what is absent — on a desktop that already has everything it
> asks for no password — but read [Requirements](#requirements) first if any of
> that matters to you.

---

**Contents**

- [Quick start](#quick-start)
- [Using it](#using-it)
- [Settings](#settings)
- [The command line](#the-command-line)
- [What gets installed, and where](#what-gets-installed-and-where)
- [Removing it](#removing-it)
- [Security](#security)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Design notes](#design-notes)
- [Status](#status)
- [License](#license)

---

## Quick start

```bash
git clone https://github.com/Qing-LAB/ASU_VPN_SSO.git
cd ASU_VPN_SSO
./bootstrap.sh
```

`bootstrap.sh` installs whatever is missing, installs the app into `~/.local`,
and registers the launcher. It is safe to re-run: nothing already satisfied is
reinstalled. It runs `sudo apt-get update` on every run that has dependencies
enabled (stale package lists otherwise cause packages to be silently skipped),
so it asks for `sudo` each time; `--no-deps` skips that entirely. It asks
before adding the deadsnakes PPA (see [Requirements](#requirements) for why
Python 3.12 is needed).

| Flag | Effect |
| --- | --- |
| `--server HOST` | The endpoint for both the launcher and the `asuvpn` command (default `sslvpn.asu.edu`) |
| `--yes` | Never prompt, including for the PPA |
| `--no-deps` | Skip system packages, just install and register the app |
| `--link` | Run from the checkout instead of copying into `~/.local` |

One-time step if you have never signed in with `openconnect-sso` on this machine
— it needs to save your password to the login keyring, and the applet will not
guess a blank one:

```bash
openconnect-sso --server sslvpn.asu.edu --authenticate=shell
```

`--authenticate=shell` matters: without it, `openconnect-sso` goes on to run
`sudo openconnect` itself and leaves a foreground tunnel you have to Ctrl-C.

### From PyPI instead

The same app is on PyPI as a delivery channel. The package is not a second
installer — it carries this repository's programs **and both of its shell
scripts**, and its two commands just run them, so a PyPI install and a checkout
install put the same files in the same places and end with the same self-check.

On Ubuntu or Debian, the whole thing:

```bash
pipx install asuvpn
asuvpn-bootstrap                # system packages, then the app. Uses sudo.
```

`asuvpn-bootstrap` is `bootstrap.sh` — the same apt packages, the same
`openconnect-sso` on Python 3.12, the same GNOME extension — and it finishes by
running the user-half install itself, so that is the only command you need.

If you would rather handle the system half yourself, or you are not on apt:

```bash
pipx install asuvpn
asuvpn-install                  # user half only; accepts install.sh's flags
```

That writes nothing outside `$HOME` and asks for no privileges. What it cannot
do is the part no wheel can carry — the GTK bindings, `openconnect`, `pkexec`,
the GNOME tray extension are apt packages and a shell extension, not Python
distributions. On Ubuntu/Debian one line covers the minimum (this is a subset
of what `asuvpn-bootstrap` does, minus the Python 3.12 story in
[Requirements](#requirements)):

```bash
sudo apt install openconnect vpnc-scripts policykit-1 python3-gi \
  gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7
```

Either way, `asuvpn selftest` at the end says what is still missing rather than
leaving you to find out at the first connect.

Both commands install to your home directory and register the desktop launcher,
so **ASU VPN appears in the Activities overview and app grid** exactly as it
does from a checkout — see
[What gets installed, and where](#what-gets-installed-and-where) for the full
list of paths, including where the wheel itself lives.

Updating later is `pipx upgrade asuvpn && asuvpn-install` — both steps, because
what runs is the copy under `~/.local/share/asuvpn/`, not the wheel.

## Using it

Launching the app connects straight away:

1. A browser window opens for the ASU sign-in, Duo push included — that is
   `openconnect-sso` doing the login.
2. The system asks for **your own** password, in the same dialog software
   updates use (polkit). One step of building the tunnel — creating the
   virtual network device — needs administrator rights, and this dialog is
   how a desktop app asks for them (a terminal `sudo` prompt would have
   nowhere to appear). You are asked once per connect, and never to
   disconnect.
3. The tunnel stays up in the background.

End to end, a first connect looks like this: click **ASU VPN** → browser
window appears → sign in and approve the Duo push → browser closes →
password dialog → a **VPN connected** notification with the address you were
assigned. From then on, the panel icon is the whole interface.

### The panel icon

| Icon | State |
| --- | --- |
| Filled VPN badge | Connected |
| Dashed VPN badge | Disconnected |
| Acquiring badge | Signing in, connecting, retrying a lost link, not carrying traffic, or disconnecting — the status line says which |
| Error badge | Something failed |

The menu shows only what applies to the current state: **Connect** when down,
**Disconnect** and **Reconnect** when up, and **Cancel** while signing in or
connecting. While the applet is waiting to retry a connection that dropped,
**Stop reconnecting** appears — it calls the retries off without changing any
setting. Nothing can be cancelled during teardown, which must not be
interrupted. **Show log…** opens a live log window, and **Quit** closes the
tunnel first. The bottom of the menu names the running build — the same
answer `asuvpn --version` gives, and the applet logs it once at startup.

**Start on login (applet only)** puts the icon in your tray at login without
connecting — so you are not met with a Duo push before you have asked for one.

### What it tells you, and when

A badge quietly changing to a spinner is easy to miss, so every transition that
matters raises a desktop notification:

| Notification | When | Costs you |
| --- | --- | --- |
| **VPN connected** | the tunnel came up for the first time | — |
| **VPN connection lost** | `openconnect` lost the link and is re-establishing it | nothing — same session, no sign-in |
| **VPN reconnected** | it came back, possibly on a new address | — |
| **VPN not carrying traffic** | the watchdog's free re-establish did not help, or could not be tried | — |
| **VPN reconnecting** | `openconnect` was nudged to rebuild the tunnel | nothing — same session |
| **VPN carrying traffic again** | the tunnel recovered | — |
| **VPN signing in again** | the free fix did not help — or the tunnel died outright and is being rebuilt — and automatic reconnection is on | **a Duo push and a password** |
| **VPN still not connected** | automatic reconnection gave up after three attempts; it will wait to be asked | — |
| **VPN disconnected** | the tunnel closed, with the reason if it was not you | — |
| **Sign-in failed** | the sign-in step itself failed; the text says why | — |
| **VPN warning** | the helper hit trouble — most seriously, the network may not have been restored after teardown | — |
| **Cannot start** | `openconnect-sso` is not installed, so there is nothing to sign in with | — |

The distinction the wording carries is deliberate: *connection lost* and
*reconnecting* are free and need nothing from you, while *signing in again* is
the one that will interrupt you.

Right-clicking the app icon in the dash also offers Disconnect and Reconnect.

### Settings

One file, `~/.config/asuvpn/asuvpn.conf`, generated by `install.sh` from the
schema itself — so the file you get is the reference for what can be changed,
with every setting listed at its default and a sentence saying what it does:

```
# Seconds between dead-peer probes, forced on because some servers
# negotiate detection off and then a dropped tunnel looks connected. 0
# leaves the server's choice alone.
dpd = 30
```

Most of it takes effect without reconnecting: the built-in health checker
(the "watchdog" below) re-reads the file on every check, so changing
`health-interval`, `probe`, `probe-target` or the rate limits applies within
seconds. `dpd`, `dns` and `dns-domains` reach `openconnect` and its script on
the command line, so those three need a reconnect. A malformed line costs that setting its default
and logs a sentence saying so — a config file is never a reason to be unable to
connect.

| Setting | Default | What it decides |
| --- | --- | --- |
| `server` | `sslvpn.asu.edu` | The endpoint. Set by `install.sh --server`. |
| `autoreconnect` | `on` | Let the applet sign in again by itself — both when a stalled tunnel cannot be freed and when one has died outright. It is always the last thing tried, never the first, and it costs a Duo push and a password when it fires. |
| `dpd` | `30` | Dead-peer probe interval, forced on. **`0` leaves the server's choice alone** — the escape hatch if forcing it ever misbehaves. |
| `dns` | `on` | Put the resolver the VPN pushes on the tunnel's own link, through `systemd-resolved`, instead of letting `vpnc-script` rewrite `/etc/resolv.conf`. This is what makes internal names resolve *and keep resolving*. See [DNS, and why it is not written to `/etc/resolv.conf`](#dns-and-why-it-is-not-written-to-etcresolvconf). |
| `dns-domains` | *(empty)* | Which names to resolve through the tunnel when the gateway names none itself. Empty derives one from `server` — `sslvpn.asu.edu` gives `asu.edu`. What the gateway pushes always wins over both. |
| `health-interval` | `20` | Seconds between checks. **`0` turns the watchdog off** — the config file is still re-read at the default cadence, so turning it back on needs no restart. |
| `health-strikes` | `2` | Consecutive bad checks before the badge stops claiming Connected. |
| `probe` | `on` | Ask the network whether traffic still flows. The only check that catches a tunnel that looks perfect and delivers nothing. |
| `probe-target` | *(empty)* | Address to probe. Empty means the resolver the VPN itself pushed. |
| `probe-port`, `probe-every`, `probe-timeout` | `53`, `3`, `5` | Port (1–65535; 0 would blind the probe and is refused), how often, how long to wait (the wait is capped at 120). |
| `nudge-min-gap` | `120` | Seconds between free re-establish requests — the recovery that costs you nothing. |
| `autoreconnect-min-gap` | `300` | Seconds between unattended sign-ins. One budget, shared by both kinds, so they cannot add up to more than you allowed. |
| `signin-timeout` | `300` | How long a sign-in may take before it is given up on. **No off switch** (60–3600 only): an unattended one must never be able to sit behind a browser window forever. |
| `teardown-timeout` | `75` | Seconds to wait for the helper. Must outlast its signal escalation, so values below 35 are refused and the default used. |
| `log-max-kb` | `4096` | Size the session log may reach before it is rotated. **`0` never rotates on size.** |
| `log-keep` | `3` | Rotated logs kept as `session.log.1`, `.2`, … Connecting rotates too, so this is also how many past sessions survive. `0` keeps none; capped at 99. |

`asuvpn autoreconnect on` edits the file in place, changing that one line and
leaving everything else — comments included — as you left it. Most settings
are re-read on every health check, so a change takes effect within seconds
rather than at the next connect.

#### If ASU's address ever changes

Nothing here is hardwired to `sslvpn.asu.edu` — it is only the default.
Three ways to point at a different endpoint, most permanent first:

```bash
./install.sh --server vpn.other.edu     # or bootstrap.sh --server …
```

or edit the `server = …` line in `~/.config/asuvpn/asuvpn.conf` (then
`asuvpn quit` and connect again — the endpoint is fixed for an applet's
lifetime), or for one run only:

```bash
asuvpn --server vpn.other.edu connect
```

A running applet always refuses a *different* server (exit code 4) rather
than quietly connecting somewhere you did not ask — so the switch is always
explicit: stop the old applet, start against the new address.

### The command line

`asuvpn` does the same things as the menu. If an applet is already running it
drives that one rather than starting a second.

```bash
asuvpn                  # same as: asuvpn connect
asuvpn connect          # sign in and bring the tunnel up
asuvpn status           # what state is it in
asuvpn disconnect       # close the tunnel (or call off a pending retry)
asuvpn reconnect        # sign in again and replace the tunnel
asuvpn log -f           # follow this session's log
asuvpn quit             # close the tunnel and stop the applet
asuvpn tray             # run the applet in the foreground, do not connect
asuvpn selftest         # check this installation against this machine
asuvpn autoreconnect    # show or set automatic reconnection: [on|off]
```

Every command prints the resulting state, so nothing happens silently.

By default `connect` returns as soon as the applet is running, while the sign-in
is still in progress — it does not tie up your terminal waiting for a Duo push.
Add `--wait` when the next thing you do depends on the tunnel actually being up:

```bash
asuvpn connect --wait && rsync -a ./data internal-host:/srv/
```

Exit codes are meant for scripting:

| Exit code | Meaning |
| --- | --- |
| `0` | The request was carried out — and for `status` or `--wait`, connected |
| `1` | `status` or `--wait`: not connected. `disconnect`: the tunnel did not close. `quit`: still shutting down. `log`: no log yet |
| `2` | A mis-typed command line (the standard Python argument-parsing code) |
| `3` | `status` — or a `--wait` the applet vanished under: it is not running |
| `4` | A different server was asked for than the running applet is using |

Actions report whether the action worked, so a successful `disconnect` exits 0.
Only `status` and `--wait` report connectedness. `asuvpn log` exits 1 when there
is no log yet.

A tunnel that fails reports `openconnect`'s own exit status, or `128 + n` if it
was killed by signal *n*. Codes in the twenties come from the helper refusing to
start before `openconnect` was ever run. Each one is reported to you as the
helper's own sentence rather than as the number — the helper marks those lines,
so this does not depend on how any of them happen to be worded:

| Code | The helper refused because |
| --- | --- |
| `20` | `openconnect` is not installed |
| `21` | no session cookie arrived on stdin |
| `22` | the interface name you passed could not name a device |
| `23` | that interface already exists, and it was not created by this session |
| `24` | no free `asuvpnN` name (a hundred tunnels is not a real scenario) |
| `25` | an option was passed that would detach `openconnect` from the helper |
| `26` | the helper, its directory, `asuvpn-notify` or the shared `asuvpn_contract.py` is writable by someone else, or owned by someone else |
| `27` | a negative dead-peer interval was passed |
| `28` | `--host` or `--fingerprint` was not one — a value that `openconnect` would read as an option rather than as a server |

```bash
asuvpn status >/dev/null || asuvpn connect --wait
```

Other options: `--server HOST` for a different endpoint, `--foreground` to
keep the applet attached to the terminal, `--version` to print the release
and wire-contract versions, and a bare `--` to pass extra arguments through
to `openconnect`. Flags may go before or after the command.

Arguments after `--` are checked for options that would detach `openconnect`
from its supervisor — `--background`, `--syslog`, `--pid-file` and friends are
refused, because a detached `openconnect` is a root process nothing can stop.
Bundled short options are refused too: `openconnect` reads `-bv` as `-b -v`,
so a bundle could smuggle in a refused option, and picking bundles apart
reliably would mean tracking its option table across releases. Write them
separately: `-i lo`, not `-ilo`.

```bash
asuvpn --server vpn.other.edu connect
asuvpn connect -- --script /path/to/vpnc-script
```

An applet only ever serves one server. Asking a running one for a different
endpoint is refused with exit code 4 rather than quietly connecting to the
wrong place; `asuvpn quit` first. This compares the endpoint actually in
use, so it also catches the case where `install.sh` was re-run with a new
`--server` while an applet was still up.

## What gets installed, and where

Everything lands in your home directory — the program under `~/.local`, your
settings under `~/.config/asuvpn`. Nothing is written outside `$HOME`, no
system files are touched, and no part of the installation needs root. The
program is **copied**, so the checkout can be moved or deleted afterwards.

| Path | What it is |
| --- | --- |
| `~/.local/share/asuvpn/` | `asuvpn-tray`, `asuvpn-helper`, `asuvpn-notify`, `asuvpn-selftest` (`0755`) and `asuvpn_contract.py` (`0644`) — nothing group-writable |
| `~/.local/share/applications/asuvpn.desktop` | Launcher, with Disconnect/Reconnect actions |
| `~/.local/share/icons/hicolor/scalable/apps/asuvpn.svg` | The app-grid icon |
| `~/.local/bin/asuvpn` | Symlink to the installed `asuvpn-tray` |
| `~/.config/asuvpn/asuvpn.conf` | Every setting, generated from the schema with each one documented (`0600` in a `0700` directory) |

The `.desktop` file is what puts **ASU VPN** in the Activities overview and app
grid. `install.sh` refreshes the desktop and icon caches, so it appears without
a logout.

Runtime state lives elsewhere, and is created on demand:

| Path | What it is |
| --- | --- |
| `~/.cache/asuvpn/session.log` | Session log (`0600` in a `0700` directory). Rotated — not wiped — on each connect and at `log-max-kb`; `log-keep` past logs survive as `session.log.1`, `.2`, … |
| `~/.config/autostart/asuvpn-tray.desktop` | Written only when you tick "Start on login (applet only)" |
| abstract socket `asuvpn-tray-$UID` | Single-instance guard and CLI channel; peer uid is checked, and it vanishes with the process |

Separately, `bootstrap.sh` installs system packages with `apt`, and installs
`openconnect-sso` into its own pipx venv under `~/.local/share/pipx/`.

**Installing from PyPI lands in exactly the same places.** `pipx install
asuvpn` only puts the wheel in a pipx venv of its own
(`~/.local/share/pipx/venvs/asuvpn/`); nothing there is the app. Running
`asuvpn-bootstrap` or `asuvpn-install` then copies the payload out to the same
`~/.local/share/asuvpn/` and writes the same launcher, icon, symlink and
settings file as the table above — because it is the same `install.sh`, shipped
inside the wheel. So **ASU VPN appears in the Activities overview and the app
grid either way**, with the same Disconnect and Reconnect entries on its
right-click menu, and the desktop and icon caches are refreshed the same way so
it shows up without a logout. Nothing about the desktop integration depends on
how the files arrived.

One consequence worth knowing: the copy under `~/.local/share/asuvpn/` is what
runs, not the one in the pipx venv, so `pipx upgrade asuvpn` alone changes
nothing — run `asuvpn-install` after it to copy the new version out. Forgetting
that half is silent by nature, so `asuvpn selftest` asks the question for you:
it compares the running copy against the version the installed package
carries, and says which command finishes the job.

### Running from the checkout instead

`--link` skips the copy and points the launcher at the checkout, so your edits
take effect immediately. The checkout then has to stay where it is.

```bash
./bootstrap.sh --link
```

## Removing it

```bash
asuvpn quit
rm -rf ~/.local/share/asuvpn ~/.cache/asuvpn ~/.config/asuvpn
rm -f  ~/.local/share/applications/asuvpn.desktop \
       ~/.local/share/icons/hicolor/scalable/apps/asuvpn.svg \
       ~/.local/bin/asuvpn \
       ~/.config/autostart/asuvpn-tray.desktop
update-desktop-database ~/.local/share/applications
```

That removes the app completely, however it was installed — those paths are
where it lives in both cases. If you installed from PyPI, `pipx uninstall
asuvpn` removes the delivery wheel as well; on its own it would leave the
installed copy above running, since that is a copy and not a link.

It deliberately leaves the things it did not own: `openconnect-sso`
(`pipx uninstall openconnect-sso`), the apt packages, the deadsnakes PPA, the
AppIndicator GNOME extension, your keyring entries, and any polkit rule you
added by hand.

## Security

The design assumes you would rather understand the privilege boundary than trust
it, so here it is in full.

### What runs as you

Nearly everything. The applet, the CLI, and the sign-in browser all run as your
normal user, with no elevation:

- reads `~/.config/openconnect-sso/config.toml`
- runs `openconnect-sso`, which opens the Qt browser window for ASU SSO and Duo
- reads your password **from the login keyring** — see below
- writes `~/.cache/asuvpn/session.log`
- writes `~/.config/autostart/…` only when you tick "Start on login (applet only)"
- opens a private control channel (an abstract Unix socket) for the
  single-instance guard and the CLI. That kind of channel has no file
  permissions of its own, so on every connection the applet asks the kernel
  who is calling (`SO_PEERCRED`) and refuses any user id but yours —
  otherwise another local user could drop your tunnel, read your assigned
  VPN address, or trigger `connect` to raise an admin password prompt on
  your desktop at will. Someone grabbing the channel's name first can only
  stop the applet starting (it reports "already running"); they cannot
  impersonate it, because the CLI checks the server's identity the same way
  the applet checks its callers

### What runs as root

Only the pieces that build the tunnel, and every one of them is reached
through the same door: `asuvpn-helper` runs via `pkexec` after you approve
the password dialog, it runs `openconnect`, and at each connection change
`openconnect` runs `asuvpn-notify`, which reports one status message and
hands over to the routing script. The helper's whole job is supervision:

1. runs `openconnect` with the session cookie fed on stdin, and stays alive as
   its supervisor for the life of the tunnel — it does not exec and step aside,
2. signals `openconnect` when asked — the free `SIGUSR2` re-establish nudge
   over the already-open control pipe, and shutdown when that pipe closes,
3. after exit, deletes a tunnel interface that outlived `openconnect` and reads
   the default route back, to confirm your network was restored.

It also opens a datagram socket for `asuvpn-notify` to report state on. That
lives in a `0700` directory under `/run` owned by root, so no other account can
reach it — and every message carries a per-session token, so two concurrent
sessions cannot be confused for one another.

Before doing any of that, the helper **refuses to run** if itself, its
directory, `asuvpn-notify` or `asuvpn_contract.py` is world-writable, writable
by a shared group, **or owned by anyone but you or root**. Permissions say who
may write a file *besides* its owner; an owner rewrites their own file whenever
they like, so ownership is part of the same question rather than a separate
one, and `install.sh --link` from a checkout somebody else owns is a documented
way to arrive there. That turns
the caveat below from something you have to remember into something enforced. A
user-private group is not treated as a finding: Debian and Ubuntu default to
umask 002, so an ordinary checkout is `0775` with `gid == uid` and the "group"
is one person.

The ownership half is asked *before* `asuvpn_contract.py` is executed, not
after. It used to be asked only in `main()`, which runs long after the module
has been imported — so a contract owned by another user was run as root and
refused afterwards. `sec.sh` case (e3) stages exactly that, with a payload, so
"refused" has to mean "did not run".

### What it never does

- **Never sees your password.** `openconnect-sso` reads it from the login
  keyring, and the polkit password goes to GNOME's authentication agent. Neither
  passes through this app. The pre-flight check asks the keyring only whether a
  password exists and receives back one of three literal strings — `ready`,
  `no-password` or `no-credentials` — never the password itself. Anything else
  is treated as unknown, and a probe that hangs is treated as a locked keyring
  and fails closed rather than let a blank answer become the saved password.
- **Never writes to the keyring.**
- **Never logs the session cookie**, and never puts it on a command line where
  `ps` could show it. It travels on a pipe from the sign-in, through the
  applet's memory, into the helper's stdin, and nowhere else — never a file,
  never a terminal, never `argv`.

  That much is structural, and it only covers the paths this project wrote. The
  log also carries `openconnect`'s own output verbatim, so as a second line of
  defence **every log line is redacted before it is written**: anything shaped
  like a session token — `COOKIE`, `webvpn`, `acSamlv2Token`, `sso-token`,
  `sessionid` — has its value replaced with `<redacted>`, while the key and the
  rest of the line survive so the log stays readable. This is why
  `asuvpn connect -- --dump-http-traffic`, which makes *openconnect* print the
  cookie header, no longer leaks it.
- **Never modifies system files or settings — at run time.** Installing the app
  is confined to `$HOME` and needs no root at all. `bootstrap.sh` is the sole
  exception, and only on the dependency pass: it runs `apt` under `sudo`, asks
  before adding the deadsnakes PPA, and enables the AppIndicator GNOME extension
  (a dconf setting in your own profile). `--no-deps` skips all of it.
- **Never leaves a privileged process behind.** See
  [the control pipe](#the-control-pipe).

### The password prompt, and why it is not cached

`pkexec` is polkit's equivalent of `sudo`. Ubuntu's default for
`org.freedesktop.policykit.exec` is `auth_admin`:

```xml
<allow_any>auth_admin</allow_any>
<allow_inactive>auth_admin</allow_inactive>
<allow_active>auth_admin</allow_active>
```

`auth_admin` does **not** cache, so you are asked once for every connect and
reconnect. You are never asked to disconnect, because closing the control pipe
requires no privileges at all.

### Making it prompt less

The keyring is not the mechanism here, and it is worth being clear why: `polkit`
authenticates through PAM against your account password. It never consults the
login keyring, so there is nothing to store there. What can cache is polkit's
own **temporary authorization** — `auth_admin_keep`, which retains an
authorization for a few minutes.

Two facts about how that works, both checkable on your own machine with
`pkaction --action-id org.freedesktop.policykit.exec --verbose`:

- `pkexec` runs **every** program under the single action id
  `org.freedesktop.policykit.exec`, whose implicit result is `auth_admin` for
  active, inactive and any.
- The program is passed as a *detail*, not as part of the action id. A rule can
  read it with `action.lookup("program")`, but the action being authorized is
  the same one every `pkexec` on the system uses.

An earlier version of this file concluded from that pair that any
`AUTH_ADMIN_KEEP` rule leaves `pkexec <anything>` passwordless. That is true of
an **unscoped** rule and overstated for a scoped one: polkit re-evaluates the
rules on every check and only consults a stored temporary authorization when the
current evaluation itself returns a `_KEEP` result, so a rule that returns
`auth_admin_keep` for one program and falls through for everything else does not
hand out a general exemption.

The reason not to do it anyway is simpler and does not depend on that detail:

> **The helper lives in your home directory, and you can write it.**

A rule keyed on that path caches an authorization for *whatever is at that path*.
Today the per-connect prompt means an attacker who has replaced the file still
has to wait for you to connect and approve it; with caching they can invoke it
themselves inside the retention window. `polkit.Result.YES` removes even the
waiting, permanently.

So the honest options are:

| Option | Prompt | Safe? |
| --- | --- | --- |
| As shipped | once per connect | yes — nothing to widen |
| Connect less often, stay connected | rarely | yes, and the session lasts weeks |
| `auth_admin_keep` scoped to the helper in `$HOME` | once per session | **no** — caches root for a file you can overwrite |
| Move the helper to root-owned storage first, then scope a rule to *that* path | once per session | yes — and it removes the caveat below as well |

The last row is the only way to get one password per session without giving
something up, because it fixes the underlying problem rather than working around
it. It costs the property that this app needs no root to install: the helper
would have to be placed outside `$HOME` by an administrator once. That is a
deliberate trade and is not done by default.

Note that a **drop already costs you nothing** — `openconnect` re-establishes
using the same session, and the applet's nudge goes down a pipe that is already
open, needing no privilege at all. Only a fresh connect prompts.

### Reporting a problem

Found something that crosses a privilege or user boundary? Please report it
privately rather than in an issue — [`SECURITY.md`](SECURITY.md) says how, what
is in scope, and what belongs upstream with `openconnect` instead. It also asks
you to keep real hostnames and addresses out of the report, for the same reason
none appear anywhere in this repository.

### Things worth knowing before you trust it

- **The helper lives in your home directory.** Anything able to write
  `~/.local/share/asuvpn/asuvpn-helper` runs as root at your next connect, when
  you approve the dialog. That is inherent to `pkexec`-ing a user-owned script.
  The helper runs under `python3 -I` so that its *directory* is not on
  `sys.path` — otherwise dropping a `signal.py` beside it would be enough, with
  no need to touch the helper itself.
- **`--` passes arguments straight to `openconnect`, as root.** `asuvpn connect
  -- --script /path/to/script` will run that script with root privileges. This
  is deliberate — it is how you supply a custom `vpnc-script` — but it is a real
  capability, not a cosmetic passthrough.
- **The applet trusts the fingerprint from `openconnect-sso`.** Certificate
  pinning is `openconnect`'s job, via the `--servercert` value produced during
  sign-in; this app passes it through unmodified.

## How it works

Connecting is split across a privilege boundary, which is the whole point of the
design:

```
  you ──▶ asuvpn-tray ──▶ openconnect-sso ──▶ browser window (ASU SSO + Duo)
              │                  │
              │                  └──▶ host + certificate fingerprint + cookie
              │
              └──▶ pkexec ──▶ asuvpn-helper (root) ──▶ openconnect ──▶ asuvpn0
                                    ▲
                          cookie on stdin, never on argv
```

- **`asuvpn-tray`** runs as you. It drives `openconnect-sso --authenticate=shell`,
  which performs the SAML/Duo login in a browser and prints back a host, a
  server certificate fingerprint, and a short-lived session cookie.
- **`asuvpn-helper`** runs as root under `pkexec`. It receives only the cookie,
  on stdin, and hands it to `openconnect`.

The browser never runs as root, and the cookie never appears in the log or on a
command line where `ps` would show it.

### Why pkexec instead of sudo

Run on its own, `openconnect-sso` finishes the browser login and then shells out
to `sudo openconnect …` itself — that is the terminal password prompt you get
when you run it by hand. Passing `--authenticate=shell` stops it one step
earlier: it prints the host, fingerprint and cookie and exits, never reaching
its sudo call.

The applet then makes the privileged call itself, with `pkexec`. That is not
cosmetic. A `.desktop` launcher has no terminal, so a `sudo` password prompt
would have nowhere to appear and the connect would just hang; `pkexec` asks
through the GNOME polkit dialog instead.

### Knowing whether it is connected

State comes from openconnect's **script contract**, not from matching its log
output. openconnect runs `vpnc-script` at every transition with the state in the
environment — `reason` is one of `pre-init`, `connect`, `disconnect`,
`attempt-reconnect`, `reconnect`, alongside `TUNDEV` and
`INTERNAL_IP4_ADDRESS`. That interface is documented, versioned and inherited
from vpnc; the log wording is neither.

[`asuvpn-notify`](asuvpn-notify) is installed as that script. It forwards one
datagram to the helper, configures the tunnel's DNS on the tunnel's own link,
and then `exec`s the real `vpnc-script`, so routing is configured exactly as it
would have been. DNS is the one thing it keeps — see
[DNS, and why it is not written to `/etc/resolv.conf`](#dns-and-why-it-is-not-written-to-etcresolvconf)
for why leaving it to the real script silently stops working on Ubuntu. If you
pass your own `--script`, it is chained rather than discarded.

Which script it chains to is **asked of `openconnect`**, not assumed:
`openconnect --version` reports its own compiled-in default, which is
`/usr/share/vpnc-scripts/vpnc-script` on Debian and Ubuntu but `/etc/vpnc/vpnc-script`
on Fedora and Arch, and anything at all in a source build. This matters because
passing `--script` *replaces* that default — chain to a path that is not there
and the tunnel comes up with no routes and no DNS, restores nothing on the way
out, and the tray reports "Connected" throughout. If the script cannot be found
or is not executable, the helper does not interpose at all: `openconnect` keeps
its own default and state falls back to reading its output. Losing state
precision is a fair trade; losing your routing table is not.

What `openconnect` reports, and what you see:

| `reason` | Badge |
| --- | --- |
| `pre-init` | nothing yet — the tunnel is not configured |
| `connect` | **Connected**, with the address it assigned you |
| `attempt-reconnect` | **Connecting… — link lost, retrying** |
| `reconnect` | **Connected**, with the new address if it changed |
| `disconnect` | left to the exit path, which knows whether you asked for it |

Three sources, in order of authority:

| Source | What it gives | When it is used |
| --- | --- | --- |
| Script contract | `reason`, device, assigned address | Always, when available |
| `/sys/class/net/<dev>/ifindex` | Proof the device is the one we created | Teardown ownership |
| Log patterns | Best guess | Fallback only, if no event arrives |

This is not hypothetical tidying. Matching on `Connected as …` — which
openconnect stopped saying in v8 — meant the applet could only ever reach
"Connected" when DTLS happened to negotiate. On a network blocking UDP/443 or
behind a proxy the tunnel worked while the tray sat in "Connecting…" forever.
The contract has no such failure mode, and it hands over the assigned address,
which the log patterns never reliably did.

### When the link drops

There are two different things called "reconnection" here, and they cost very
different amounts. This matters, because one of them is free and invisible and
the other interrupts you:

| | openconnect re-establishes | `asuvpn reconnect` |
| --- | --- | --- |
| Session cookie | **reuses** the existing one | fetches a new one |
| Your password | not asked | not asked — read from the keyring |
| **Duo / 2FA** | **no** | **yes** |
| **polkit password prompt** | **no** | **yes, typed** |
| Triggered by | dead peer detection, or a nudge | the menu, the CLI, the watchdog escalating |
| Good until | the session expires — openconnect logs the date | — |

`openconnect` handles the first kind itself and the applet follows rather than
interferes: it retries for `--reconnect-timeout` seconds (default 300) using the
same session cookie, so a WiFi toggle or moving between networks normally
recovers with no sign-in and no Duo push. It copes with your address changing
underneath it. Past the retry window, or once the session expires, a fresh
sign-in is needed and that is the expensive kind.

The tray shows the cheap kind as **Connecting… — link lost, retrying**, driven
by `attempt-reconnect` and `reconnect` events, so `asuvpn status` stops exiting 0
while traffic is going nowhere.

A concrete example, from a real session: close the laptop lid mid-tunnel and
reopen it a minute later. The forced dead-peer detection notices the gap, the badge
flips to *Connecting… — link lost, retrying*, and about eighteen seconds after
waking the tunnel is back on the same session — no browser, no Duo, no
password. The only trace is a notification pair: *VPN connection lost*, then
*VPN reconnected*.

#### Dead peer detection is forced on

That first mechanism only works if dead peer detection is running — the
periodic "are you still there?" exchange between the two ends of the tunnel —
and **ASU's server turns it off**. A real session logs:

```
CSTP connected. DPD 0, Keepalive 0
```

With `DPD 0` there are no probes and no keepalives, so `openconnect` has no way
to learn the far end stopped answering — it sits in a connected state
indefinitely while nothing flows. That is what a silent breakage is.

So the helper passes `--force-dpd 30`, which `openconnect` documents as using
DPD "even if the server hasn't requested it". Being wrong about the interval is
cheap: a DPD failure makes `openconnect` re-establish with the *same* cookie, so
an over-eager setting costs a brief reconnect, never a re-authentication. Pass
your own to override it:

```bash
asuvpn connect -- --force-dpd 60
```

### Watching the tunnel itself

Dead peer detection covers the far end going away. It cannot see the case where
the far end is fine but the tunnel has stopped being usable locally — a resume
from suspend, a network change, or another daemon rewriting the routing table.
Every layer still believes it is connected, which is why that failure is silent.

So the applet checks the tunnel every 20 seconds while it claims to be
connected, and acts after two consecutive bad checks. What it checks is
deliberately narrow, because **three of the four things one would check first
are wrong** — each was tried against a live ASU tunnel and each would have
raised a false alarm on a perfectly healthy link:

| Tempting check | Why it is wrong here |
| --- | --- |
| `operstate == "up"` | a tun device reports `unknown`, never `up` |
| `IFF_RUNNING` | not set on a tun device either |
| a default route through the tunnel | ASU is a **split tunnel** — the default route stays on your WiFi, and only the advertised prefixes are routed in |
| traffic is flowing | an idle tunnel moves no bytes at all |

What is left is what is true of every working tunnel and false of a broken one:
the device still exists, it is still the same device this session created (by
`ifindex`, not by name), it is still administratively up, and the routes that
make it useful are still installed. That last one is precisely what dead peer
detection cannot see.

Every one of those is a couple of reads from `/sys` and `/proc` — no packets and
no subprocess. But they all share a blind spot: a tunnel can have a healthy
device, correct routes, and still carry nothing. So every third cycle the applet
also **asks the network**.

The target is never hardcoded — by default it is the resolver the VPN itself
pushed (`INTERNAL_IP4_DNS`), forwarded through the same script contract
everything else uses. Whatever this tunnel says to resolve against is by
definition something that ought to answer through it. The `probe-target`
setting overrides that derivation if you know better for your network. A VPN
that pushes no resolver simply gets the device checks.

There is a third check, and it catches something the other two cannot: the
tunnel is up, the routes are installed, packets cross in both directions — and
internal names still resolve to whatever the public internet says, because the
resolver the VPN pushed is no longer configured on the tunnel's link. Every
20 seconds the applet asks `systemd-resolved` whether that resolver is still
in force — on the tunnel's link, or in `/etc/resolv.conf` if the handover fell
back to `vpnc-script`; either counts, because either works. It only reads;
putting it back needs root, and the free re-establish does exactly that by
running the script again. If `systemd-resolved` does not
answer — a machine that does not run it never had this configured — that is not
a verdict, and nothing is demoted over it.

This one is not hypothetical. It is the failure that prompted the whole
mechanism, and it ran for hours at a time looking perfectly healthy. See
[DNS, and why it is not written to `/etc/resolv.conf`](#dns-and-why-it-is-not-written-to-etcresolvconf).

The probe opens one TCP connection and closes it. **A refusal counts as
alive**, which is the part worth understanding: measured against a live ASU
tunnel, one pushed resolver accepted the connection in 29 ms and the other
answered "nothing is listening here" (a RST packet) in 20 ms — and the refusal
is just as good an answer, because it proves a packet crossed in each
direction. Only silence means the tunnel is not carrying traffic. Whether the
service behind the probe is up is none of our business.

The two sources are tracked separately, so a probe failure is only cleared by a
successful probe. Letting the device check promote the badge back would flap it
every twenty seconds against a tunnel that is genuinely carrying nothing. The
same rule holds against openconnect's own word: the reconnect a nudge produces
does not promote the badge either — the source that demoted has to pass again
first, which for the device checks is the very next check and for the probe is
at most one probe cycle (`probe-every` × `health-interval` seconds). Route
families are counted separately too, because `ip route flush` removes only
IPv4 and a summed count sat green through exactly that break on a live tunnel.

Every failing check and every recovery is logged with the facts attached, so
the next silent break leaves evidence instead of a mystery (a quietly healthy
tunnel logs nothing — a line every twenty seconds forever would bury the log).
A routes-lost incident reads like this:

```
[tray] tunnel device check 1/2: the tunnel's IPv4 routes are gone (dev=asuvpn0, ifindex=6, flags=0x1091, routes4=0, routes6=6)
[tray] tunnel device check 2/2: the tunnel's IPv4 routes are gone (dev=asuvpn0, ifindex=6, flags=0x1091, routes4=0, routes6=6)
[tray] the tunnel is not usable: the tunnel's IPv4 routes are gone
[tray] asked openconnect to re-establish (same session, no sign-in needed)
```

#### What it does about it

Two different things can go wrong, and they need different answers:

| What happened | What is left to work with | What the applet does |
| --- | --- | --- |
| The tunnel is **up but useless** — routes wiped, or a black hole | a live `openconnect`, a device, a session cookie | the ladder: nudge, then say so, then sign in again |
| The tunnel is **gone** — `openconnect` gave up and exited | nothing at all | rebuild it from scratch, up to three times |

##### When the tunnel is up but useless

Cheapest first, because the two recoveries are not interchangeable — one is
free and one costs you a Duo approval:

1. **Nudge it.** Send `openconnect` a `SIGUSR2`. It documents this as forcing
   "an immediate disconnection and reconnection", and it reuses the session
   cookie — so there is no sign-in, no Duo push and no password. You need not
   even be at the keyboard.

   One nudge per incident. If the tunnel is demoted again *after* its nudge,
   the nudge demonstrably did not fix it, and asking again every two minutes
   is what a routes-lost tunnel actually got before this rule.

2. **Say so.** The badge leaves *Connected*, so `asuvpn status` stops exiting
   0, and one notification explains what was seen. The menu still offers
   Disconnect and Reconnect, because the tunnel is established — just not
   usable.

3. **Sign in again.** On by default. By the time this step is reached the free
   option has been tried and the tunnel is *still* carrying nothing, so the
   only thing left is a fresh session. It costs a Duo approval and a password,
   so it happens at most once every five minutes.

Picking up where the log above left off — the nudge has been sent, and the
routes still have not come back:

```
[tray] tunnel device check 2/2: the tunnel's IPv4 routes are gone (dev=asuvpn0, routes4=0, routes6=6)
[tray] the tunnel is not usable: the tunnel's IPv4 routes are gone
[tray] the free re-establish was already tried for this incident and traffic did not return
[tray] signing in again to rebuild the tunnel
```

Every pass logs the decision it took *and* the reason, including the passes
that decide to do nothing — "holding the free re-establish for another 47s",
"automatic sign-in is off". A log that shows verdicts but never decisions
reads as a hang, which is exactly how the first live routes-lost break read.

##### When the tunnel is gone

`openconnect` retries on its own for five minutes and then gives up. Any
suspend, or any WiFi outage longer than that, ends this way. There is now no
tunnel to nudge and no device to watch, so the ladder above cannot help — the
applet signs in again from scratch instead.

```
[tray] connection dropped
[tray] rebuilding it shortly
[tray] rebuilding the dropped tunnel (attempt 1 of 3)
[tray] ---- reconnecting; the lines above say why ----
[tray] authenticating to sslvpn.asu.edu via /home/you/.local/bin/openconnect-sso
```

If the network never comes back, it stops — and says so rather than going
quiet:

```
[tray] the tunnel did not come back in 3 attempts; waiting to be asked
```

Four rules keep that from becoming a nuisance:

- **Only a tunnel that was working gets rebuilt.** If it never came up at all,
  something is wrong that a second attempt will not fix — a rejected cookie, a
  dismissed password prompt — and retrying just repeats the browser window and
  the Duo push.
- **Three attempts, then it stops** and says so once. A network that is down
  stays down; spacing the attempts out is not the same as bounding them.
- **What earns the attempts back is a session that lasted.** A tunnel that
  outlives the five-minute gap did not flap, so its next death starts with a
  fresh three. This is the difference between recovering all day from real
  outages and firing a Duo push every five minutes at a link that comes up and
  falls straight over.
- **Anything you do yourself takes over.** Connect, Cancel, or Disconnect —
  from the menu or the command line — calls off whatever was pending.

While a rebuild is owed, the badge says so and the menu offers **Stop
reconnecting**, which calls it off without touching your settings:

```console
$ asuvpn status
ASU VPN: Not connected (sslvpn.asu.edu) — connection dropped; rebuilding
$ asuvpn disconnect          # the same thing from the command line
ASU VPN: Disconnected (sslvpn.asu.edu)
```

##### Turning it off

```bash
asuvpn autoreconnect          # show the current setting
asuvpn autoreconnect off      # or use the menu checkbox
```

The menu item is **Reconnect automatically if traffic stops**. Off, the applet
stops at the diagnosis: the badge leaves *Connected*, the notification says
what was seen, and nothing asks you for a password until you pick Connect or
Reconnect yourself.

##### Two smaller guarantees

**A sign-in always ends.** `openconnect-sso` opens a browser window and waits
for a Duo approval. That is fine when you clicked Connect and are watching it;
it is not fine when the applet started it and nobody is there. `signin-timeout`
(five minutes, and there is deliberately no way to switch it off) ends one that
never finishes, so the applet cannot be left stuck in *Signing in…* behind a
login window nobody is looking at.

**An automatic reconnect does not wipe the log.** The lines explaining *why* it
happened are the only record of a break that was silent by definition. A
connect you asked for still starts a fresh log.

### DNS, and why it is not written to `/etc/resolv.conf`

A split tunnel wants split DNS. ASU routes only its own prefixes down the
tunnel and leaves everything else on your own connection; DNS should have the
same shape. Names that live behind the tunnel — internal hosts, licence
servers, a cluster login node — have to be resolved by ASU's resolver, and
every other name should stay on the resolver your machine already had.

**The stock `vpnc-script` cannot do that here, and fails in a way that looks
like nothing at all.** It decides how to install a resolver by grepping
`/etc/nsswitch.conf` for `resolve`. On Ubuntu that word is absent — the
`libnss-resolve` package is not installed by default, and `systemd-resolved` is
reached through its stub listener at `127.0.0.53` instead. The grep fails, the
script concludes there is no resolver manager to talk to, and falls all the way
through its chain to the generic branch, which writes the VPN's resolver
straight into `/etc/resolv.conf`.

That file is a symlink to `/run/systemd/resolve/stub-resolv.conf`, which
belongs to `systemd-resolved`. The write lands, DNS works — and then
`systemd-resolved` rewrites its own file at the next link change and the VPN's
resolver is silently gone. The tunnel is still up. The routes are still
installed. Traffic still crosses. An internal hostname resolves to whatever
the public internet says — for a name fronted by a CDN, that is the CDN's edge,
which answers nothing you were asking for — and reconnecting the VPN is the
only thing that fixes it, until the next rewrite.

So this applet configures DNS itself, on the tunnel's own link, through
`systemd-resolved`'s own interface:

```
resolvectl default-route asuvpn0 no        # this link is not for every name
resolvectl domain        asuvpn0 asu.edu   # these names, though, are its own
resolvectl dns           asuvpn0 192.0.2.53
```

Three properties come out of that, and none of them is available from a global
resolver list:

- **It is scoped.** A domain listed on a link both completes single-label names
  and routes matching queries there, so `asu.edu` goes to ASU and nothing else
  does. `/etc/resolv.conf` is one flat list and cannot express this at all — the
  reason the obvious fix (installing `libnss-resolve` so the stock script takes
  its `systemd-resolved` branch) is still the worse answer: that branch sets no
  routing domain unless the gateway pushes one, and a link with servers and no
  domains becomes a candidate for **every** lookup on the machine.
- **It has the right lifetime.** Link configuration dies with the link. No
  backup file, no restore step, and nothing to lose a race with.
- **Nobody else owns it.** `systemd-resolved` rewriting its stub file cannot
  disturb per-link configuration, because that is where it keeps its own.

**Which names count as the tunnel's** is the gateway's call first:
`CISCO_DEF_DOMAIN` and `CISCO_SPLIT_DNS`, which `openconnect` passes to the
script, are it saying which names it serves. The `CISCO_` prefix is historical
and not a limitation — it comes from vpnc, and `openconnect` funnels every
protocol it speaks (AnyConnect, Juniper/Pulse, GlobalProtect, Fortinet, Array)
into those same two variables, so this works the same against any of them.

Only when the gateway names none does the local answer apply — the
`dns-domains` setting, or, left empty, the domain derived from the server
address (`sslvpn.asu.edu` → `asu.edu`). Nothing is hardcoded; point the applet
at a different VPN and it derives that one's domain instead.
If no domain can be worked out at all, the link takes every lookup rather than
none — never worse than the behaviour being replaced — and the log says so and
names the setting that would narrow it.

**The handover is total, and it fails safe.** The real `vpnc-script` guards
both its DNS branches on `INTERNAL_IP4_DNS` being set, so once the link is
configured that variable is removed from the environment the script inherits.
Routing is handed over untouched; DNS has exactly one owner. If any part of it
does not work — no `resolvectl`, `systemd-resolved` not running, a call that
fails — the variable stays, the link is reverted rather than left half
configured, and the stock script does whatever it would have done. Falling back
to the old behaviour beats half-configuring DNS.

Every connect logs what was done:

```
15:38:44  [vpn] asuvpn: DNS for asu.edu on asuvpn0 via 192.0.2.53 (pushed by the gateway); /etc/resolv.conf left alone
```

`dns = off` turns the whole thing off and gives `vpnc-script` its old job back.

### The control pipe

The helper keeps reading the same stdin pipe for the life of the tunnel. Closing
the pipe *is* the disconnect signal, which buys two things:

- **Disconnecting never asks for your password again.** The tray already holds
  the write end; it just closes it. No second privileged call is needed.
- **A crashed tray cannot strand the tunnel.** The helper sees EOF and tears
  `openconnect` down, instead of leaving a root process holding your routing
  table. This is verified by killing the applet with `SIGKILL` and checking that
  nothing survives.

The helper also relays `openconnect`'s output rather than handing it the tray's
pipe directly. That costs a thread, but it means a dead tray cannot hit
`openconnect` with `SIGPIPE` and kill it *before* it restores your routes and
DNS.

### Every way of stopping it

All of these end in the same graceful teardown: `openconnect` receives `SIGINT`
and gets 15 seconds to run `vpnc-script` before anything harsher is considered.

| How you stop it | What happens |
| --- | --- |
| Tray menu → **Disconnect** | The tray closes the control pipe, the helper signals `openconnect`, routes are restored. The applet stays running. |
| Tray menu → **Quit** | The same teardown, then the applet exits. |
| `asuvpn disconnect` / `asuvpn quit` | Routed to the applet over the control socket. Identical to the menu. |
| **Ctrl+C**, in `tray` or `--foreground` mode | The applet catches `SIGINT` and runs the orderly teardown. |
| **Closing the terminal** (`SIGHUP`) | Same as Ctrl+C. |
| **Logging out** (`SIGTERM`) | Same as Ctrl+C. |
| The applet **crashes** or is `kill -9`ed | The control pipe closes, the helper sees EOF and tears the tunnel down. Nothing is left holding your routes. |
| The **helper** itself dies (out of memory, `kill -9`) | The kernel itself notices — the helper registered for that (`PR_SET_PDEATHSIG`) — and signals `openconnect`, so the routing script still runs. |

> [!NOTE]
> `asuvpn connect` from a terminal puts the applet in its own session and
> returns. Ctrl+C afterwards does nothing, because the applet is no longer
> attached to your terminal — use `asuvpn disconnect`.

The helper is deliberately started in its **own session**, so a Ctrl+C aimed at
the applet does not also land on `openconnect`. That leaves exactly one teardown
path instead of two racing ones. An earlier version got this wrong: the terminal
signalled every process at once, two shutdowns ran concurrently, and the escalation
timer misread a healthy teardown as a hang and escalated to `SIGKILL` — which is
the one thing guaranteed to stop `vpnc-script` from restoring the routing table.

### Putting the network back

`openconnect` restores your routes and DNS by running `vpnc-script` with
`reason=disconnect` on the way out — but only when it exits *gracefully*. If it
is killed outright the script never runs, which is the classic way to end up
with no working network until you reboot or toggle the interface. Three things
guard against that:

- **Gentle escalation.** Teardown sends the polite stop signal (`SIGINT`),
  waits 15 seconds, sends the firmer one (`SIGTERM`), waits 10 more, and only
  then force-kills (`SIGKILL`). Both polite signals make `openconnect` run the
  cleanup script; the force-kill is the one thing that prevents it, which is
  why the waits are deliberately generous.
- **No broken-pipe deaths.** The helper relays `openconnect`'s output instead
  of wiring it straight to the applet, so an applet that vanished cannot make
  a write fail in a way that kills `openconnect` (`SIGPIPE`) before it has
  finished cleaning up.
- **A dead supervisor still triggers teardown.** The control pipe covers the
  tray dying; `PR_SET_PDEATHSIG` covers the helper dying. Without it, killing
  the helper left `openconnect` running as root with nothing able to reach it,
  while the tray cheerfully reported the connection as dropped. (In that path
  the kernel may deliver the signal twice, a millisecond apart; `openconnect`
  treats the second as a repeat of the same cancellation.)
- **A check afterwards.** After `openconnect` exits, the helper deletes the
  tunnel device if it outlived it — removing an interface takes its routes with
  it — then prints the restored default route, or a warning if there is none.
  Warnings also raise a desktop notification, so a broken teardown is visible
  instead of silent.

The tunnel device is named **`asuvpn0`** (or the first free `asuvpnN`) rather
than the usual `tun0`. That is
what makes the cleanup above safe: teardown can prove which interface is its own
instead of deleting anything that merely looks like a tunnel. Guessing by name
prefix would eventually delete a VM's `tap0` or a second VPN's `tun1` — as root,
while trying to *fix* your networking. Anything else that appeared meanwhile is
reported and left alone. Passing your own `--interface` through `--` overrides
the name, and teardown then tracks that one instead.

A healthy disconnect ends with a line like:

```
18:32:14  [helper] NOTE default route restored: default via 198.51.100.1 dev wlan0 proto dhcp metric 600
```

If instead you see `[helper] WARNING no default route after teardown — network
is likely broken` (the kind word carries no colon in the session log), the
recovery is:

```bash
nmcli networking off && nmcli networking on
```

### Why the sign-in needs its own browser window

`openconnect` can do SAML by itself, handing the login to your normal browser
with `--external-browser`. That would remove most of what `bootstrap.sh`
installs — Qt, PyQt6-WebEngine, the Python 3.12 they pin, the compiler that
builds `lxml`. It was measured, and **ASU's gateway refuses that method**: asked
for it alone it answers `error 108, does not support the requested
authentication type`, and only `single-sign-on-v2` — the embedded browser
`openconnect-sso` drives — is accepted. `asuvpn selftest` re-asks on every run,
so if that ever changes you will hear it from the self-check rather than from a
failed sign-in. [DESIGN.md](DESIGN.md#why-openconnect-sso-and-not-openconnects-own-external-browser)
has the detail.

### Two upstream quirks worth knowing

**The TOTP prompt.** `openconnect-sso` asks for a TOTP secret on the terminal
whenever its keyring entry is empty, which is every run for a Duo-push setup.
Launched from a desktop icon there is no terminal, so `getpass` hits `EOFError`
and the sign-in dies before the browser even opens. The applet answers that
prompt with a blank line, meaning "not required", and lets the browser handle
the second factor.

**The password prompt behind it.** The same code path asks for your *password*
first when the keyring has none, and a blank answer there would be silently
saved as your password. So the applet probes the keyring first and stops with
`no saved password` rather than guessing.

## Requirements

`bootstrap.sh` handles all of this. It is written down because the Python
version in particular is easy to get wrong.

### The applet

Runs on the **system** `python3` with GTK 3, Ayatana AppIndicator and libnotify
bindings:

```
python3-gi  gir1.2-gtk-3.0  gir1.2-ayatanaappindicator3-0.1  gir1.2-notify-0.7
```

It deliberately uses `/usr/bin/python3` in its shebang rather than whatever is
first on `PATH`, because a conda or pyenv install will shadow it and will not
have `gi`.

**Python 3.10 or newer** for the applet itself — the floor Ubuntu 22.04 sets,
and CI runs the portable half on 3.10, 3.11 and 3.12+ on every push so the
claim is tested rather than asserted. Note this is a *different* requirement
from the Python 3.12 `openconnect-sso` needs below: that one lives in its own
pipx venv and the applet never runs on it.

Also needed: `openconnect`, `pkexec`, and the GNOME AppIndicator extension
(`gnome-shell-ubuntu-extensions`) — without the extension GNOME has nowhere to
draw a tray icon.

### openconnect-sso needs Python 3.12

This is the fiddly part. `openconnect-sso` pins `lxml <5` and
`PyQt6-WebEngine <7`, and neither publishes wheels for Python 3.13+. Ubuntu
26.04 ships only 3.14, so 3.12 has to come from the deadsnakes PPA, and `lxml`
compiles from source, which needs a toolchain and headers:

```bash
sudo add-apt-repository ppa:deadsnakes/ppa
sudo apt install python3.12 python3.12-venv python3.12-dev \
                 build-essential libxml2-dev libxslt1-dev zlib1g-dev \
                 libffi-dev libssl-dev pkg-config
pipx install --python /usr/bin/python3.12 'openconnect-sso[full]'
pipx inject openconnect-sso 'setuptools<71' --force
```

Three details that are easy to miss:

- The **`[full]` extra** pulls in keyring support.
- The **`setuptools<71` pin** matters. `openconnect-sso` imports
  `pkg_resources` — in its sign-in browser process, to load the `user.js` it
  injects — and current setuptools no longer ships that module. Measured on
  this machine: setuptools `78.1.1` still has `pkg_resources`, `83.0.0` does
  not. So `<71` is a **known-good pin, not the exact boundary**; it is the
  bound that has been made to work end to end, which is why it is not relaxed.
- **`--force` on that inject is not optional.** `pipx` decides whether a
  package is already injected with a version-blind test — it asks only whether
  *some* `setuptools` is present, and one always is. Without `--force` it prints
  "already seems to be injected", installs nothing, and **still exits 0**, so
  the pin silently never applies and the venv keeps a `setuptools` that breaks
  sign-in at import. `asuvpn selftest` checks the pin by its effect, not by
  that exit status.

Qt6 WebEngine also dlopens a set of shared libraries for the sign-in window
(`libnss3`, `libxcomposite1`, `libxdamage1`, `libxrandr2`, `libxkbcommon-x11-0`,
`libxcb-cursor0`, `libgl1`, `libegl1`, `libxtst6`, `libdbus-1-3`, `fontconfig`).
`libxcb-cursor0` is the one people hit on X11 sessions.

## Troubleshooting

Start with the log, either from the menu's **Show log…** or:

```bash
asuvpn log -f
```

Every line has the same shape — a timestamp, a source tag, and (for helper
lines) a kind word. Knowing the tags makes the log greppable:

```
HH:MM:SS  [tray] …            the applet: decisions, checks, state changes
HH:MM:SS  [config] …          a problem in asuvpn.conf, reported once
HH:MM:SS  [sso] …             openconnect-sso's own output during sign-in
HH:MM:SS  [helper] NOTE …     the root helper, informational
HH:MM:SS  [helper] WARNING …  needs attention — most seriously, the network
                              may not have been restored
HH:MM:SS  [helper] FATAL …    refused before openconnect ever started
HH:MM:SS  [helper] STATE …    a transition from openconnect's script contract
HH:MM:SS  [helper] DEVICE …   the tunnel device this session will create
HH:MM:SS  [vpn] …             one line of openconnect's own output, relayed
HH:MM:SS  [old tunnel] …      a superseded helper's last words
```

The kind word is part of the line — grep for `WARNING` (no colon), not
`WARNING:`. A line like `[tray] ignoring 'check' while disconnecting` is the
applet declining a message that arrived too late to matter — normal during
teardown, and logged precisely so a declined action never reads as a hang.

| Symptom | Cause and fix |
| --- | --- |
| `no saved password` | The keyring has no password and the applet will not guess a blank one. Run `openconnect-sso --server sslvpn.asu.edu --authenticate=shell` once in a terminal. |
| `keyring did not answer` | The login keyring is locked, so the probe timed out rather than risk a blank answer being saved as your password. Unlock the keyring and connect again. |
| `authorization cancelled` | The polkit dialog was dismissed, or the password was wrong. Run `asuvpn connect` again. |
| No icon in the panel | `gnome-extensions enable ubuntu-appindicators@ubuntu.com` |
| `asuvpn: command not found` | `~/.local/bin` is not on your `PATH`. Add it, or run `pipx ensurepath` and open a new terminal. |
| The sign-in window never appears | That is `openconnect-sso`, not this applet. Run `openconnect-sso --server sslvpn.asu.edu --authenticate=shell` to see the real error. |
| `could not load the Qt platform plugin "xcb"` | Missing `libxcb-cursor0`. Re-run `./bootstrap.sh`. |
| Log stops at `signed in, starting openconnect` | The polkit dialog never appeared. Check that a polkit agent is running, and that you are in the `sudo` group. |
| `[helper] WARNING no default route after teardown` | Teardown could not restore routing. `nmcli networking off && nmcli networking on`. |
| `[helper] FATAL refusing to run: … is world-writable` | Anything writable by another account runs as root at your next connect, so the helper stops. `chmod go-w ~/.local/share/asuvpn` and re-run. |
| `refusing --background` / `refusing -bv` | That option would detach `openconnect` from the helper, leaving a root process nothing can stop. Drop it; write bundled short options separately (`-i lo`, not `-ilo`). |
| `[helper] WARNING … is not executable, so openconnect's own default script is left in place` | The `vpnc-script` this system uses could not be found, so state falls back to reading `openconnect`'s output. Routing is unaffected. Install `vpnc-scripts`. |
| `Script … returned error 127` | The `vpnc-script` failed, so routes and DNS were never configured. Install `vpnc-scripts`, then `asuvpn selftest`. |
| `ModuleNotFoundError: No module named 'pkg_resources'` | The `setuptools<71` pin did not take. `pipx inject openconnect-sso 'setuptools<71' --force` — the `--force` is what makes it apply. |
| Badge says **not carrying traffic** | The watchdog found the tunnel device or its routes gone, or nothing answering through it. It has already nudged `openconnect` once; `asuvpn log` says what it saw. If it does not recover, the automatic sign-in fires (unless turned off) — or `asuvpn reconnect` yourself. |
| Badge says **DNS not configured** | The resolver the VPN pushed is no longer on the tunnel's link, so internal names resolve to whatever public DNS says. The applet asks `openconnect` to re-establish, which reconfigures it. `resolvectl dns asuvpn0` shows the live state. |
| `ssh` to an internal host hangs while the VPN is up | The name is resolving to a public address instead of the internal one — `resolvectl query <host>` says which, and `resolvectl dns asuvpn0` says whether the VPN's resolver is on the link. If it is empty, `asuvpn log` will say why the handover did not take. With `dns = off` this is the stock `vpnc-script` behaviour and is expected to come back. |
| Badge says **…; rebuilding** | The tunnel died on its own and the applet will sign in again shortly, up to three times. **Stop reconnecting** in the menu — or `asuvpn disconnect` — calls it off. |
| `sign-in did not finish within 300s` | A sign-in sat unanswered — usually a Duo push or browser window with nobody at the keyboard — and was ended by `signin-timeout`. Connect again when you are there to answer it. |
| Tunnel silently stops working, badge stays green | Should no longer happen: `--force-dpd 30` is passed because ASU negotiates DPD off, and the watchdog covers what DPD cannot see. If it recurs, `asuvpn log` now records every check. |
| Self-check reports a failure | `asuvpn selftest` prints a detail line under each failure saying what will break and how to fix it. |

## Repository layout

| Path | What it is |
| --- | --- |
| [`asuvpn-tray`](asuvpn-tray) | The applet and the `asuvpn` CLI. Runs as you, on the system `python3`. |
| [`asuvpn-helper`](asuvpn-helper) | The root side, run under `pkexec`. Owns `openconnect`'s lifetime. |
| [`asuvpn-notify`](asuvpn-notify) | The `vpnc-script` wrapper. Reports state, configures the tunnel's DNS on its own link, then chains to the real script for routing. |
| [`asuvpn_contract.py`](asuvpn_contract.py) | What the programs agree on: wire format, control verbs, event fields, the settings schema — and the release version, stated once and read by everything including the build. Loaded, not run. |
| [`asuvpn-selftest`](asuvpn-selftest) | Checks the install against the machine. Run by `install.sh`, and by `asuvpn selftest`. |
| [`bootstrap.sh`](bootstrap.sh) | Installs dependencies, then calls `install.sh`. |
| [`install.sh`](install.sh) | Copies the app into `~/.local` and registers it. No system changes. |
| [`asuvpn.svg`](asuvpn.svg) | App icon. |
| [`tests/sandbox/`](tests/sandbox/README.md) | Scenario tests: the real programs run whole lifetimes against stand-ins, in a namespace. |
| [`IMPLEMENTATION_GUIDE.md`](IMPLEMENTATION_GUIDE.md) | Read before changing anything: what is proven and what is only believed, the traps, and the lessons each bug paid for. |
| [`ruff.toml`](ruff.toml) | Lint config. Its `ignore` list records which rules are off and why. |
| [`DESIGN.md`](DESIGN.md) | How the code works: the state machine and its full as-built transition table, who owns DNS, the invariants, and how it is all tested. |
| [`SECURITY.md`](SECURITY.md) | How to report a vulnerability privately, what is in scope, and what belongs upstream. |
| [`pyproject.toml`](pyproject.toml) + [`asuvpn_dist/`](asuvpn_dist/install.py) | The PyPI delivery channel: a wheel carrying these same files, plus `asuvpn-bootstrap` and `asuvpn-install`, which run the bundled `bootstrap.sh` and `install.sh`. No second installer. |
| [`.github/workflows/`](.github/workflows) | CI: the self-test and analysers on every push and PR; the scenario sandbox on main; PyPI publishing on a `v*` tag. |
| [`LICENSE`](LICENSE) | MIT. |

### Checking it

`install.sh` runs the self-check at the end of every install, and you can run it
yourself whenever something behaves oddly:

```bash
asuvpn selftest
asuvpn selftest --tier environment
asuvpn selftest --quiet          # only failures and warnings
```

It exits 0 if nothing failed, 1 otherwise. Nothing in it needs privileges, and
nothing it does can change this machine or the tunnel. It does reach the
network three times, all read-only: the real `openconnect` is run only to
describe itself (`--version` for its script path, `--help` for its
give-up-retrying default); a loopback connect and a SYN to RFC 5737
documentation space exercise the liveness probe and leave nothing behind; and
one unauthenticated capability handshake asks your gateway which sign-in method
it offers. That last one carries no credentials — it is the first request any
VPN client makes — and it is skipped, not failed, when the server is
unreachable.

The reason it is shaped the way it is: **ordinary unit tests would not have
caught a single one of the bugs that hurt this project.** Matching on
`Connected as`, which `openconnect` stopped saying in v8; hardcoding the
`vpnc-script` path, which differs between distributions; comparing whole `argv`
elements when `getopt` bundles short options — every one was a wrong assumption
about the *environment*, and a test that only checked the code against itself
would have passed happily while the code was dead. So there are three tiers, and
the middle one is the point:

| Tier | What it checks |
| --- | --- |
| `logic` | Pure functions and the state machine: the option blocklist, interface-name validation, `--interface`/`--script` parsing, the permission rules, state-payload parsing, the transition table driven with real message sequences, the rebuild bounds, the sign-in deadline against a child that would outlive the run, that `openconnect`'s output cannot forge a helper message, the split-DNS domain rules against option-like and shell-punctuation payloads, and every verdict the resolver check can reach |
| `environment` | Our assumptions put to the installed binaries — that `openconnect` exists, that it *gives up retrying* rather than trying forever (the fact the rebuild rests on, read back out of its own `--help`), that the `vpnc-script` it names is executable and handles every `reason` we send, that our fallback log patterns still appear in its message catalogue, that the split-DNS variables the handover reads are still named what we think, and that nothing the helper runs as root is writable by anyone else |
| `wiring` | `asuvpn-notify` actually executed: the event arrives with the right token and fields, the real `vpnc-script` still runs with its environment intact, the token is scrubbed before it sees it, no event can emit more than one line — and the DNS handover driven against a stand-in `resolvectl`, asserting the call order, the revert on every failure path, and that a failure always leaves the stock script its DNS job |

CI adds one thing the three tiers cannot do on a single machine: it runs the
`logic` tier inside Ubuntu 22.04, Debian 12, Fedora and Arch containers. That
tier is pure
Python — the GUI stack is imported behind a `try`/`except`, so a machine with
no GTK at all still loads every module and runs the contract, the state machine
and the split-DNS rules. It proves the portable half is portable. It proves
nothing about the tray on those distributions: no GTK, no `openconnect`, no
`pkexec` is exercised there, and `bootstrap.sh` still installs packages on apt
only.

The environment tier reads the installed `libopenconnect`'s own strings, so
`asuvpn selftest` is what tells you the fallback patterns have gone stale on
some future release, instead of finding out during an outage.

The suite is itself checked by breaking the code on purpose and confirming it
notices — from reverting the bundled-option fix to un-wiring the log scrubber
from the write path. The full table of verified mutations, every row run and
caught, lives in [DESIGN.md](DESIGN.md#mutation-testing).

The linters run separately. The four programs have no `.py` extension, so copy
them under one first; the contract comes along so it is checked too:

```bash
mkdir -p /tmp/asuvpn-lint && cp ruff.toml asuvpn_contract.py /tmp/asuvpn-lint/
cp asuvpn-tray     /tmp/asuvpn-lint/asuvpn_tray.py
cp asuvpn-helper   /tmp/asuvpn-lint/asuvpn_helper.py
cp asuvpn-selftest /tmp/asuvpn-lint/asuvpn_selftest.py
cp asuvpn-notify   /tmp/asuvpn-lint/asuvpn_notify.py
cp asuvpn_dist/install.py /tmp/asuvpn-lint/asuvpn_dist_install.py

ruff check /tmp/asuvpn-lint
pyflakes   /tmp/asuvpn-lint/*.py
pylint --disable=all --enable=E --ignored-modules=gi,gi.repository /tmp/asuvpn-lint/*.py
bandit -q -r /tmp/asuvpn-lint -ll
vulture --min-confidence 70 /tmp/asuvpn-lint/*.py
mypy --ignore-missing-imports /tmp/asuvpn-lint/*.py
shellcheck -S style bootstrap.sh install.sh tests/sandbox/*.sh \
           tests/sandbox/bin/pkexec tests/sandbox/bin/sso-python \
           tests/sandbox/bin/vpnc-script
```

All of these are expected to be clean. None of them need installing: `pipx run
<tool>` runs each from pipx's own cache and touches nothing else (the last one
as `pipx run --spec shellcheck-py shellcheck`). CI runs this same list plus
the full self-test on every push and pull request
([checks.yml](.github/workflows/checks.yml)), and the whole scenario sandbox
on pushes to main ([scenarios.yml](.github/workflows/scenarios.yml)). mypy's `--ignore-missing-imports`
is for `gi`, which ships no stubs.

The plain mypy run exits 0; the few `annotation-unchecked` notes it prints are
pointers to the stricter mode, not findings. Stricter mypy
(`--check-untyped-defs`) reports exactly two kinds of complaint,
both typeshed limitations rather than defects: `Popen` pipe attributes typed
`IO | None` (`PIPE` guarantees them, and every such write is exception-guarded
anyway), and `spec_from_loader` typed as returning `ModuleSpec | None` in each
program's contract loader (with an explicit `SourceFileLoader` it cannot).
Anything outside those two kinds is new, and worth reading.

## Design notes

[`DESIGN.md`](DESIGN.md) covers the internals for anyone reading or changing the
code: the process and privilege model, the state machine and where state comes
from, the threading model and the locks, the teardown guarantees, the full exit
code list, the invariants the code exists to maintain, how it is tested, and
what to update in lockstep when you change something.

## Status

Exercised with stand-in `openconnect-sso`, `pkexec` and `openconnect` binaries,
the last of which modeled a teardown that took real time to restore routes:
connect, disconnect, reconnect while connected, quit while connected, Ctrl+C in
foreground mode, crash safety under `SIGKILL`, a dismissed authorization dialog,
four simultaneous launches racing for the single-instance guard, every exit code,
the `--` passthrough, and installing from an arbitrary directory in both copy and
`--link` modes. Each teardown path was checked for a single `SIGINT`, no spurious
escalation, and a restored default route.

The state framework was exercised through the real script contract: a stand-in
openconnect that invokes `--script` with `reason=connect`, `attempt-reconnect`,
`reconnect` and `disconnect`, confirming the tray follows each one and displays
the assigned address. The permission refusal was tested by making each file and
the directory world-writable in turn, by staging a file owned by a genuinely
*second* group and watching the real helper refuse it (the scenario asserts,
and fails loudly if the refusal does not happen), and by confirming an ordinary
user-private-group checkout still runs.

The stand-ins and the scenarios live in
[tests/sandbox](tests/sandbox/README.md) and run inside an unprivileged
**user + mount namespace**, bind-mounted over `/usr/sbin/openconnect`,
`/usr/bin/pkexec`, `openconnect-sso` and the
`vpnc-script`, with a guard that refuses to start unless every one of them
resolves to a fake. Earlier rounds used symlinks, and twice a gap in that
arrangement let a test reach a real binary. A namespace cannot leak: the real
filesystem is not modified at all, and is byte-identical afterwards.

The `reason` values the framework depends on were confirmed present in the
installed `libopenconnect.so.5` rather than assumed. `reconnect` and `connect`
do not appear as separate strings in the binary because the build stores
them inside the longer word (tail-merging), overlapping them into
`attempt-reconnect` — they are at `attempt-reconnect`+8 and +10 respectively —
and the installed `vpnc-script` enumerates exactly those five in its own
`case` statement.

Behaviours confirmed by first reproducing the bug and then the fix: a failure
after a successful connect now reports `Failed to connect to host …` rather than
a bare exit status; a `reconnect` event racing a user-requested disconnect ends
`Disconnected` rather than in the error state; a bundled `-bv` is refused; a
missing `vpnc-script` leaves `openconnect`'s own default in place instead of
silently disabling all routing.

Specific defences were tested by trying to defeat them, not by inspection:

- **Import injection.** A `signal.py` dropped beside the helper executes when the
  helper runs without `-I`, and is ignored with it. The shebang is load-bearing.
- **Control socket.** With the peer check inverted so an ordinary connection
  looks foreign, the applet refuses it and logs the uid.
- **Interface safety.** `--interface <an existing device>` is refused rather than
  deleted; `--interface ../../etc/passwd` is rejected; the parser takes the last
  `--interface`, matching what getopt hands openconnect.
- **Cookie hygiene.** The cookie string appears zero times in the session log and
  zero times in the journal; only the `--cookie-on-stdin` flag name is there.
- **State reporting.** A rejected cookie surfaces as "Cookie was rejected by
  server", not a bare exit code; a mid-tunnel `Connection lost` drops the badge
  out of Connected so `asuvpn status` stops exiting 0.

Checked against the real tools: the sign-in browser reaches ASU's SAML page, the
keyring probe reports correctly, and GNOME resolves the launcher and icon.

> [!IMPORTANT]
> Stand-ins are only as good as the strings they imitate. An earlier version
> of the fake `openconnect` printed `Connected as …`, which openconnect
> stopped saying in v8 — so the applet's connect detection passed every test
> while being dead against the real v9.12 binary, and would have hung in
> "Connecting…" on any network without DTLS. The patterns are now taken from
> the installed binary's own message catalogue (`strings libopenconnect.so.5`)
> rather than from memory, and replayed against realistic v9.12 transcripts
> for the DTLS, TLS-only, proxied, rehandshake and drop-then-recover cases.
> `asuvpn selftest` now also holds the stand-in itself to that rule: every
> line it prints must be marked `[stand-in] ` or begin with a prefix from the
> installed binary's own catalogue, so a fake cannot drift back into invented
> wording.

**Exercised end to end since:** a full connect through the real `pkexec`
prompt, a real Duo approval and ASU's own gateway, watched over a working
session and torn down cleanly — `openconnect exited with status 0`,
`default route restored:` in the log, the device gone and nothing left running.
The `--force-dpd 30` the helper passes was confirmed safe against ASU: the
server declines DPD but answers forced probes, with zero reconnect events over
the measured window.

The stand-in exercises earlier in this section — the launch races, the exit
code sweep, the arbitrary-directory installs — predate the committed suite
and were run with earlier versions of the same fakes before the harness moved into the
repository; the fourteen committed scenarios are the ones tabulated in
[tests/sandbox](tests/sandbox/README.md).

What is proven live against the real gateway (full connects and teardowns,
forced-DPD safety, free recovery through WiFi loss and suspend, the nudge)
versus only in the sandbox (the full escalation ladder including the
unattended sign-in, the shared-group refusal) is kept, with dates and evidence,
in
[IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) — that ledger, not this
paragraph, is current.

## License

MIT. See [LICENSE](LICENSE).
