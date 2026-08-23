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

# Bumped when the wire format changes in a way the programs must agree on.
# `asuvpn selftest` reports it, so a half-updated install is visible rather than
# mysterious.
CONTRACT_VERSION = 1


# --------------------------------------------------------------- permissions


def unsafe_write_access(path):
    """Why `path` is writable by a principal other than its owner, or None.

    Group-writable is not automatically a finding. Debian and Ubuntu default to
    umask 002 with user-private groups, so a plain git checkout is 0775 with
    gid == uid — the "group" is one person, and refusing there would break
    --link mode for no gain. A *shared* group is a second principal, and
    world-writable always is.
    """
    try:
        st = os.stat(path)
    except OSError:
        return None
    if st.st_mode & stat.S_IWOTH:
        return "world-writable"
    if st.st_mode & stat.S_IWGRP and st.st_gid != st.st_uid:
        return f"writable by group {st.st_gid}"
    return None


# ------------------------------------------------- helper -> tray, one line


# The helper's own messages and openconnect's output share a single pipe, so
# each line says which it is. Without the framing a VPN banner containing
# "[helper] WARNING:" could raise a desktop notification with text the server
# chose, or "[helper] STATE connected" could drive the badge.
MESSAGE_PREFIX = "[helper]"
RELAY_PREFIX = "[vpn]"

KIND_NOTE = "NOTE"        # informational; shown to the user without the kind
KIND_WARNING = "WARNING"  # the network may not have been restored
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
# waiting to happen, so it is gone.
CONTROL_QUIT = "quit"
CONTROL_RECONNECT = "reconnect"
CONTROL_STOP = (CONTROL_QUIT,)
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
EVENT_SOCKET_VAR = "ASUVPN_EVENT_SOCKET"
EVENT_TOKEN_VAR = "ASUVPN_EVENT_TOKEN"
REAL_SCRIPT_VAR = "ASUVPN_REAL_SCRIPT"
EVENT_VARS = (EVENT_SOCKET_VAR, EVENT_TOKEN_VAR, REAL_SCRIPT_VAR)

# The environment variables openconnect itself sets, in the order they travel.
# `reason` is lower case because that is what the vpnc-script contract calls it.
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
REASON_STATES = {
    "connect": "connected",
    "reconnect": "connected",
    "attempt-reconnect": "connecting",
    "disconnect": "disconnected",
}

# IFNAMSIZ is 16 including the NUL. Anything outside this cannot name a device,
# and unchecked it would reach an `ip link delete` running as root, or be
# interpolated into a path under /sys.
INTERFACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$")
INTERFACE_PREFIX = "asuvpn"

# What we present to the gateway. Both the tray (which passes it) and the
# helper (which needs a default for a direct caller) must say the same one; it
# was stated in each and could drift.
AC_VERSION = "4.7.00136"

# Only a last resort, shared by the helper (when the binary will not name its
# own default) and asuvpn-notify (when run as a vpnc-script by hand). The real
# path is asked of `openconnect --version`; it differs between distributions.
FALLBACK_VPNC_SCRIPT = "/usr/share/vpnc-scripts/vpnc-script"


def one_token(value):
    """Collapse a value to a single whitespace-free token."""
    return re.sub(r"\s+", "_", str(value).strip())[:64]


def one_line(value):
    """Collapse a value to a single line, so it cannot end a framed message."""
    return re.sub(r"[\r\n]+", " ", str(value)).rstrip()


# ------------------------------------------------------------- the settings


class Setting:
    """One knob: how it is spelled, what it means, and what it is when unset."""

    __slots__ = ("default", "kind", "maximum", "name", "summary")

    def __init__(self, name, kind, default, summary, maximum=None):
        self.name = name
        self.kind = kind
        self.default = default
        self.summary = summary
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
    Setting("autoreconnect", "bool", False,
            "Sign in again by itself when a stalled tunnel cannot be recovered"
            " for free. Costs a Duo push and a password each time, so it is off"
            " unless you ask for it."),
    Setting("dpd", "int", 30,
            "Seconds between dead-peer probes, forced on because some servers"
            " negotiate detection off and then a dropped tunnel looks connected."
            " 0 leaves the server's choice alone."),
    Setting("health-interval", "int", 20,
            "Seconds between checks of the tunnel device and its routes."
            " 0 turns the watchdog off entirely."),
    Setting("health-strikes", "int", 2,
            "Consecutive bad checks before the badge stops claiming Connected."
            " Two, because routes are briefly absent during a real reconnect."),
    Setting("probe", "bool", True,
            "Ask the network whether the tunnel still carries traffic. This is"
            " the only check that catches a tunnel whose device and routes are"
            " perfectly healthy but which delivers nothing."),
    Setting("probe-target", "text", "",
            "Address to probe. Empty means whatever resolver the VPN itself"
            " pushed, which is the right answer on every network it is used on."),
    Setting("probe-port", "int", 53,
            "Port for the probe. Nothing is sent; a refusal counts as alive,"
            " because a RST proves a packet crossed in each direction.",
            maximum=65535),
    Setting("probe-every", "int", 3,
            "Run the probe on every Nth health check, so it costs a packet a"
            " minute rather than one every twenty seconds."),
    Setting("probe-timeout", "int", 5,
            "Seconds to wait for an answer. A healthy tunnel replies in"
            " milliseconds, so this is generous by two orders of magnitude."),
    Setting("nudge-min-gap", "int", 120,
            "Seconds between asking openconnect to re-establish. Free, but not"
            " something to do every time a check fails."),
    Setting("autoreconnect-min-gap", "int", 300,
            "Seconds between automatic sign-ins, when autoreconnect is on."),
    Setting("teardown-timeout", "int", 75,
            "Seconds to wait for the helper to finish. Must outlast its own"
            " signal escalation of 15 + 10 + 5 plus the routing check after."),
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
        with open(path, encoding="utf-8") as handle:
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
# purpose, and it is eight lines that never change.
#
#     def _contract():
#         here = os.path.dirname(os.path.abspath(__file__))
#         path = os.path.join(here, "asuvpn_contract.py")
#         if os.geteuid() == 0:          # running privileged: verify before exec
#             for target in (here, path):
#                 st = os.stat(target)
#                 if st.st_mode & stat.S_IWOTH or (
#                         st.st_mode & stat.S_IWGRP and st.st_gid != st.st_uid):
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
