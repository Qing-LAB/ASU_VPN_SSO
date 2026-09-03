"""Deliver the ASU VPN applet from PyPI, without becoming a second installer.

This package is a delivery channel, not a different install. The wheel carries
the repository's own programs and both of its shell installers as a payload,
and the two console scripts here do exactly one thing each: run one of those
scripts out of the unpacked payload, passing every argument through.

Everything the README says about what lands where — the programs in
~/.local/share/asuvpn, the launcher, the settings file — is unchanged, because
it is the same installer. A second one would drift from the first, and drift is
how this project's worst bugs happened.

The split between the two matches the split PyPI cannot cross:

  asuvpn-install    the user half. Copies the programs into ~/.local, writes
                    the launcher and the settings file, ends with the
                    self-check. Touches nothing outside $HOME and asks for no
                    privileges. This is all a wheel can honestly do by itself.

  asuvpn-bootstrap  the system half, on Debian and Ubuntu: the GTK bindings,
                    openconnect, pkexec, the GNOME tray extension, and
                    openconnect-sso on the Python version it still supports.
                    These are apt packages and a GNOME extension, so no wheel
                    can carry them -- but the script that installs them can be
                    carried, and it ends by running asuvpn-install itself.

Before there were two, bootstrap.sh shipped inside the wheel with no way to
run it: a PyPI user got the user half and a paragraph of README telling them to
find the system half by hand, while the script that does it sat unreachable in
site-packages. Elsewhere than Debian and Ubuntu the README's Requirements
section lists what is needed, and the self-check at the end of either script
says plainly what is still missing.
"""

import subprocess
import sys
from importlib.resources import as_file, files


def _run(script):
    """Run one payload script with our arguments, and return its exit status.

    as_file because the payload may be inside a zip: it materialises a real
    directory when it has to, which matters because bootstrap.sh reads its own
    location to find install.sh and the programs beside it.
    """
    with as_file(files("asuvpn_dist") / "payload") as payload:
        return subprocess.call(["bash", str(payload / script), *sys.argv[1:]])


def main():
    """asuvpn-install: the user half. Accepts install.sh's own flags."""
    return _run("install.sh")


def bootstrap():
    """asuvpn-bootstrap: the system half, then the user half. Uses sudo."""
    return _run("bootstrap.sh")


if __name__ == "__main__":
    sys.exit(main())
