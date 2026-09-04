# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting: the **Security** tab of this
repository → **Report a vulnerability**. That opens a private thread visible
only to the maintainers, and it needs no email address on either side.

What helps most, in rough order:

- what an attacker can do that they should not be able to do, stated as an
  outcome rather than as a code smell;
- the smallest sequence that shows it — a command line, a config file, a
  crafted server response;
- which version (`asuvpn --version`) and which distribution.

**Leave real infrastructure out of the report.** Internal hostnames, resolver
and gateway addresses, your tunnel address, session logs and certificate
fingerprints are rarely load-bearing for a proof of concept, and a private
report can still end up quoted in a public commit or a release note when it is
fixed. Use the same placeholders the tests do — `192.0.2.x`, `198.51.100.x`,
`203.0.113.x`, `2001:db8::x`, `example.com` — and say "the gateway's resolver"
rather than naming it. If a specific value really is the bug, say so and we
will handle that thread carefully.

## What to expect

This is a small project maintained alongside other work, so: an
acknowledgement within about a week, and an honest estimate rather than a
promise. Fixes land on `main` and go out as a new release; the report is
credited unless you would rather it were not, and nothing is published before
you have seen the fix.

## Supported versions

| Version | Supported |
| --- | --- |
| the latest release | yes |
| anything older | no — upgrade first |

Pre-1.0, and delivered as a `pipx install` or a `git pull` away from current.
There are no maintenance branches, so "is it fixed in the latest release" is
the only version question with an answer.

## Scope

**In scope** — anything that crosses a privilege or user boundary:

- the root helper (`asuvpn-helper`), which runs under `pkexec`, and the
  `vpnc-script` wrapper (`asuvpn-notify`), which runs as root because
  `openconnect` executes it — a different way in, and worth keeping distinct:
  `asuvpn-notify` is reached with an environment the gateway has a hand in,
  never through a polkit dialog;
- the polkit action, and anything that widens what it authorises;
- the control socket's uid gate — it is an abstract socket with no file
  permissions, so `SO_PEERCRED` is the only thing between another local
  account and your tunnel;
- the event socket between `asuvpn-notify` and the helper;
- anything a **hostile or compromised gateway** can do through the values it
  pushes: resolver addresses, split-DNS domains, routes, the banner, log text;
- the DNS handover — a link configured so that queries meant to stay local go
  down the tunnel, or vice versa, is a security bug, not a cosmetic one;
- teardown leaving a root process alive, or leaving routing or DNS in a state
  the user did not ask for.

**Out of scope**, with somewhere better to send it:

- `openconnect`, `openconnect-sso`, `vpnc-script`, `systemd-resolved`, GTK —
  report upstream; this project wraps them and will pick up their fixes;
- ASU's own VPN service, SAML or Duo configuration — that is ASU IT, not this
  repository, and please do not test against it as though it were;
- the user editing files they own that later run as root. That is the
  documented design: the helper lives in a directory you own, so you and root
  are the same principal here. A *second* account reaching those files **is**
  in scope, in either of two ways — being able to write them, or owning them —
  and the helper refuses both: `unsafe_write_access` rejects world- and
  shared-group-writable paths, and, when the caller is privileged, any path
  owned by a uid that is neither root nor the person who invoked `pkexec`. An
  owner can rewrite their own file whatever its permissions, so ownership is
  part of the question and not a separate one. See
  [`asuvpn_contract.py`](asuvpn_contract.py), the `sec.sh` scenario, and the
  logic tier's ownership checks.

  With one honest exception, worth stating because the list above includes it:
  `asuvpn-helper` also checks **itself**, and against an attacker that is not
  a defence — `pkexec` has already executed the file before any of its code
  runs, so anyone who could rewrite it would simply delete the check. It stays
  on the list because it catches an accidentally widened mode before anyone
  exploits it, and because the file's own permissions are worth reporting. The
  real protection for the other three paths — the directory, `asuvpn-notify`
  and `asuvpn_contract.py` — is genuine: those are read *after* the helper is
  running, and `sec.sh` proves each one refuses before anything executes.

## Where the design is written down

Reading these first will usually tell you whether something is a bug or a
deliberate trade-off, and both name the trade-offs explicitly:

- [README → Security](README.md#security) — what runs as you, what runs as
  root, what it never does, and the polkit options ranked by whether they are
  safe;
- [DESIGN.md → Invariants](DESIGN.md#invariants) — the properties the code
  exists to maintain, each with what enforces it and what checks it;
- `asuvpn selftest` — several of those invariants are checked on the machine
  you are running, including that nothing executed as root is writable by
  anybody else.
