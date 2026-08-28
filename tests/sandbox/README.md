# The scenario sandbox

Scenario tests for the parts of this project that cannot be exercised for real
on every change: a real connect fires a Duo push at a phone, raises a root
password prompt, opens ASU's sign-in page, and builds a real tunnel — and the
most safety-critical code only shows its worth in situations nobody would stage
on a live session ("the tray was `kill -9`'d", "the tunnel went black", "the
helper's files were tampered with").

[`asuvpn selftest`](../../asuvpn-selftest) deliberately does none of this: its
checks never create a tunnel or ask for privileges. This directory is the
other half of the testing story — the half that runs the real programs through
whole lifetimes against stand-ins.

## How the isolation works

`enter.sh` builds an unprivileged **user + mount namespace** (no sudo, no
setuid anything beyond the distribution's own `newuidmap`/`newgidmap`) in
which:

- the four binaries a scenario could otherwise reach for real —
  `/usr/sbin/openconnect`, `/usr/bin/pkexec`, the installed `openconnect-sso`
  and the `vpnc-script` — are covered by bind-mounted stand-ins from
  [`bin/`](bin);
- a **guard refuses to run anything** unless every one of those paths, and
  every PATH lookup of those names, resolves to a stand-in. Two earlier,
  symlink-based arrangements let a test reach a real binary — once opening the
  real ASU sign-in browser — and the guard is why that cannot recur;
- the caller is mapped to uid 0, so the helper's privileged paths (the
  permission refusals, `/run/asuvpn`, teardown as root) are live;
- the caller's `/etc/subgid` block is mapped as well (`--map-auto`), so gids
  other than our own exist inside. That is what lets [`sec.sh`](sec.sh) create
  a file owned by a **second group** and watch the real helper refuse it —
  a predicate unit test cannot prove that end to end; only a second principal
  can. (An earlier single-gid namespace made that scenario a silent no-op: its
  `chgrp` failed with the error discarded, and the helper ran against an
  unchanged file.)
- the fake world gets its **own session bus** (`dbus-run-session`). The tmpfs
  over `/run` hides the real one, and GTK's autolaunch fallback was both slow
  and able to reach the real bus through the abstract socket namespace —
  which is how scenario runs used to raise notifications on the actual
  desktop. Now they land on a bus that dies with the namespace.

The system paths the stand-ins cover are never modified — the bind mounts
vanish with the namespace, which cannot leak the way a symlink arrangement
can. This directory itself does accumulate staged runtime files between runs
(`app/`, `rbin/`, `home/`, `tray.err`, `xauth` — all gitignored; `xauth` is a
0600 copy of your X cookie, refreshed or removed on each `enter.sh` run).

## Keeping the stand-ins honest

A stand-in is only as good as the strings it imitates. An earlier fake printed
`Connected as …`, which the real binary stopped saying in v8 — so every test
passed while the applet was dead against the real openconnect.

Two rules now hold, and `asuvpn selftest` enforces the first mechanically
("the sandbox stand-in only speaks lines from the installed catalogue"):

1. every line [`bin/openconnect`](bin/openconnect) prints either begins with
   `[stand-in] ` — unmistakably harness telemetry, which no real openconnect
   line begins with — or starts with a prefix present in the installed
   binary's own message catalogue;
2. the stand-in drives the **script contract** (`--script` invoked with
   `reason=` in the environment) exactly the way the real binary does, because
   that contract — not log wording — is where state comes from.

## Running scenarios

```bash
tests/sandbox/enter.sh sec.sh        # one scenario
tests/sandbox/enter.sh /bin/bash     # look around the fake world by hand
```

`enter.sh` restages `app/` from the repository on every run, so scenarios
always test the checkout's current code, and writes runtime copies of the
fakes into `rbin/` (the fake `openconnect-sso` needs a shebang naming an
absolute path on this machine — the tray reads that shebang to find the venv
python). `app/`, `rbin/`, `home/` and the other runtime artifacts are
gitignored; nothing in here needs cleaning up by hand.

Every scenario also **refuses to run outside the namespace** (exit 90, with a
pointer to `enter.sh`). The staged `app/` and `rbin/` persist between runs, so
tab-completing a scenario directly used to run the real tray against the real
`pkexec`, `openconnect-sso` and `openconnect` — the exact accident the guard
exists to prevent, now structural at both ends of the door.

Every scenario **asserts its outcome and exits 1 when it is not met**. Six of
them once only printed what happened; a print-only scenario proves nothing,
and these six could not even prove the tray had started — their readiness
loop tested `asuvpn status` for plain success, which the applet answers with
exit 1 while up-but-disconnected, so the loop had silently never succeeded
and the long sleeps after it hid that. The shared plumbing (the guard, the
staged HOME, the proven tray start, the assertion helpers) lives in
[`lib.sh`](lib.sh).

| Scenario | What it proves | Display needed |
| --- | --- | --- |
| `sec.sh` | the permission refusals, on the real helper: world-writable, group-shared, directory, symlink swap — each refused before anything executed, and the normal contrast case NOT refused | no |
| `sec2.sh` | staging positive-control: the `chgrp` to a second group really takes | no |
| `sec3.sh` | negative dpd refused with its documented exit 27; 0 means "leave the server alone"; a normal value reaches openconnect's command line | no |
| `fdcheck.sh` | openconnect's stdin is not the helper's control pipe, so it cannot inject control verbs (fails if it finds no subject to inspect) | no |
| `stubborn.sh` | the teardown ladder's *order*, against a stand-in that ignores SIGINT: SIGINT first, SIGTERM only after the full grace, never SIGKILL against a peer that yields — and a clean exit 0 at the end | no |
| `lifecycle.sh` | connect → reconnect → probes → disconnect → quit, the state asserted at each step, and a healthy tunnel never demoted | yes |
| `discon.sh` | a demoted tunnel still disconnects cleanly: exit 0 and a Disconnected badge (`FAKE_DEAF=1` ignores nudges) | yes |
| `escalate.sh` | the watchdog's ladder: exactly one nudge, then — with autoreconnect on — exactly one full sign-in | yes |
| `watchdog-test.sh` | a gone device: strikes → demotion → exactly one nudge; the reconnect event adopts the tunnel but the badge stays demoted | yes |
| `blackhole.sh` | device and routes healthy, probe target silent → demoted with the probe named in the verdict, one nudge, and a badge that stays demoted because only the probe can promote it | yes |
| `rebuild.sh` | a tunnel that dies outright (`FAKE_DIE_AFTER` models openconnect giving up after its own reconnect timeout) is signed in again unasked — and, because every rebuilt tunnel here dies too, capped at `MAX_REBUILDS` attempts with the give-up said once | yes |
| `contract-test.sh` | the config file drives the helper (`--force-dpd 45` on the real command line) and the CLI autoreconnect toggle lands back in the file | yes |
| `ipc-gate.sh` | the control socket's uid gate, against a real second uid (mapped via `/etc/subuid`): the foreign poke gets no reply and is logged with its uid, while the same raw poke from our own uid is answered — so the refusal is proven non-vacuous | yes |

"Display needed" scenarios start the real tray, which needs GTK and an X
display (`:0` is assumed; on Wayland that is XWayland). `enter.sh` copies the
session's X cookie to `xauth` when `XAUTHORITY` is set. The scenarios that
drive the helper directly run anywhere, headless included.

Scenarios still print what happened for a reader; the assertions are what
make a run mean something. The `sec.sh` assertions are mutation-verified:
neutering the contract's group predicate makes (b2) fail, and neutering the
loader's inline check as well makes (b) fail. The `lib.sh` helpers'
failure paths are exercised too — a `must_contain` miss and an
`await_status` timeout both exit 1, checked against a stub.

## What a pass here does and does not claim

A green scenario proves *our* logic — the state machine, teardown ordering,
refusals, the watchdog — against a modeled openconnect. It does not prove the
model matches the real binary: that is the selftest environment tier's job
(it reads the installed binary's own string table, asks it for its script
path, and checks the stand-in against the same catalogue), and ultimately the
live runs recorded in [HANDOVER.md](../../HANDOVER.md). Keep the two claims
separate; the hand-over's proven/unproven ledger is the place they are
tracked.
