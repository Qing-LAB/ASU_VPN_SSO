# The state-machine revision — consolidated plan

Requested by the user on 2026-08-23, during the full review: *define a real
state machine, write it down with clear transitions and conditions, double-check
the logic, then migrate the code to use it fully and solely — and make the
watchers inject messages into it instead of operating on state directly.*

This document is that plan: what state exists today and who touches it, why
that shape keeps producing bugs, the proposed machine, a migration path in
small verifiable steps, and the decisions that are the user's to make.
**No code moves until this plan is approved.**

---

## 1. Why — the evidence from the 2026-08-23 review

Three of the review's worst findings were the same disease in different limbs.
In every case, a piece of code decided *on its own* that it may change the
applet's state, using a hand-written condition that did not know what the rest
of the program was doing:

1. **A probe verdict stomped a user's Disconnect.** The probe's result callback
   checked "quitting?" and "same tunnel?" but not "tearing down?" — so a strike
   landing mid-teardown rewrote `disconnecting` to `connecting` and handed a
   requested disconnect to the escalation ladder. (Fixed with a guard; the
   event path had the same guard, the probe path simply lacked it. Scattered
   conditions drift apart — that is the disease.)
2. **A timer raced an exit callback into a false FAILED.** GLib runs timers
   ahead of queued idle callbacks, so the watchdog could act on a helper that
   had died before the death was processed, and the late exit callback then
   painted a failure over a healthy recovery. (Fixed with a generation bump —
   again a point guard.)
3. **The ladder skipped an untried free recovery.** The "nudge is rate-limited"
   branch fell through to the paid sign-in because nothing in the shape of the
   code said "wait" — the escalation order lived in comments, not in structure.

There are today **~24 pieces of state** in the tray, written from **five
different execution contexts** (menu handlers, the IPC thread, worker threads
via idle callbacks, the health timer, signal handlers). Each writer carries its
own idea of when it is allowed to write. The review found the three places
where those ideas disagreed; a machine makes disagreement impossible rather
than findable.

## 2. What exists today — the inventory

### 2.1 The state variables (all in `VpnTray`)

| Group | Variables | Written by |
| --- | --- | --- |
| The badge | `state`, `detail`, `_status` | `_set_state` (12 direct callers) |
| Health incident | `health_demoted`, `demoted_by`, `strikes`, `nudge_spent`, `failure_notified`, `routes_seen` | `_adopt_tunnel`, `_reset_tunnel_state`, `_healthy`, `_unhealthy`, `_tunnel_unhealthy`, `_health_check` |
| Tunnel identity | `tunnel_device`, `tunnel_ifindex`, `tunnel_address`, `tunnel_dns`, `tunnel_ever_connected` | `_adopt_tunnel`, `_reset_tunnel_state`, `_on_tunnel_output` (DEVICE line) |
| Rate limits | `last_nudge`, `last_autoreconnect` | `_tunnel_unhealthy` |
| Process handles | `helper_proc`, `helper_exited`, `auth_proc` | `_start_tunnel`, `_on_tunnel_exit`, `_auth_thread`, `_reconnect_now` |
| Generations | `helper_generation`, `auth_generation` | `connect`, `cancel`, `quit`, `_start_tunnel`, `reconnect(force)` |
| Intent flags | `reconnect_pending`, `reconnect_keep_log`, `cancelled`, `quitting` | `reconnect`, `cancel`, `quit`, `connect`, `_reconnect_now`, `_on_tunnel_exit` |
| Probe bookkeeping | `probe_cycle`, `probe_in_flight` | `_health_check`, `_start_probe`, `_probe_result` |
| Sources of truth kept elsewhere | `state_events`, `last_failure`, `helper_spoke` | `_apply_state_event`, `_on_tunnel_output`, `_start_tunnel` |

### 2.2 The message sources (what will become event emitters)

Everything below already *reports* something; today each also *acts*. Under the
machine, each only injects a message.

| Source | Runs on | Today it… | Message(s) it will emit |
| --- | --- | --- | --- |
| Script contract (`[helper] STATE …`) | main loop (via reader idle) | calls `_apply_state_event` → adopts, promotes, announces | `EVT_CONNECTED(dev, addr, dns)`, `EVT_LINK_LOST`, `EVT_DISCONNECT_SEEN` |
| `DEVICE` line | main loop | assigns `tunnel_device` | `EVT_DEVICE(dev)` |
| `FATAL` / `WARNING` lines | main loop | sets `last_failure`, notifies | `EVT_FATAL(sentence)`, `EVT_WARNING(sentence)` |
| Log-pattern fallback | main loop | announces connect / link-lost when no events have arrived | same `EVT_CONNECTED` / `EVT_LINK_LOST`, tagged `source=fallback` |
| Health timer | main loop | runs checks *and* the ladder | `EVT_CHECK(source=device, verdict, facts)` |
| Probe worker | thread → idle | clears latch, strikes, promotes | `EVT_CHECK(source=probe, verdict, facts)` |
| Helper exit | thread → idle | the whole `_on_tunnel_exit` tail | `EVT_HELPER_EXITED(status, generation)` |
| Sign-in completion | thread → idle | starts the tunnel or fails | `EVT_AUTH_OK(host, cookie, fp)`, `EVT_AUTH_FAILED(reason)` |
| User verbs (menu / CLI / signals) | main loop | call `connect`/`disconnect`/… directly | `CMD_CONNECT`, `CMD_DISCONNECT`, `CMD_RECONNECT`, `CMD_CANCEL`, `CMD_QUIT` |
| Watchdog escalation | (becomes machine-internal) | nudges / signs in | *(an action, not a message)* |

## 3. The proposed machine

### 3.1 Shape

One `dispatch(message)` function, running **only on the GLib main loop** (the
sources already funnel there via `idle_add`, so no new thread machinery is
needed). It looks up `(current_state, message_type)` in a transition table,
evaluates the entry's *condition*, performs its *actions*, and moves to its
*next state*. Nothing else in the program assigns `self.state` or the incident
fields — that is the "fully and solely" in the user's direction.

Actions are the side effects the machine orders: set the badge, log a line,
notify, send a control verb, spawn a sign-in, start a teardown, arm a probe.
Workers still run on threads; they report back only as messages.

### 3.2 States

Eight, replacing six-plus-flags. `DEMOTED` and `RECOVERING` stop hiding inside
`CONNECTING`:

| State | Meaning | Today's spelling |
| --- | --- | --- |
| `DISCONNECTED` | nothing running | same |
| `AUTHENTICATING` | sign-in in flight | same |
| `CONNECTING` | cookie handed over, tunnel not up yet | same |
| `CONNECTED` | up and believed healthy | same |
| `RECOVERING` | openconnect itself is re-establishing (its own retry) | `CONNECTING` after `attempt-reconnect` |
| `DEMOTED` | established but not carrying traffic (the watchdog's verdict) | `CONNECTING` + `health_demoted` |
| `DISCONNECTING` | teardown in progress; **absorbing** — only `EVT_HELPER_EXITED` leaves it | same |
| `FAILED` | dead, with the reason kept | same |

The incident bookkeeping (`demoted_by`, `nudge_spent`, `failure_notified`,
`routes_seen`, strike counters, rate-limit stamps) becomes the machine's
private *extended state* — readable by conditions, writable only by actions.

### 3.3 The transition table (the artifact to review)

The full table is written out below in the exact form the code will consume —
one row per `(state, message)`, with condition, actions, and next state. Rows
marked ▲ encode behavior that is live-proven today and must survive verbatim.

| State | Message | Condition | Actions | Next |
| --- | --- | --- | --- | --- |
| DISCONNECTED / FAILED | CMD_CONNECT | — | rotate log, start sign-in | AUTHENTICATING |
| AUTHENTICATING | EVT_AUTH_OK | generation current | spawn helper, feed cookie | CONNECTING |
| AUTHENTICATING | EVT_AUTH_FAILED | — | keep sentence, notify | FAILED |
| AUTHENTICATING / CONNECTING | CMD_CANCEL | — | kill sign-in / terminate pkexec, begin teardown if helper lives | DISCONNECTING or DISCONNECTED |
| CONNECTING | EVT_CONNECTED | — | adopt tunnel ▲, announce (first vs re-) ▲ | CONNECTED |
| CONNECTED | EVT_LINK_LOST | — | announce "link lost, retrying" ▲ | RECOVERING |
| RECOVERING | EVT_CONNECTED | — | adopt, announce reconnected ▲ | CONNECTED |
| CONNECTED | EVT_CHECK bad | strikes(source) just reached threshold | demote; try ladder step (§3.4) ▲ | DEMOTED |
| CONNECTED / RECOVERING | EVT_CHECK bad | below threshold | count the strike, log it ▲ | *(same)* |
| RECOVERING | EVT_CHECK * | — | stand aside — openconnect owns its own retry ▲ | RECOVERING |
| DEMOTED | EVT_CONNECTED | — | **adopt only** — reset family latch iff new ifindex ▲; never promote, never reset the incident ▲ | DEMOTED |
| DEMOTED | EVT_CHECK good | source == demoted_by | promote, reset incident, notify "carrying traffic again" ▲ | CONNECTED |
| DEMOTED | EVT_CHECK good | source != demoted_by | clear that source's strikes only ▲ | DEMOTED |
| DEMOTED | EVT_CHECK bad | threshold reached again | ladder step (§3.4) ▲ | DEMOTED or DISCONNECTING |
| DEMOTED | CMD_CONNECT | — | delegate: same as CMD_RECONNECT ▲ | DISCONNECTING |
| CONNECTED / DEMOTED | CMD_DISCONNECT / CMD_RECONNECT / CMD_QUIT | — | begin teardown (reconnect/quit remember intent) ▲ | DISCONNECTING |
| DISCONNECTING | EVT_CHECK / EVT_CONNECTED / EVT_LINK_LOST / EVT_FATAL | — | **drop** — teardown has decided how this ends ▲ | DISCONNECTING |
| DISCONNECTING | EVT_HELPER_EXITED | generation current | report per intent (asked-for → "disconnected"; reconnect → sign in again; quit → exit) ▲ | DISCONNECTED / AUTHENTICATING / *(exit)* |
| any | EVT_HELPER_EXITED | generation stale | log "[old tunnel] closed" only ▲ | *(same)* |
| CONNECTED / RECOVERING | EVT_HELPER_EXITED | current | explain (FATAL sentence > "connection dropped" > status) ▲ | FAILED |
| any | EVT_FATAL | — | keep the sentence for the exit report ▲ | *(same)* |

### 3.4 The ladder as a condition chain (inside the DEMOTED bad-check action)

Ordered, first match wins — this is today's fixed behavior, now as data:

1. nudge not spent **and** `nudge-min-gap` elapsed → send nudge, mark spent,
   notify "reconnecting" once ▲
2. nudge not spent, gap **not** elapsed → log "holding", **wait** (never skip
   ahead) ▲
3. otherwise → warn once per incident ▲; then: autoreconnect off → log and
   hold ▲; its gap open → log the wait ▲; else → sign in (`keep_log`) ▲

### 3.5 The injection rule

`_apply_state_event`, the fallback pattern matcher, `_health_check`,
`_probe_result`, and `_on_tunnel_exit` stop calling `_set_state`,
`_adopt_tunnel`, `reconnect` or each other. Each shrinks to: parse → build
message → `dispatch(message)`. The log watcher in particular becomes exactly
what the user specified: a reader that *provides the correct message* and
never operates the machine.

## 4. What must not be lost (each becomes a table row or test)

- One reaper per child; `helper_exited` Event ordering (exit message queued
  before the event is set).
- Generation checks on every helper/auth/probe message.
- Teardown is absorbing; `force` never overrides it.
- Rate-limit stamps survive resets; incident survives openconnect's word.
- Per-source promotion; per-family route latch; latch reset on new ifindex.
- Log rotation on user connect only; `keep_log` on automatic recovery.
- The cookie's path (stdin only) and every permission property — untouched by
  this work.

## 5. Migration, in verifiable steps

Each step lands alone, with `asuvpn selftest` green, the analysers clean, the
scenario suite green, and one commit:

1. **Table first, no behavior change.** Add the machine module (plain dict
   table + `dispatch`; stdlib only — no new dependencies), with the selftest
   driving it purely as data: feed message sequences, assert states. The
   applet does not use it yet.
2. **Shadow mode.** The applet feeds real messages to the machine *alongside*
   the existing code and logs any disagreement (`[machine] would be X, is Y`).
   Run the scenario suite and a real session; the log must show zero
   disagreements. This is the double-check the user asked for, done against
   reality.
3. **Cut over the badge.** `_set_state` becomes machine-internal; the old
   call sites become messages. Scenarios + a live connect/disconnect.
4. **Cut over the watchdog** (checks emit `EVT_CHECK`; ladder becomes §3.4
   data). Re-run the routes-flush live test.
5. **Cut over teardown/exit intent flags** (`reconnect_pending`, `cancelled`,
   `quitting` become states/intent in the machine).
6. **Delete the guards** the review added (probe-teardown guard, generation
   bump, held-nudge return) — the table now makes them structural. Mutation
   tests move from guarding code lines to corrupting table rows.

Rollback at every step is `git revert` of one commit.

## 6. Verification additions

- The transition table is data, so the selftest gains a **table-driven tier**:
  every ▲ row exercised by feeding its message sequence to a machine instance.
- The sandbox scenarios stay as-is (they test through the real programs) and
  keep their assertions.
- Mutation testing gets cheaper and stronger: flip one table cell, one check
  fails.
- Live checklist after step 4: the WiFi-loss, suspend, and routes-flush
  exercises from HANDOVER, re-run once each.

## 7. Decisions that are yours

1. **State shape** — the plan proposes eight flat states (§3.2). The
   alternative is two layers (connection × health); flat is simpler to read
   and test, layered avoids near-duplicate rows. *Recommendation: flat.*
2. **Scope** — tray only (proposed), or also restructure the helper the same
   way. The helper is small, already message-shaped, and live-proven; touching
   it buys little. *Recommendation: tray only.*
3. **Framework** — hand-rolled table (proposed, ~100 lines, stdlib only) vs a
   dependency. A dependency conflicts with "system python, nothing installed".
   *Recommendation: hand-rolled.*
4. **Shadow-mode duration** — how long step 2 runs against your real sessions
   before cutting over: one day of normal use is the proposal.
5. **When** — this plan can start as the next work item, or wait until after
   the routes-lost live re-verification (HANDOVER item 2). They are
   independent; doing the live check first pins today's behavior tighter
   before the migration reproduces it. *Recommendation: live check first.*
