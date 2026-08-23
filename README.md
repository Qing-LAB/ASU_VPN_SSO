# ASU VPN SSO

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
- **Another distribution.** `bootstrap.sh` is apt-only and will stop with the
  dependency list rather than guess. The applet itself is plain Python and GTK 3.

> [!NOTE]
> `bootstrap.sh` installs around thirty apt packages including a build
> toolchain, compiles `lxml` from source, may add the deadsnakes PPA for
> Python 3.12, and enables a GNOME extension. Read
> [Requirements](#requirements) first if that matters to you.

---

**Contents**

- [Quick start](#quick-start)
- [Using it](#using-it)
- [Settings](#settings)
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

## Using it

Launching the app connects straight away:

1. `openconnect-sso` opens a browser window for the ASU sign-in, including Duo.
2. A polkit dialog asks for **your own** password, because `openconnect` needs
   root to create the tun device. This replaces the terminal `sudo` prompt you
   get from `openconnect-sso` on its own — a desktop launcher has no terminal to
   type into. You are asked once per connect, and never to disconnect.
3. The tunnel stays up in the background.

### The panel icon

| Icon | State |
| --- | --- |
| Filled VPN badge | Connected |
| Dashed VPN badge | Disconnected |
| Acquiring badge | Signing in, connecting, or disconnecting |
| Error badge | Something failed |

The menu shows only what applies to the current state: **Connect** when down,
**Disconnect** and **Reconnect** when up, and **Cancel** while signing in or
connecting. It is not offered during teardown, which must not be interrupted.
**Show log…** opens a live log window, and **Quit** closes the tunnel first.

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
| **VPN not carrying traffic** | the watchdog found the device, its routes or the far end gone | — |
| **VPN reconnecting** | `openconnect` was nudged to rebuild the tunnel | nothing — same session |
| **VPN carrying traffic again** | the tunnel recovered | — |
| **VPN signing in again** | the nudge did not help and automatic reconnection is on | **a Duo push and a password** |
| **VPN disconnected** | the tunnel closed, with the reason if it was not you | — |
| **VPN teardown warning** | the network may not have been restored | — |

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

Most of it takes effect without reconnecting: the watchdog re-reads the file on
each check, so changing `health-interval`, `probe`, `probe-target` or the rate
limits applies within seconds. `dpd` reaches `openconnect` on its command line,
so that one needs a reconnect. A malformed line costs that setting its default
and logs a sentence saying so — a config file is never a reason to be unable to
connect.

| Setting | Default | What it decides |
| --- | --- | --- |
| `server` | `sslvpn.asu.edu` | The endpoint. Set by `install.sh --server`. |
| `autoreconnect` | `off` | Sign in again unattended when a stall cannot be fixed for free. Costs a Duo push and a password. |
| `dpd` | `30` | Dead-peer probe interval, forced on. **`0` leaves the server's choice alone** — the escape hatch if forcing it ever misbehaves. |
| `health-interval` | `20` | Seconds between checks. **`0` turns the watchdog off.** |
| `health-strikes` | `2` | Consecutive bad checks before the badge stops claiming Connected. |
| `probe` | `on` | Ask the network whether traffic still flows. The only check that catches a tunnel that looks perfect and delivers nothing. |
| `probe-target` | *(empty)* | Address to probe. Empty means the resolver the VPN itself pushed. |
| `probe-port`, `probe-every`, `probe-timeout` | `53`, `3`, `5` | Port, how often, how long to wait. |
| `nudge-min-gap` | `120` | Seconds between free re-establish requests. |
| `autoreconnect-min-gap` | `300` | Seconds between unattended sign-ins. |
| `teardown-timeout` | `75` | Seconds to wait for the helper. Must outlast its signal escalation. |

`asuvpn autoreconnect on` edits the file in place, changing that one line and
leaving everything else as you left it.

### The command line

`asuvpn` does the same things as the menu. If an applet is already running it
drives that one rather than starting a second.

```bash
asuvpn                  # same as: asuvpn connect
asuvpn connect          # sign in and bring the tunnel up
asuvpn status           # what state is it in
asuvpn disconnect       # close the tunnel, leave the applet running
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
| `1` | `status` or `--wait`: not connected. `disconnect`: the tunnel did not close |
| `2` | A bad command line (argparse's own code) |
| `3` | `status`: the applet is not running |
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
| `26` | the helper, its directory, `asuvpn-notify` or the contract is writable by someone else |
| `27` | a negative dead-peer interval was passed |

```bash
asuvpn status >/dev/null || asuvpn connect --wait
```

Other options: `--server HOST` for a different endpoint, `--foreground` to keep
the applet attached to the terminal, and a bare `--` to pass extra arguments
through to `openconnect`. Flags may go before or after the command.

Arguments after `--` are checked for options that would take `openconnect` out
of the helper's supervision — `--background`, `--syslog`, `--pid-file` and
friends are refused. Bundled short options are refused too, because `getopt`
reads `-bv` as `-b -v` and working out which letter is an option and which is
somebody's argument would mean reimplementing `getopt` against a table that
changes between releases. Write them separately: `-i lo`, not `-ilo`.

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

Everything lands under `~/.local`. Nothing is written outside `$HOME`, no system
files are touched, and no part of the installation needs root. The program is
**copied**, so the checkout can be moved or deleted afterwards.

| Path | What it is |
| --- | --- |
| `~/.local/share/asuvpn/` | `asuvpn-tray`, `asuvpn-helper`, `asuvpn-notify`, `asuvpn-selftest`, `asuvpn_contract.py` and the icon (`0755`, never group-writable) |
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

That removes the app completely. It deliberately leaves the things it did not
own: `openconnect-sso` (`pipx uninstall openconnect-sso`), the apt packages, the
deadsnakes PPA, the AppIndicator GNOME extension, your keyring entries, and any
polkit rule you added by hand.

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
- binds an abstract Unix socket for the single-instance guard and the CLI.
  Abstract sockets carry no filesystem permissions, so every connection's peer
  uid is checked with `SO_PEERCRED` and anything else is refused — otherwise
  another local user could drop your tunnel, read your assigned VPN address,
  or call `connect` to raise an admin password prompt on your desktop at will

### What runs as root

Only `asuvpn-helper`, only via `pkexec`, and only after you approve the polkit
dialog. Once elevated it does exactly three things:

1. runs `openconnect` with the session cookie fed on stdin, and stays alive as
   its supervisor for the life of the tunnel — it does not exec and step aside,
2. signals `openconnect` to shut down when the control pipe closes,
3. after exit, deletes a tunnel interface that outlived `openconnect` and reads
   the default route back, to confirm your network was restored.

It also opens a datagram socket for `asuvpn-notify` to report state on. That
lives in a `0700` directory under `/run` owned by root, so no other account can
reach it — and every message carries a per-session token, so two concurrent
sessions cannot be confused for one another.

Before doing any of that, the helper **refuses to run** if itself, its directory
or `asuvpn-notify` is world-writable or writable by a shared group. That turns
the caveat below from something you have to remember into something enforced. A
user-private group is not treated as a finding: Debian and Ubuntu default to
umask 002, so an ordinary checkout is `0775` with `gid == uid` and the "group"
is one person.

### What it never does

- **Never sees your password.** `openconnect-sso` reads it from the login
  keyring, and the polkit password goes to GNOME's authentication agent. Neither
  passes through this app. The pre-flight check asks the keyring only whether a
  password exists and receives back one of four literal strings — `ready`,
  `no-password`, `no-credentials` or `unknown` — never the password itself.
- **Never writes to the keyring.**
- **Never logs the session cookie**, and never puts it on a command line where
  `ps` could show it. It is written to the helper's stdin and nowhere else.
  Note this is a property of the default arguments: `asuvpn connect --
  --dump-http-traffic` would make *openconnect* print the cookie header, and
  that lands in the log like any other output.
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
datagram to the helper and then `exec`s the real `vpnc-script`, so routing and
DNS are configured exactly as they would have been. If you pass your own
`--script`, it is chained rather than discarded.

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

#### Dead peer detection is forced on

That first mechanism only works if dead peer detection is running, and **ASU's
server turns it off**. A real session logs:

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

The target is not configured and not hardcoded — it is the resolver the VPN
itself pushed (`INTERNAL_IP4_DNS`), forwarded through the same script contract
everything else uses. Whatever this tunnel says to resolve against is by
definition something that ought to answer through it. A VPN that pushes no
resolver simply gets the device checks.

The probe opens a TCP connection and closes it. **A refusal counts as alive**,
which is the part worth understanding: measured against a live ASU tunnel, one
pushed resolver completed the handshake in 29 ms and the other answered with a
RST in 20 ms — and the RST is just as good an answer, because it proves a packet
crossed in each direction. Only silence means the tunnel is not carrying
traffic. Whether the service behind the probe is up is none of our business.

The two sources are tracked separately, so a probe failure is only cleared by a
successful probe. Letting the device check promote the badge back would flap it
every twenty seconds against a tunnel that is genuinely carrying nothing. The
same rule holds against openconnect's own word: the reconnect a nudge produces
does not promote the badge either — the source that demoted has to pass again
first, which takes at most one more check. Route families are counted
separately too, because `ip route flush` removes only IPv4 and a summed count
sat green through exactly that break on a live tunnel.

The result is logged either way, so the next silent break leaves evidence
instead of a mystery:

```
[tray] tunnel device check 1/2: the tunnel's IPv4 routes are gone (dev=asuvpn0, ifindex=6, flags=0x1091, routes4=0, routes6=6)
[tray] tunnel probe check 2/2: nothing answers through the tunnel (10.0.0.53 did not answer in 5s)
[tray] asked openconnect to re-establish (same session, no sign-in needed)
```

#### What it does about it

Cheapest first, because the two recoveries are not interchangeable:

1. **Nudge.** Send `openconnect` a `SIGUSR2`, which it documents as forcing "an
   immediate disconnection and reconnection". The session is reused, so this
   costs no sign-in, no Duo push and no password — you need not even be at the
   keyboard. One nudge per incident: if the tunnel is demoted again after its
   nudge, the nudge demonstrably did not fix it, and asking every two minutes
   forever is what a routes-lost tunnel actually got before this rule.
2. **Say so.** The badge leaves *Connected*, so `asuvpn status` stops exiting 0,
   and one notification per incident explains what was observed.
3. **Sign in again — only if you asked for it.** Off by default, because it
   means a Duo approval and typing your password into a polkit dialog.

```bash
asuvpn autoreconnect          # on or off
asuvpn autoreconnect on
```

or the menu item **Reconnect automatically if traffic stops**. When on, it is
rate limited to once every five minutes.

An automatic reconnect does **not** truncate the session log, so the lines
explaining why it happened survive it — a connect you asked for still starts a
fresh log. While the badge shows *not carrying traffic* the menu still offers
Disconnect and Reconnect, because the tunnel is established, just not usable.

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
| The **helper** itself dies (OOM, `kill -9`) | The kernel signals `openconnect` via `PR_SET_PDEATHSIG`, so it still runs `vpnc-script`. |

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

- **Gentle escalation.** Teardown sends `SIGINT`, waits 15 seconds, then
  `SIGTERM` for another 10, and only then `SIGKILL`. Both polite signals make
  `openconnect` run the disconnect script; killing early is precisely what
  breaks things, so the graces are deliberately generous.
- **No `SIGPIPE` deaths.** Relaying output keeps `openconnect` alive long enough
  to finish that script even if the tray is gone.
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
18:32:14  [helper] default route restored: default via 198.51.100.1 dev wlan0 proto dhcp metric 600
```

If instead you see `[helper] WARNING: no default route after teardown — network
is likely broken`, the recovery is:

```bash
nmcli networking off && nmcli networking on
```

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

| Symptom | Cause and fix |
| --- | --- |
| `no saved password` | The keyring has no password and the applet will not guess a blank one. Run `openconnect-sso --server sslvpn.asu.edu --authenticate=shell` once in a terminal. |
| `authorization cancelled` | The polkit dialog was dismissed, or the password was wrong. Run `asuvpn connect` again. |
| No icon in the panel | `gnome-extensions enable ubuntu-appindicators@ubuntu.com` |
| `asuvpn: command not found` | `~/.local/bin` is not on your `PATH`. Add it, or run `pipx ensurepath` and open a new terminal. |
| The sign-in window never appears | That is `openconnect-sso`, not this applet. Run `openconnect-sso --server sslvpn.asu.edu --authenticate=shell` to see the real error. |
| `could not load the Qt platform plugin "xcb"` | Missing `libxcb-cursor0`. Re-run `./bootstrap.sh`. |
| Log stops at `signed in, starting openconnect` | The polkit dialog never appeared. Check that a polkit agent is running, and that you are in the `sudo` group. |
| `WARNING: no default route after teardown` | Teardown could not restore routing. `nmcli networking off && nmcli networking on`. |
| `refusing to run: … is world-writable` | Anything writable by another account runs as root at your next connect, so the helper stops. `chmod go-w ~/.local/share/asuvpn` and re-run. |
| `refusing --background` / `refusing -bv` | That option would detach `openconnect` from the helper, leaving a root process nothing can stop. Drop it; write bundled short options separately (`-i lo`, not `-ilo`). |
| `WARNING: … is not executable, so openconnect's own default script is left in place` | The `vpnc-script` this system uses could not be found, so state falls back to reading `openconnect`'s output. Routing is unaffected. Install `vpnc-scripts`. |
| `Script … returned error 127` | The `vpnc-script` failed, so routes and DNS were never configured. Install `vpnc-scripts`, then `asuvpn selftest`. |
| `ModuleNotFoundError: No module named 'pkg_resources'` | The `setuptools<71` pin did not take. `pipx inject openconnect-sso 'setuptools<71' --force` — the `--force` is what makes it apply. |
| Badge says **not carrying traffic** | The watchdog found the tunnel device or its routes gone. It has already nudged `openconnect` once; `asuvpn log` says what it saw. If it does not recover, `asuvpn reconnect`. |
| Tunnel silently stops working, badge stays green | Should no longer happen: `--force-dpd 30` is passed because ASU negotiates DPD off, and the watchdog covers what DPD cannot see. If it recurs, `asuvpn log` now records every check. |
| Self-check reports a failure | `asuvpn selftest` prints a detail line under each failure saying what will break and how to fix it. |

## Repository layout

| Path | What it is |
| --- | --- |
| [`asuvpn-tray`](asuvpn-tray) | The applet and the `asuvpn` CLI. Runs as you, on the system `python3`. |
| [`asuvpn-helper`](asuvpn-helper) | The root side, run under `pkexec`. Owns `openconnect`'s lifetime. |
| [`asuvpn-notify`](asuvpn-notify) | The `vpnc-script` wrapper. Reports state, then chains to the real script. |
| [`asuvpn_contract.py`](asuvpn_contract.py) | What the programs agree on: wire format, control verbs, event fields, and the settings schema. Loaded, not run. |
| [`asuvpn-selftest`](asuvpn-selftest) | Checks the install against the machine. Run by `install.sh`, and by `asuvpn selftest`. |
| [`bootstrap.sh`](bootstrap.sh) | Installs dependencies, then calls `install.sh`. |
| [`install.sh`](install.sh) | Copies the app into `~/.local` and registers it. No system changes. |
| [`asuvpn.svg`](asuvpn.svg) | App icon. |
| [`DESIGN.md`](DESIGN.md) | Internals: state machine, concurrency, invariants, how it is tested. |
| [`HANDOVER.md`](HANDOVER.md) | What is proven and what is not, the lessons behind the design, and what to do next. |
| [`ruff.toml`](ruff.toml) | Lint config. Its `ignore` list records which rules are off and why. |

### Checking it

`install.sh` runs the self-check at the end of every install, and you can run it
yourself whenever something behaves oddly:

```bash
asuvpn selftest
asuvpn selftest --tier environment
asuvpn selftest --quiet          # only failures and warnings
```

It exits 0 if nothing failed, 1 otherwise. Nothing in it connects to a network,
asks for privileges, or touches the real `openconnect`.

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
| `logic` | Pure functions: the option blocklist, interface-name validation, `--interface`/`--script` parsing, the permission rules, state-payload parsing, and that `openconnect`'s output cannot forge a helper message |
| `environment` | Our assumptions put to the installed binaries — that `openconnect` exists, that the `vpnc-script` it names is executable and handles every `reason` we send, that our fallback log patterns still appear in its message catalogue, and that nothing the helper runs as root is writable by anyone else |
| `wiring` | `asuvpn-notify` actually executed: the event arrives with the right token and fields, the real `vpnc-script` still runs with its environment intact, the token is scrubbed before it sees it, and no event can emit more than one line |

The environment tier reads the installed `libopenconnect`'s own strings, so
`asuvpn selftest` is what tells you the fallback patterns have gone stale on
some future release, instead of finding out during an outage.

The suite is checked by breaking the code on purpose and confirming it notices:
reverting the bundled-option fix, making the field sanitiser a no-op, pointing
the default script somewhere that does not exist, matching on a message the
binary no longer contains, and making the installed directory world-writable.
All five are caught.

The linters run separately. The four programs have no `.py` extension, so copy
them under one first; the contract comes along so it is checked too:

```bash
mkdir -p /tmp/asuvpn-lint && cp ruff.toml asuvpn_contract.py /tmp/asuvpn-lint/
cp asuvpn-tray     /tmp/asuvpn-lint/asuvpn_tray.py
cp asuvpn-helper   /tmp/asuvpn-lint/asuvpn_helper.py
cp asuvpn-selftest /tmp/asuvpn-lint/asuvpn_selftest.py
cp asuvpn-notify   /tmp/asuvpn-lint/asuvpn_notify.py

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
as `pipx run --spec shellcheck-py shellcheck`). mypy's `--ignore-missing-imports`
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
the last of which models a teardown that takes real time to restore routes:
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
installed `libopenconnect.so.5` rather than assumed. `connect` and `reconnect`
do not appear in `strings` output because the linker tail-merges them into
`attempt-reconnect` — they are at `attempt-reconnect`+8 and +10 — and the
installed `vpnc-script` enumerates exactly those five in its own `case`
statement.

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
> of the fake `openconnect` printed `Connected as …`, which openconnect has
> not said since v7 — so the applet's connect detection passed every test
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

Still unproven: the watchdog's recovery ladder against a *real* failure
(suspend/resume, WiFi loss — sandbox-proven only so far), the shared-group
permission refusal end to end, and anything outside Ubuntu and GNOME.
[HANDOVER.md](HANDOVER.md) keeps the ledger of what is proven against the real
gateway versus only in the sandbox.

## License

MIT. See [LICENSE](LICENSE).
