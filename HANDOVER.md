# Hand-over

State of the work, what is proven and what is not, and the things that were
learned the expensive way. Written for whoever picks this up next — including a
future assistant session starting cold.

[README](README.md) is for users. [DESIGN.md](DESIGN.md) is how the code works.
This file is what you need to know *before* changing any of it.

---

## Where it stands

Everything is committed and pushed to `main` at
**https://github.com/Qing-LAB/ASU_VPN_SSO**, and released to PyPI as `asuvpn`
on a `v*` tag.

The installed copy under `~/.local/share/asuvpn` is a **copy**, so it lags
`HEAD` until `./install.sh` (or `asuvpn-install`) is run again — `asuvpn
--version` against the contract's `VERSION` is how to tell. Worth checking
before believing a bug report from your own desktop.

| | |
| --- | --- |
| Programs | `asuvpn-tray` (you), `asuvpn-helper` (root, via pkexec), `asuvpn-notify` (root, run by openconnect), `asuvpn-selftest` (you) |
| Shared | `asuvpn_contract.py` — loaded by explicit path, never imported |
| Settings | `~/.config/asuvpn/asuvpn.conf`, generated from the contract's schema |
| Checks | `asuvpn selftest` — three tiers, count in its own summary line; scenario suite in [tests/sandbox](tests/sandbox/README.md), every scenario asserting its outcome |
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
- **Free recovery works on the real gateway** (exercised 2026-08-23, twice).
  WiFi loss and suspend/resume both played out the designed sequence live:
  forced DPD detected the dead peer, `attempt-reconnect` → `reconnect` came
  through the script contract, the badge honestly showed "link lost, retrying"
  throughout, and the session resumed with the same cookie and address — no
  Duo, no password. Wake-to-recovered after suspend: 18 seconds. The watchdog
  counted a probe strike during each break and correctly stood aside while
  openconnect ran its own recovery; a transient overnight probe strike (1/2)
  cleared on the next cycle without a demotion.
- **The nudge fired live** (2026-08-23, routes flushed by hand): two probe
  strikes → demotion → `SIGUSR2` → openconnect re-established the session in
  one second, no sign-in. The mechanism works; what it exposed is recorded
  under "what to do next".
- The liveness probe target answers in ~17 ms (an earlier session measured
  29 ms); a refusal (RST) arrives in ~20 ms and correctly counts as alive.

### Proven only in the sandbox

- The escalation ladder *beyond its first rung*. The WiFi and suspend breaks
  never reached the ladder at all — openconnect recovered first, which is the
  designed order — and the live routes-flush did fire the nudge (see above).
  What has run only in the sandbox is the post-fix remainder: staying demoted
  after a spent nudge, and the unattended sign-in.
- The nudge rate limits, notification wording, every failure path, and the
  config driving behaviour end to end.
- **Rebuilding a tunnel that died outright** (2026-08-28). `rebuild.sh` stages
  openconnect giving up the way it does after its own reconnect timeout, and
  asserts the applet signs in again unasked, stops after `MAX_REBUILDS`, and
  says so once. The three bounds — armed only after real traffic, the shared
  rate limit, the count — are each mutation-verified in the logic tier.
- **The sign-in deadline** (2026-08-28), driven against a child that would
  outlive the whole run. A wait that never returns cannot be observed by
  waiting for it, so `Deadline` takes its kill as an argument and the check
  hangs the suite rather than passing quietly if it ever stops firing.
- **The helper dying takes openconnect with it** (2026-08-28): `pdeath.sh`
  SIGKILLs the helper mid-tunnel and asserts the stand-in openconnect dies
  within five seconds — the kernel parent-death signal proven end to end,
  where before only the tray-death direction had a scenario.
- **The nudge's delivery** (2026-08-28): `watchdog-test.sh` now asserts the
  stand-in's own SIGUSR2 telemetry, not just the tray's intent line — the
  verb crossing the pipe and becoming a signal was previously unproven.
- The teardown ladder's **order** (2026-08-24): `stubborn.sh` stages a peer
  that ignores SIGINT and asserts SIGTERM comes only after the full grace and
  SIGKILL not at all. Live teardowns had only ever exercised the first rung.
- The control socket's **uid gate** against a real second uid (2026-08-24):
  `ipc-gate.sh` pokes the applet's socket as uid 65534 (refused, no reply,
  logged) and as our own uid (answered). Previously verified once by hand,
  by inverting the check.
- The **shared-group** permission refusal, end to end since 2026-08-22: the
  sandbox now maps this user's `/etc/subgid` block (`--map-auto`), so
  `tests/sandbox/sec.sh` stages a file owned by a second group and watches the
  real helper refuse — loader path for the contract, exit 26 for the helper
  itself — with both assertions mutation-verified. (Earlier, the namespace
  mapped a single gid, the scenario's `chgrp` failed silently, and the case was
  honestly recorded here as not proven at all.)
- These use stand-ins. **A stand-in is only as good as the strings it imitates**
  — see the `Connected as` story below. Since 2026-08-22 the selftest enforces
  that mechanically: every line the stand-in prints is either marked
  `[stand-in] ` or anchored to the installed binary's own catalogue.

### Not proven at all

- Anything on a distribution other than Ubuntu/Debian, or a desktop other than
  GNOME.

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

It lives in [tests/sandbox](tests/sandbox/README.md) — committed since
2026-08-22, after it was found to exist only in a session's temp directory,
one reboot away from ceasing to exist while three documents described it in
the present tense.

### 6. Duplication drifts, and drift is invisible

Five message prefixes, two config mechanisms, nine tunables across two programs,
a permission rule copied three times — each restated where it was needed and
each quietly diverged. One tunnel-starter reset omitted `tunnel_dns` and a new
tunnel probed the previous one's resolver.

`asuvpn_contract.py` now holds anything more than one program needs to know. The
small loader in each program is the *only* thing duplicated on purpose, because
code cannot be shared before the sharing mechanism is loaded — and the copies
are not quite identical: the tray resolves its symlink with `realpath`, the
others use `abspath`, and the reference copy in the contract says which.

---

## Traps specific to this codebase

- **Only one thread may call `Popen.wait()` per child.** CPython's timed wait
  acquires the waitpid lock non-blockingly, so a concurrent blocking wait makes
  every timed wait spuriously time out. That once escalated a clean teardown to
  `SIGKILL` — the one thing that stops `vpnc-script` restoring the routing table.
- **`preexec_fn` runs in the child.** `os.getpid()` there is the child's. Capture
  the parent pid *before* `Popen`.
- **Post the exit message before releasing anyone waiting.** In
  `_tunnel_thread`'s `finally`, post `helper-exited` *then* set `exited`, or
  teardown can win the race and a healthy reconnect gets reported as a failure.
- **`~` is root's home in the helper.** It never reads user config; the tray
  passes what it needs as arguments.
- **Loading the contract writes `__pycache__`** into the directory the helper
  runs out of as root, unless `sys.dont_write_bytecode` is set first. This has
  regressed twice; it is now its own check ("loading the contract writes
  nothing beside the helper").
- **The running applet holds its code in memory.** After `install.sh`, a plain
  `asuvpn reconnect` still runs the old tray. `asuvpn quit` then connect.
- **`asuvpn status` exits 1 while up-but-disconnected.** A liveness probe
  that tests for plain success never sees a freshly started applet as up;
  only exit 3 means "not running". The sandbox scenarios' readiness loop made
  exactly this mistake and silently never succeeded for as long as it
  existed — the long sleeps after it hid that until the scenarios learned to
  assert.

---

## What to do next, roughly in order

1. **Live-verify the routes-lost fix** — now also the state machine's first
   live outing. The rebuild landed 2026-08-23 (eight states, one transition
   table — see DESIGN's state-machine section, which now carries the full
   as-built table (the self-check holds it to the code); git history records
   the rationale and the user's decisions). It is suite- and sandbox-proven;
   live confidence accrues with use, and the flush test doubles as its trial. The break was staged live on
   2026-08-23 (`sudo ip route flush dev asuvpn0`) and defeated the ladder as
   then designed, three ways at once: a same-address `reconnect` does not
   reinstall routes (the stock vpnc-script only routes on `reason=connect`),
   the reconnect event cleared a demotion the probe had never cleared (badge
   flap every ~2 minutes, repeated notifications, sign-in branch unreachable
   even opted in), and the surviving IPv6 routes hid an IPv4-only wipe from a
   summed route count. All three are fixed the same day — demotions now
   survive openconnect's word and are promoted only by the source that
   demoted, the nudge is once per incident, and route families are counted
   separately — with five selftest checks, four of them mutation-verified,
   plus the sandbox scenarios. What remains is one live confirmation: with a
   fresh applet, flush the routes again and expect two strikes → demotion →
   one nudge → the badge *staying* demoted with one warning notification —
   and with `autoreconnect on`, a sign-in within `autoreconnect-min-gap`.
2. **Live-verify the rebuild** (added 2026-08-28, with `autoreconnect` now on
   by default). `autoreconnect` used to gate one rung of the demotion ladder
   and nothing else, so it did nothing for the commonest break there is:
   openconnect gives up after its own 300 s reconnect timeout and the applet
   sat at *Not connected*. The `(failed, rebuild)` row now signs in again, up
   to `MAX_REBUILDS` = 3.

   **What to stage:** suspend the machine for longer than five minutes, then
   wake it. Expect the badge to read `connection dropped; rebuilding`, a
   sign-in within one `autoreconnect-min-gap`, and the tunnel back. Leave the
   WiFi off instead and expect three attempts and then one "gave up"
   notification — not a fourth.

   Suite- and sandbox-proven (`rebuild.sh`, eight mutation-verified checks),
   live-unproven.
3. **Confirm `signin-timeout` against a real Duo push.** Five minutes is
   generous by design, but it is the first thing in this program that can cut
   a sign-in short, and only a live approval taken slowly proves the floor is
   comfortable. If someone hits it legitimately, raise it — the ceiling is
   3600.
4. **Watch how often the Duo pushes actually arrive** now that both automatic
   sign-ins are on by default and share one `autoreconnect-min-gap`. More than
   one every five minutes means a bound is wrong, not that the feature is.
5. **Consider whether `probe-every = 3` is the right frequency** now that a real
   probe costs ~17 ms and one TCP handshake a minute.
6. Leave the polkit prompt alone unless the user reopens it.

---

## How to work on it

```bash
asuvpn selftest                 # run before and after any change; it prints its own tally
tests/sandbox/enter.sh sec.sh   # scenario tests, in a namespace of stand-ins
./install.sh                    # copies into ~/.local, runs the self-check
asuvpn log -f                   # what it is actually doing
```

Analysers (all expected clean) are listed in the README's
[Checking it](README.md#checking-it) section; CI runs them plus the full
self-test on every push (`checks.yml`) and the scenario sandbox on main
(`scenarios.yml`). Releases: bump `VERSION` in
`asuvpn_contract.py` (the single source — the build, `--version`, the menu
and the startup log all read it), commit, then push a matching `v*` tag and
`workflow.yml` publishes to PyPI via Trusted Publishing — registered on pypi.org
as project `asuvpn`, repo `Qing-LAB/ASU_VPN_SSO`, workflow **`workflow.yml`**,
environment **`pypi`**. That filename is matched literally by PyPI, so renaming
the file breaks publishing with an invalid-publisher error after a green build;
change it on pypi.org first if it ever has to move. A version already on PyPI
can never be re-uploaded, so the tag is the point of no return. `DESIGN.md` has the invariants
table and a "Changing things" section saying what to update in lockstep.

**Before claiming anything works, ask how it would look if it did not.** That
question is the whole difference between the bugs in this history and the ones
that were caught.
