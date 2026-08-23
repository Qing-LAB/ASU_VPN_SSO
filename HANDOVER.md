# Hand-over

State of the work, what is proven and what is not, and the things that were
learned the expensive way. Written for whoever picks this up next — including a
future assistant session starting cold.

[README](README.md) is for users. [DESIGN.md](DESIGN.md) is how the code works.
This file is what you need to know *before* changing any of it.

---

## Where it stands

Everything is committed and pushed to `main` at
**https://github.com/Qing-LAB/ASU_VPN_SSO**, and the installed copy in
`~/.local/share/asuvpn` matches `HEAD` exactly.

| | |
| --- | --- |
| Programs | `asuvpn-tray` (you), `asuvpn-helper` (root, via pkexec), `asuvpn-notify` (root, run by openconnect), `asuvpn-selftest` (you) |
| Shared | `asuvpn_contract.py` — loaded by explicit path, never imported |
| Settings | `~/.config/asuvpn/asuvpn.conf`, generated from the contract's schema |
| Checks | `asuvpn selftest` — 67, in three tiers |
| Analysers | ruff, pyflakes, pylint, mypy, bandit, vulture, shellcheck — all clean |
| Tested against | openconnect v9.12-3.3, Ubuntu, GNOME, ASU's `sslvpn.asu.edu` |

**It works.** A real tunnel has been established, run, watched and torn down
cleanly, with `default route restored:` confirmed on the way out.

---

## What is proven, and what is not

Be precise about this. Several things in this project *looked* proven and were
not, and each cost a round of rework.

### Proven on the real thing

- Full connect through real `pkexec`, real Duo, real ASU gateway.
- Clean teardown: `openconnect exited with status 0`, routes restored, device
  gone, nothing left running.
- The script contract fires from the real binary — `STATE connected dev=asuvpn0
  addr=…` came from real openconnect via real `vpnc-script`.
- `--force-dpd 30` is **safe on ASU**. The server negotiates `DPD 0` but *does*
  answer forced probes: 90 seconds with DPD active, zero reconnect events. This
  was the last open risk and it is closed.
- The liveness probe target answers in ~17 ms; a refusal (RST) arrives in ~20 ms
  and correctly counts as alive.

### Proven only in the sandbox

- The watchdog's escalation ladder, the nudge rate limits, notification wording,
  every failure path, and the config driving behaviour end to end.
- These use stand-ins. **A stand-in is only as good as the strings it imitates**
  — see the `Connected as` story below.

### Not proven at all

- Anything on a distribution other than Ubuntu/Debian, or a desktop other than
  GNOME.
- The **shared-group** permission refusal end to end. The predicate is unit
  tested, but a user namespace maps a single gid, so a second principal cannot
  be created inside the sandbox. Do not write this up as if it were covered.

---

## Open questions, and answers already established

Do not re-derive these. Each was investigated with evidence.

**Can the polkit password be cached?** Not safely as things stand. `pkexec` runs
everything under one action id (`org.freedesktop.policykit.exec`) and the
program is a *detail*, not part of the action. A scoped `auth_admin_keep` rule
would not hand out a general exemption — polkit re-evaluates per check and only
consults a stored authorization when the current evaluation returns a `_KEEP`
result — but that is not the reason to avoid it. **The helper lives in the
user's home and the user can write it**, so a rule keyed on that path caches
root for a file they can overwrite. The only safe version moves the helper to
root-owned storage first, and **the user has explicitly ruled that out** ("a can
of worms"). Treat it as closed.

**Can the Duo push be skipped?** Not from here. `openconnect-sso` uses Qt's
default WebEngine profile, which is off-the-record — `~/.cache/openconnect-sso`
holds only a shader cache and nothing was written there by two sign-ins. The
"remember this device" cookie is discarded every run. Fixing it means patching
upstream, or using openconnect's own `--external-browser` (untested; depends on
the gateway advertising `single-sign-on-external-browser`).

**Can the session cookie be cached to skip sign-in?** No — and the reason is
worth remembering. `SIGINT/SIGTERM` makes openconnect *log the session off*, and
our teardown is always clean by design. The cached cookie would be dead. It
would only survive an unclean exit, which is exactly what this project is built
to prevent. libsecret works fine from the tray's python if this ever comes up
again; the obstacle is not the storage.

**Why is the pin `setuptools<71`?** Empirical, from the user. The stated reason
was wrong and is now corrected: `pkg_resources` is present in setuptools 78.1.1
and gone by 83.0.0, so the real cliff is above 78. `<71` is a known-good pin,
not a boundary. `openconnect_sso/browser/webengine_process.py` is what needs it.

---

## The lessons, in order of how much they cost

### 1. Wording is not an interface

The applet matched `Connected as …`, which openconnect **stopped saying in v8**.
Every test passed because the stand-in printed the invented wording. The code
was dead against the real v9.12 binary and would have hung in "Connecting…" on
any network without DTLS.

The same mistake recurred in a different shape: the tray picked the helper's
failure explanation out of lines beginning with `"refusing"`, and four of seven
refusals did not use that word, so those reached the user as a bare exit number.

**Therefore:** state comes from openconnect's *script contract* (`reason=…` in
the environment), not its log text. Messages carry an explicit `KIND`. Where log
patterns survive as a fallback, each carries the literal fragment it depends on
and `asuvpn selftest` checks those against the installed binary's own string
table.

### 2. Check the effect, not the exit status

Every serious bug here was something reporting success while doing nothing:

- matching a log line the binary no longer prints
- chaining to a `vpnc-script` path that does not exist on this distribution
- comparing whole `argv` elements when `getopt` bundles short options (`-bv`)
- `pipx inject` skipping a pin because *some* `setuptools` was present, exit 0

In each case the status said fine and the code was inert. So: ask the installed
software rather than remembering what it does (`openconnect --version` reports
its own default script path), and verify outcomes (`bootstrap.sh` checks that
`pkg_resources` actually imports).

### 3. Test the environment, not just the code

Ordinary unit tests would have caught **none** of the above. That is why
`asuvpn-selftest` has an `environment` tier that puts assumptions to the
installed binaries, and why the watchdog's checks were designed by measuring a
live tunnel first — three of the four obvious health checks would have raised a
false alarm on a perfectly healthy ASU link:

| Tempting check | Reality on a live ASU tunnel |
| --- | --- |
| `operstate == "up"` | `unknown` — tun devices never say `up` |
| `IFF_RUNNING` | not set; flags are `0x1091` |
| default route via the tunnel | absent — split tunnel, 53 IPv4 + 6 IPv6 routes |
| counters advancing | flat; an idle tunnel moves nothing |

### 4. A test that only ever passes proves nothing

Every check in the self-test has been verified by breaking the code on purpose
and confirming it fails. Do this for anything you add. It has caught weak
assertions twice — including one that checked field *names* when the property
that mattered was the field *count*.

### 5. Sandbox isolation must be structural, not careful

Twice, test harnesses reached real binaries — once opening the real ASU sign-in
browser, once making a real TLS connection to the gateway. Both times the cause
was checking one binary and assuming the rest.

The sandbox is now an unprivileged **user + mount namespace** with fakes
bind-mounted over `/usr/sbin/openconnect`, `/usr/bin/pkexec`, the real
`openconnect-sso` and the `vpnc-script`, plus a guard that refuses to start
unless every one of them resolves to a fake. A namespace cannot leak: the real
filesystem is never modified. **Do not go back to symlinks.**

### 6. Duplication drifts, and drift is invisible

Five message prefixes, two config mechanisms, nine tunables across two programs,
a permission rule copied three times — each restated where it was needed and
each quietly diverged. One `_start_tunnel` reset omitted `tunnel_dns` and a new
tunnel probed the previous one's resolver.

`asuvpn_contract.py` now holds anything more than one program needs to know. The
eight-line loader in each program is the *only* thing duplicated on purpose,
because code cannot be shared before the sharing mechanism is loaded.

---

## Traps specific to this codebase

- **Only one thread may call `Popen.wait()` per child.** CPython's timed wait
  acquires the waitpid lock non-blockingly, so a concurrent blocking wait makes
  every timed wait spuriously time out. That once escalated a clean teardown to
  `SIGKILL` — the one thing that stops `vpnc-script` restoring the routing table.
- **`preexec_fn` runs in the child.** `os.getpid()` there is the child's. Capture
  the parent pid *before* `Popen`.
- **`GLib.idle_add` before releasing anyone waiting.** In `_tunnel_thread`'s
  `finally`, queue `_on_tunnel_exit` *then* set `exited`, or teardown can win the
  race and a healthy reconnect gets reported as a failure.
- **`~` is root's home in the helper.** It never reads user config; the tray
  passes what it needs as arguments.
- **Loading the contract writes `__pycache__`** into the directory the helper
  runs out of as root, unless `sys.dont_write_bytecode` is set first. This has
  regressed twice; it is now check #67.
- **The running applet holds its code in memory.** After `install.sh`, a plain
  `asuvpn reconnect` still runs the old tray. `asuvpn quit` then connect.

---

## What to do next, roughly in order

1. **Live-exercise the watchdog.** Everything about it is sandbox-proven only.
   Suspend/resume, or toggle WiFi, on a real tunnel and watch `asuvpn log -f`.
   Expected: `attempt-reconnect` → `reconnect` with no sign-in, or the probe
   reporting if routes are lost.
2. **Try `autoreconnect = on`** for a while, if the user wants unattended
   recovery, and see whether the 300 s floor is right.
3. **Consider whether `probe-every = 3` is the right frequency** now that a real
   probe costs ~17 ms and one TCP handshake a minute.
4. Leave the polkit prompt alone unless the user reopens it.

---

## How to work on it

```bash
asuvpn selftest                 # 67 checks; run before and after any change
./install.sh                    # copies into ~/.local, runs the self-check
asuvpn log -f                   # what it is actually doing
```

Analysers (all expected clean) are listed in the README's
[Checking it](README.md#checking-it) section. `DESIGN.md` has the invariants
table and a "Changing things" section saying what to update in lockstep.

**Before claiming anything works, ask how it would look if it did not.** That
question is the whole difference between the bugs in this history and the ones
that were caught.
