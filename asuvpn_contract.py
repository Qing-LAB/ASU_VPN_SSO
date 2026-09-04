"""The agreement the ASU VPN programs share.

Everything here is something more than one program has to know: the wire format
the helper speaks to the tray, the verbs the tray speaks back, the fields
asuvpn-notify puts on the event socket, the reasons openconnect reports, and the
settings a user may change. Each of those used to be restated wherever it was
needed, and most had already drifted — five message prefixes each parsed by its
own string test, two unrelated config mechanisms, and nine tunables split across
two programs with no way to change any of them.

**Loaded by explicit path, never through sys.path.** asuvpn-helper and
asuvpn-notify run isolated (-I) so that their own directory is *not* importable
— that is what stops a signal.py dropped beside them being executed as root —
and asuvpn-tray is reached through a symlink in a different directory from its
siblings. An explicit path is the one form correct for all three.

Loading this is exactly as trusting as running the program that loads it: same
directory, same owner. The programs that run privileged re-check that directory
for write access by a second principal before executing anything, so the trust
is verified rather than assumed — see the bootstrap note at the foot of this
file.

Settings are read on the *user* side only. The helper runs as root, where `~`
is root's home, so it takes what it needs as explicit arguments rather than
reading a file owned by somebody else.
"""

import os
import re
import stat

# The release version, stated once. pyproject.toml reads it from this line at
# build time (hatchling's version pattern), `asuvpn --version` prints it, the
# applet logs it at startup and shows it at the bottom of its menu, and the
# self-test banner reports it. Distinct from CONTRACT_VERSION below, which
# tracks the wire format and moves only when the programs must agree anew.
VERSION = "0.11.0"

# Bumped when the wire format changes in a way the programs must agree on.
# `asuvpn selftest` reports it, and the header of a generated config file
# records the version that wrote it. It cannot catch a half-updated install by
# itself — every program loads the one copy beside it, so within one install
# there is nothing to disagree with.
CONTRACT_VERSION = 2


# --------------------------------------------------------------- permissions


def unsafe_write_access(path, trusted_uids=None):
    """Why `path` may be written by somebody we do not trust, or None.

    Group-writable is not automatically a finding. Debian and Ubuntu default to
    umask 002 with user-private groups, so a plain git checkout is 0775 with
    gid == uid — the "group" is one person, and refusing there would break
    --link mode for no gain. A *shared* group is a second principal, and
    world-writable always is.

    **The owner is a principal too.** The mode bits say who *besides* the owner
    may write; they say nothing about who the owner is, and an owner may always
    rewrite their own file whatever the mode. So a file belonging to another
    user at a perfectly ordinary 0644 passed this test for as long as it only
    looked at permissions — and `install.sh --link` from a checkout somebody
    else owns is a documented, supported way to arrive at exactly that. Their
    next edit would then run as root at our next connect.

    `trusted_uids` is who may own it: root, and the human who invoked us. It is
    passed in rather than discovered here because only the caller knows which
    human that is — under pkexec it is PKEXEC_UID, not geteuid(). When it is
    None the ownership question is not asked at all, which is right for an
    unprivileged caller checking its own files.
    """
    try:
        st = os.stat(path)
    except OSError:
        return None
    if st.st_mode & stat.S_IWOTH:
        return "world-writable"
    if st.st_mode & stat.S_IWGRP and st.st_gid != st.st_uid:
        return f"writable by group {st.st_gid}"
    if trusted_uids is not None and st.st_uid not in trusted_uids:
        return (f"owned by uid {st.st_uid}, who is neither root nor the user"
                " asking for this — its owner can rewrite it at any time")
    return None


# ------------------------------------------------- helper -> tray, one line


# The helper's own messages and openconnect's output share a single pipe, so
# each line says which it is. Without the framing a VPN banner containing
# "[helper] WARNING:" could raise a desktop notification with text the server
# chose, or "[helper] STATE connected" could drive the badge.
MESSAGE_PREFIX = "[helper]"
RELAY_PREFIX = "[vpn]"

KIND_NOTE = "NOTE"        # informational; logged as-is, raises no notification
KIND_WARNING = "WARNING"  # needs attention: most seriously, the network may
                          # not have been restored; also degraded supervision
KIND_FATAL = "FATAL"      # refused before openconnect ever started
KIND_STATE = "STATE"      # a transition from openconnect's script contract
KIND_DEVICE = "DEVICE"    # the tunnel device this session will create
KINDS = (KIND_NOTE, KIND_WARNING, KIND_FATAL, KIND_STATE, KIND_DEVICE)


def encode_message(kind, payload=""):
    """One framed line, newline included.

    The kind is always explicit on the wire even for a plain note. Leaving it
    implicit would mean deciding what a line is by reading its words, which is
    the coupling this file exists to remove.
    """
    if kind not in KINDS:
        raise ValueError(f"unknown message kind: {kind!r}")
    return f"{MESSAGE_PREFIX} {kind} {one_line(payload)}".rstrip() + "\n"


def decode_message(line):
    """(kind, payload) if this is a helper message, else None.

    None means openconnect said it, not us — including anything that merely
    looks like a helper message, because the relay prefixes every line it
    forwards and nothing else can reach this pipe.
    """
    text = line.rstrip("\n")
    if not text.startswith(MESSAGE_PREFIX + " "):
        return None
    rest = text[len(MESSAGE_PREFIX) + 1:]
    kind, _, payload = rest.partition(" ")
    if kind not in KINDS:
        return None
    return kind, payload


def encode_relay(line):
    """One line of openconnect's output, framed so it cannot forge a message."""
    return f"{RELAY_PREFIX} {line.rstrip(chr(10))}\n"


def strip_relay(line):
    """Display form: framing is how we keep the pipe honest, not something to show."""
    return line[len(RELAY_PREFIX) + 1:] if line.startswith(RELAY_PREFIX + " ") else line


# ---------------------------------------------------- tray -> helper, stdin


# The pipe is the disconnect signal, so the verbs are few and each is a whole
# line. Anything unrecognised is ignored rather than guessed at. A "disconnect"
# verb was defined here once, accepted by the helper and sent by nothing —
# closing the pipe *is* the disconnect — and a verb with no sender is drift
# waiting to happen, so it is gone. (A CONTROL_STOP set outlived it for a
# while; with one member it said nothing CONTROL_QUIT does not.)
CONTROL_QUIT = "quit"
CONTROL_RECONNECT = "reconnect"
CONTROL_VERBS = (CONTROL_QUIT, CONTROL_RECONNECT)


def encode_control(verb):
    if verb not in CONTROL_VERBS:
        raise ValueError(f"unknown control verb: {verb!r}")
    return verb + "\n"


def decode_control(line):
    """The verb on this line, or None. Blank lines and noise are not verbs."""
    verb = line.strip().lower()
    return verb if verb in CONTROL_VERBS else None


# ------------------------------------------------ asuvpn-notify -> helper


# Set by the helper in openconnect's environment, which passes them through to
# the script. Named here so the two ends cannot disagree about them.
# Written by asuvpn-notify into the helper's own /run/asuvpn session directory
# when it has put DNS on the link, removed when it takes it off again. The
# helper reads it at teardown: whether DNS is ours is a fact about what
# happened, and it used to be inferred from whether the user had asked for it.
DNS_MARKER = "dns-on-link"

EVENT_SOCKET_VAR = "ASUVPN_EVENT_SOCKET"
EVENT_TOKEN_VAR = "ASUVPN_EVENT_TOKEN"
REAL_SCRIPT_VAR = "ASUVPN_REAL_SCRIPT"
# Which domains to route to the tunnel's resolver when the gateway names none
# itself. Computed by the helper, which is the only part of this that knows the
# gateway's name and the user's setting; asuvpn-notify only applies it. Carried
# in the environment rather than on the event socket because it travels the
# other way -- helper to script, not script to helper.
DNS_DOMAINS_VAR = "ASUVPN_DNS_DOMAINS"
EVENT_VARS = (EVENT_SOCKET_VAR, EVENT_TOKEN_VAR, REAL_SCRIPT_VAR,
              DNS_DOMAINS_VAR)

# The environment variables openconnect itself sets, in the order they travel.
# `reason` is lower case because that is what the vpnc-script contract calls it.
#
# CISCO_DEF_DOMAIN and CISCO_SPLIT_DNS -- the gateway's own answer to which
# names live behind this tunnel -- are deliberately *not* here. asuvpn-notify is
# the only thing that needs them and it reads them from the environment it was
# run in; putting them on the wire as well would add two fields nothing at the
# receiving end reads, which is how a contract starts describing something other
# than what its programs do.
EVENT_ENV = ("reason", "TUNDEV", "INTERNAL_IP4_ADDRESS", "INTERNAL_IP6_ADDRESS",
             "INTERNAL_IP4_DNS")
EVENT_FIELDS = ("token", *EVENT_ENV)
EVENT_SEPARATOR = "\t"
EVENT_MAX_BYTES = 4096


def encode_event(token, environ):
    """One datagram: the token, then each contract variable in order.

    Separators are stripped from every value rather than trusted absent. A tab
    would split one field into two and a newline would end the datagram early.
    """
    parts = [token] + [str(environ.get(name, "")) for name in EVENT_ENV]
    cleaned = (p.replace(EVENT_SEPARATOR, " ").replace("\n", " ") for p in parts)
    return EVENT_SEPARATOR.join(cleaned).encode("utf-8", "replace")[:EVENT_MAX_BYTES]


def decode_event(data):
    """A dict of the contract fields, or None if this is not one of ours.

    Length is checked before anything is indexed. Callers still have to compare
    the token with `secrets.compare_digest`; that is deliberately not done here,
    because a contract file is the wrong place to hold an opinion about how a
    secret is compared.
    """
    parts = data.decode("utf-8", "replace").split(EVENT_SEPARATOR)
    if len(parts) < len(EVENT_FIELDS):
        return None
    # strict=False on purpose: a sender from a newer contract may append
    # fields this one does not know, and dropping them is the correct response
    # to that -- refusing the whole datagram would not be.
    return dict(zip(EVENT_FIELDS, parts, strict=False))


# ------------------------------------------------ openconnect's own contract


# openconnect runs vpnc-script at every transition with the state in the
# environment. These five values are inherited from vpnc, documented, and
# unchanged across the v7-to-v8 rename that silently broke log matching.
# pre-init is absent on purpose: nothing is configured yet.
#
# The wire words a STATE line may carry. Named here because both ends need
# them: the helper writes them, the tray decides what each means in its
# current state. They were bare literals at both ends once, which is the
# restated-fact drift this file exists to remove.
STATE_CONNECTED = "connected"
STATE_CONNECTING = "connecting"
STATE_DISCONNECTED = "disconnected"
REASON_STATES = {
    "connect": STATE_CONNECTED,
    "reconnect": STATE_CONNECTED,
    "attempt-reconnect": STATE_CONNECTING,
    "disconnect": STATE_DISCONNECTED,
}

# IFNAMSIZ is 16 including the NUL. Anything outside this cannot name a device,
# and unchecked it would reach an `ip link delete` running as root, or be
# interpolated into a path under /sys. \Z, not $: a dollar also matches just
# before a trailing newline, so "asuvpn0\n" passed as a device name.
INTERFACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}\Z")

# A gateway, as the sign-in hands it over and as openconnect will be given it.
#
# Anchored, and it must not start with "-". That is the whole point: this value
# becomes the *last* element of a root command line, and getopt_long permutes,
# so openconnect reads options that follow the server just as it reads ones
# before it -- measured, not assumed. A --host of "-b" is therefore not a
# server at all but --background, which fork()s away from PR_SET_PDEATHSIG and
# leaves a root openconnect nothing can reach, and "--config=/tmp/opts"
# re-admits every option UNSUPPORTED_OPTIONS exists to refuse. The blocklist
# only ever saw the passthrough arguments, so this door stood open beside it.
#
# The scheme is optional because the helper accepts a bare hostname too, and
# host_domain() already copes with both.
GATEWAY_RE = re.compile(r"^(?:https?://)?"
                        r"[A-Za-z0-9]([A-Za-z0-9._-]{0,252}[A-Za-z0-9])?"
                        r"(?::[0-9]{1,5})?"
                        r"(?:[/?][A-Za-z0-9._~!$&'()*+,;=:@%/?-]*)?\Z")

# The certificate pin. It cannot become an option -- openconnect takes it as
# the argument of --servercert, whatever it looks like -- so this is narrower
# than it needs to be for safety and exists to catch a sign-in that returned
# something other than a pin.
FINGERPRINT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:+/=_.-]{0,200}\Z")


def valid_gateway(value):
    """Is this safe to hand a root openconnect as the server to connect to?"""
    return bool(GATEWAY_RE.match(str(value or "").strip()))


def valid_fingerprint(value):
    """Does this look like a certificate pin rather than anything else?"""
    return bool(FINGERPRINT_RE.match(str(value or "").strip()))
INTERFACE_PREFIX = "asuvpn"

# What we present to the gateway. Both the tray (which passes it) and the
# helper (which needs a default for a direct caller) must say the same one; it
# was stated in each and could drift.
AC_VERSION = "4.7.00136"

# Only a last resort, shared by the helper (when the binary will not name its
# own default) and asuvpn-notify (when run as a vpnc-script by hand). The real
# path is asked of `openconnect --version`; it differs between distributions.
FALLBACK_VPNC_SCRIPT = "/usr/share/vpnc-scripts/vpnc-script"


# ------------------------------------------------- what all three programs read


def interface_index(name):
    """The kernel's ifindex for a device, or None if it has none right now.

    ifindex is monotonic, so it identifies one *incarnation* of a name, which
    is what tells "our tunnel is still here" from "a device with the same name
    is here". Two helpers racing can both pick the free name asuvpn0; the
    loser's openconnect fails, but at teardown it would find asuvpn0 present
    and delete the winner's live tunnel. Comparing the index taken once the
    tunnel was up proves the device still is the one we created.

    Here rather than in each program because it was written out twice, byte for
    byte, under two names -- and one of those copies carried a docstring
    warning that hand-copying a /sys read is how a fix to one of them gets
    lost. This file exists for facts more than one program needs; a four-line
    read is still a fact.
    """
    try:
        with open(f"/sys/class/net/{name}/ifindex") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


# systemd's own tool, and the one the stock vpnc-script reaches for on a machine
# where it detects resolved. Absolute paths and no PATH lookup: asuvpn-notify
# calls this as root, in an environment openconnect handed it.
RESOLVECTL_PATHS = ("/usr/bin/resolvectl", "/bin/resolvectl")

# Generous for a call that answers in milliseconds; the point is that there is a
# bound at all. openconnect waits for the script, so a resolved that has wedged
# must cost the connection a few seconds rather than hang it -- and the tray
# must not freeze for longer than that with its menu open.
RESOLVECTL_TIMEOUT = 5


def resolvectl_path():
    """Where resolvectl is, or None if this machine has none.

    Both ends of the DNS work ask this -- asuvpn-notify to configure a link,
    the tray to read one back -- and they asked it two different ways before
    this existed, which is two chances to disagree about whether the machine
    has systemd-resolved on it.
    """
    for path in RESOLVECTL_PATHS:
        if os.access(path, os.X_OK):
            return path
    return None


# ------------------------------------------------------------------ split DNS
#
# A split tunnel wants split DNS: the names that live behind the tunnel are
# resolved by the tunnel's resolver, and every other name stays on whatever
# resolver the machine already had. systemd-resolved expresses that as per-link
# configuration -- servers on the link, plus the domains that route to it -- and
# a domain listed on a link both completes single-label names and routes
# matching queries there, which is the whole of what is needed.
#
# The alternative, which is what the stock vpnc-script falls back to on a
# machine without nss-resolve, is rewriting /etc/resolv.conf. That file cannot
# express "these names here, the rest there" at all -- it is one flat global
# list -- and where it is systemd-resolved's own stub it belongs to another
# daemon, which rewrites it again at the next link change and silently takes the
# tunnel's resolver back out. See README, "DNS, and why it is not written to
# /etc/resolv.conf", and DESIGN, "Who owns DNS".

# A domain name, as strictly as is useful. These are about to become arguments
# to a program run as root, so the rule is a whitelist and not a blacklist: no
# leading dash (which would parse as an option), no whitespace, no shell
# punctuation, nothing but the characters a hostname may contain. The trailing
# dot of a fully qualified name is accepted and stripped by split_domains.
DOMAIN_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?"
                       r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?)+\Z")

# Enough for a gateway that pushes a long split-DNS list, few enough that a
# hostile one cannot make the command line unbounded.
MAX_DNS_DOMAINS = 32


def split_domains(*values):
    """Domain names from any mix of comma- and space-separated lists, deduped.

    openconnect hands CISCO_DEF_DOMAIN as a single domain and CISCO_SPLIT_DNS as
    a comma-separated list, but the two have been seen to arrive in each other's
    form, so both separators are accepted from both. Order is preserved because
    the first search domain is the one a single-label name is tried in first.

    Anything DOMAIN_RE does not accept is dropped rather than escaped. A domain
    that cannot be a domain has no business reaching a root command line, and
    there is nothing useful to do with it besides leave it out.
    """
    out = []
    for value in values:
        for word in str(value or "").replace(",", " ").split():
            domain = word.strip().rstrip(".").lower()
            if DOMAIN_RE.match(domain) and domain not in out:
                out.append(domain)
    return out[:MAX_DNS_DOMAINS]


def split_resolvers(*values):
    """Resolver addresses from space-separated lists, deduped, order kept.

    Held to the same rule as the domains beside them, and for the same reason:
    these become arguments to a program run as root, and a gateway that pushed
    "--something" would otherwise have handed it an option. ip_address is the
    check because it is exact: anything that is not a literal address is
    dropped. A scoped IPv6 address (fe80::1%asuvpn0) passes, which is right --
    resolvectl takes those, and the scope is part of the address.

    **Returned in canonical form, not as the gateway spelled it.** An IPv6
    address has many spellings and resolvectl echoes back systemd's, so a
    gateway pushing 2001:0db8::1 would have the tray hunting the link for that
    string while resolvectl reported 2001:db8::1 -- a resolver that is present
    and correct, reported missing, every twenty seconds, on a working tunnel.
    Normalising here fixes it for both ends at once: this is also the form
    asuvpn-notify installs. It makes the dedup below exact for the same reason.

    Order matters: the first resolver is the one asked first, and it is also
    the one the tray takes as its liveness probe target.
    """
    import ipaddress

    out = []
    for value in values:
        for word in str(value or "").replace(",", " ").split():
            try:
                address = str(ipaddress.ip_address(word))
            except ValueError:
                continue
            if address not in out:
                out.append(address)
    return out[:MAX_DNS_DOMAINS]


def parent_domain(host):
    """The domain a gateway's own name sits in: vpn.example.com -> example.com.

    The last resort for "which names belong to this VPN" when the gateway names
    none. It is a guess, but a well-founded one -- a university's VPN endpoint
    lives in the domain whose private names it exists to reach -- and it is
    derived from the endpoint the user actually configured rather than written
    into the source, so this file holds no opinion about whose VPN this is.

    A bare hostname or a two-label name yields nothing: better no routing
    domain, and DNS that plainly does not resolve, than a domain so broad that
    every query on the machine is sent down the tunnel.

    An address is not a name. DOMAIN_RE accepts "192.0.2.10" -- every label is
    alphanumeric -- so without this an endpoint configured by IP produced the
    routing domain "0.2.10": a name nothing will ever match, silently scoping
    the link to nothing while the log reported success. Refusing here falls
    through to the no-domains branch, which at least resolves.

    Known limit: this counts labels, so a name under a two-part public suffix
    (vpn.co.uk) yields "co.uk", which is too broad. Resolving that properly
    needs the public suffix list, which is not worth a dependency here -- set
    dns-domains explicitly on such an endpoint.
    """
    import ipaddress

    text = str(host or "").strip().strip(".")
    try:
        ipaddress.ip_address(text)
        return ""          # an address has no parent domain
    except ValueError:
        pass
    labels = split_domains(text)
    if not labels:
        return ""
    parts = labels[0].split(".")
    return ".".join(parts[1:]) if len(parts) > 2 else ""


def one_token(value):
    """Collapse a value to a single whitespace-free token."""
    return re.sub(r"\s+", "_", str(value).strip())[:64]


def one_line(value):
    """Collapse a value to a single line, so it cannot end a framed message."""
    return re.sub(r"[\r\n]+", " ", str(value)).rstrip()


# ------------------------------------------------------------- the settings


class Setting:
    """One knob: how it is spelled, what it means, and what it is when unset.

    `minimum` and `maximum` refuse values the setting's own documentation
    rules out — a teardown wait shorter than the signal escalation it must
    outlast, a log-keep so large that rotation would stall the applet. A
    refused value costs that line its default and earns a [config] sentence,
    like any other unparseable line.
    """

    __slots__ = ("default", "kind", "maximum", "minimum", "name", "summary")

    def __init__(self, name, kind, default, summary, minimum=None, maximum=None):
        self.name = name
        self.kind = kind
        self.default = default
        self.summary = summary
        self.minimum = minimum
        self.maximum = maximum

    def parse(self, text):
        """The value this text denotes. ValueError if it denotes nothing."""
        if self.kind == "bool":
            lowered = text.strip().lower()
            if lowered in ("on", "true", "yes", "1"):
                return True
            if lowered in ("off", "false", "no", "0"):
                return False
            raise ValueError("expected on or off")
        if self.kind == "int":
            value = int(text.strip())
            if value < 0:
                raise ValueError("cannot be negative")
            if self.minimum is not None and value < self.minimum:
                raise ValueError(f"must be at least {self.minimum}")
            if self.maximum is not None and value > self.maximum:
                raise ValueError(f"cannot exceed {self.maximum}")
            return value
        return text.strip()

    def render(self, value):
        if self.kind == "bool":
            return "on" if value else "off"
        return str(value)


SETTINGS = (
    Setting("server", "text", "sslvpn.asu.edu",
            "The VPN endpoint. Set by install.sh --server."),
    Setting("autoreconnect", "bool", True,
            "Sign in again by itself when a stalled tunnel cannot be recovered"
            " for free. On by default: it is the last rung of the ladder, so it"
            " is reached only after the free re-establish has been tried and"
            " demonstrably did not work. Costs a Duo push and a password each"
            " time it fires -- turn it off to be asked first."),
    Setting("dpd", "int", 30,
            "Seconds between dead-peer probes, forced on because some servers"
            " negotiate detection off and then a dropped tunnel looks connected."
            " 0 leaves the server's choice alone."),
    Setting("dns", "bool", True,
            "Hand the resolver the VPN pushes to systemd-resolved as per-link"
            " DNS, with the tunnel's domains routed to it and everything else"
            " left on the resolver this machine already had. This is what makes"
            " a split tunnel resolve internal names without sending every"
            " lookup on the machine to the VPN. Turn it off to leave DNS to the"
            " stock vpnc-script, which on a machine without nss-resolve"
            " rewrites /etc/resolv.conf -- and loses the change again the next"
            " time systemd-resolved rewrites its own file. Ignored where"
            " systemd-resolved is not running; there is nothing to hand it."),
    Setting("dns-domains", "text", "",
            "Domains to resolve through the tunnel, space or comma separated,"
            " when the gateway names none itself. Empty means derive one from"
            " the server address -- vpn.example.com gives example.com -- which"
            " right wherever the endpoint lives in the domain it serves. What"
            " the gateway does push always wins over both."),
    Setting("health-interval", "int", 20,
            "Seconds between checks of the tunnel device and its routes."
            " 0 turns the watchdog off; this file is still re-read at the"
            " default cadence, so turning it back on needs no restart."),
    Setting("health-strikes", "int", 2,
            "Consecutive bad checks before the badge stops claiming Connected."
            " Two, because routes are briefly absent during a real reconnect."
            " 0 behaves as 1."),
    Setting("probe", "bool", True,
            "Ask the network whether the tunnel still carries traffic. This is"
            " the only check that catches a tunnel whose device and routes are"
            " perfectly healthy but which delivers nothing."),
    Setting("probe-target", "text", "",
            "Address to probe. Empty means whatever resolver the VPN itself"
            " pushed, which is the right answer on every network it is used on."),
    Setting("probe-port", "int", 53,
            "Port for the probe, 1-65535. Nothing is sent; a refusal counts as"
            " alive, because a RST proves a packet crossed in each direction."
            " 0 is refused: it is not a connectable port, so every probe would"
            " silently come back inconclusive and the watchdog's probe half"
            " would be blind while claiming to watch.",
            minimum=1, maximum=65535),
    Setting("probe-every", "int", 3,
            "Run the probe on every Nth health check, so it costs a packet a"
            " minute rather than one every twenty seconds. 0 behaves as 1,"
            " probing on every check."),
    Setting("probe-timeout", "int", 5,
            "Seconds to wait for an answer. A healthy tunnel replies in"
            " milliseconds, so this is generous by two orders of magnitude."
            " Capped at 120: only one probe runs at a time, so an answer that"
            " never comes would otherwise block probing for as long as this.",
            maximum=120),
    Setting("nudge-min-gap", "int", 120,
            "Seconds between asking openconnect to re-establish. Free, but not"
            " something to do every time a check fails."),
    Setting("autoreconnect-min-gap", "int", 300,
            "Seconds between automatic sign-ins, when autoreconnect is on."
            " One budget, shared: a stalled tunnel's escalation and a dropped"
            " tunnel's rebuild both spend it, so neither can starve the other"
            " of the gap the user asked for."),
    Setting("signin-timeout", "int", 300,
            "Seconds each half of a connect may wait on a human before it is"
            " abandoned: the browser window and its Duo approval, and then the"
            " authorization prompt. Generous, because both are things somebody"
            " has to do -- but each has to end. A rebuild that runs with nobody"
            " at the keyboard would otherwise sit in Signing in... behind a"
            " login window, or in Connecting... behind a password dialog"
            " polkit will never time out, and only Cancel would clear it."
            " Held to 60-3600; there is deliberately no off.",
            minimum=60, maximum=3600),
    Setting("teardown-timeout", "int", 75,
            "Seconds to wait for the helper to finish. Must outlast its own"
            " signal escalation of 15 + 10 + 5 plus the routing check after,"
            " so values below 35 are refused: a shorter wait reports every"
            " clean disconnect as a failure while the helper is still fine.",
            minimum=35),
    Setting("log-max-kb", "int", 4096,
            "Size the session log may reach before it is rotated, in KiB."
            " 0 means never rotate on size."),
    Setting("log-keep", "int", 3,
            "Rotated logs kept beside the current one; session.log.1 is the"
            " newest. Connecting rotates too, so this is also how many past"
            " sessions survive. 0 keeps none, and rotation just truncates."
            " Capped at 99: every rotation walks the whole numbered chain.",
            maximum=99),
)
SETTINGS_BY_NAME = {s.name: s for s in SETTINGS}
CONFIG_BASENAME = "asuvpn.conf"


def defaults():
    return {s.name: s.default for s in SETTINGS}


def parse_settings(text):
    """(values, problems). Every key known, every value typed, nothing raised.

    A bad line costs that one setting its default and earns a sentence in
    `problems`; it never stops the applet starting. A config file is not a
    reason to be unable to connect.
    """
    values = defaults()
    problems = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        name, sep, value = line.partition("=")
        name = name.strip()
        if not sep:
            problems.append(f"line {number}: expected name = value")
            continue
        setting = SETTINGS_BY_NAME.get(name)
        if setting is None:
            problems.append(f"line {number}: unknown setting {name!r}")
            continue
        try:
            values[name] = setting.parse(value)
        except ValueError as exc:
            problems.append(f"line {number}: {name} — {exc}; using"
                            f" {setting.render(setting.default)}")
    return values, problems


def load_settings(path):
    """(values, problems) for a config file that need not exist."""
    try:
        # errors="replace", not strict. A file saved in latin-1 -- or any byte
        # that is not UTF-8 -- otherwise raises UnicodeDecodeError, which is
        # neither FileNotFoundError nor OSError and so escapes both handlers
        # below. This function is called at import time by the tray and as the
        # first statement of every health check, so that exception stopped the
        # applet starting *and* killed the watchdog of a running one. The rule
        # this file states a few lines up is absolute: a config file is not a
        # reason to be unable to connect. A mangled byte becomes a mangled
        # line, which parse_settings already reports and survives.
        with open(path, encoding="utf-8", errors="replace") as handle:
            return parse_settings(handle.read())
    except FileNotFoundError:
        return defaults(), []
    except OSError as exc:
        return defaults(), [f"cannot read {path}: {exc}"]


def render_settings(overrides=None):
    """A documented config file, every setting shown at its current value.

    Written out in full rather than as a bare list of overrides, so the file
    itself is the reference for what can be changed.
    """
    overrides = overrides or {}
    out = [
        "# ASU VPN settings.",
        "#",
        "# Every setting is listed with its default. Change a value and the",
        "# applet picks it up the next time it needs it -- the watchdog reads",
        "# these on each check, so most take effect without a reconnect.",
        "#",
        f"# Written by install.sh. Contract version {CONTRACT_VERSION}.",
        "",
    ]
    for setting in SETTINGS:
        value = overrides.get(setting.name, setting.default)
        for chunk in _wrap(setting.summary):
            out.append(f"# {chunk}")
        out.append(f"{setting.name} = {setting.render(value)}")
        out.append("")
    return "\n".join(out)


def _wrap(text, width=72):
    words, line, lines = text.split(), "", []
    for word in words:
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        lines.append(line)
    return lines


def xdg_dir(variable, fallback):
    """XDG base directory, matching GLib: a relative value is ignored."""
    value = os.environ.get(variable)
    if value and os.path.isabs(value):
        return value
    return os.path.join(os.path.expanduser("~"), fallback)


def config_path():
    return os.path.join(xdg_dir("XDG_CONFIG_HOME", ".config"), "asuvpn",
                        CONFIG_BASENAME)


# ------------------------------------------------------------- the bootstrap
#
# Each program carries its own copy of the loader below, and that duplication is
# irreducible: code cannot be shared before the mechanism that shares it has
# been loaded. It is the only thing in this project stated more than once on
# purpose. One line legitimately differs per program: the tray resolves
# `os.path.realpath(__file__)` because it is reached through the ~/.local/bin
# symlink, while the helper and asuvpn-notify use `os.path.abspath(__file__)` —
# copying the abspath form into a symlink-reachable program would look for the
# contract in the symlink's own directory and fail. asuvpn-selftest applies the
# same refusal inside its generic sibling loader (`load()`), which also covers
# the helper and tray sources it executes.
#
#     def _contract():
#         here = os.path.dirname(os.path.abspath(__file__))   # the tray: realpath
#         path = os.path.join(here, "asuvpn_contract.py")
#         if os.geteuid() == 0:          # running privileged: verify before exec
#             for target in (here, path):
#                 info = os.stat(target)
#                 if info.st_mode & stat.S_IWOTH or (
#                         info.st_mode & stat.S_IWGRP and info.st_gid != info.st_uid):
#                     raise SystemExit(f"refusing to load {target}: writable by others")
#         loader = importlib.machinery.SourceFileLoader("asuvpn_contract", path)
#         spec = importlib.util.spec_from_loader("asuvpn_contract", loader)
#         module = importlib.util.module_from_spec(spec)
#         loader.exec_module(module)
#         return module
#
# The permission test is skipped when unprivileged. Loading a file you own, as
# yourself, crosses no boundary -- and refusing there would break --link mode
# from an ordinary umask-002 checkout for no gain, which is a false positive
# this project has already had once.
