"""Deliver the ASU VPN applet from PyPI, without becoming a second installer.

This package is a delivery channel, not a different install. The wheel
carries the repository's own programs and its install.sh as a payload, and
`asuvpn-install` does exactly one thing: run that install.sh from the
unpacked payload, passing any arguments through. Everything the README says
about what lands where — the programs in ~/.local/share/asuvpn, the
launcher, the settings file — is unchanged, because it is the same
installer; a second one would drift from the first, and drift is how this
project's worst bugs happened.

What PyPI cannot deliver is the system half: the GTK bindings, openconnect,
pkexec, and the GNOME tray extension. On Debian or Ubuntu the payload's
bootstrap.sh installs those; elsewhere, the README's Requirements section
lists them. install.sh itself ends with the self-check, which will say
plainly what is still missing.
"""

import subprocess
import sys
from importlib.resources import as_file, files


def main():
    with as_file(files("asuvpn_dist") / "payload") as payload:
        return subprocess.call(
            ["bash", str(payload / "install.sh"), *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
