"""Check the install engine's effective OpenSSH options without connecting."""

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SOURCE = pathlib.Path(sys.argv.pop(1))


def effective_options(options):
    source = SOURCE.read_text()
    entrypoint = '\nmain "$@"\n'
    if not source.endswith(entrypoint) or source.count(entrypoint) != 1:
        raise AssertionError("nixos-anywhere entrypoint changed; inspect before updating this fixture")
    # Load the real argument parser, but do not run installs, builds or SSH.
    parser = source.removesuffix(entrypoint) + '\nparseArgs "$@"\nprintf "%s\\0" "${sshArgs[@]}"\n'
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR") or "/data/scratch/tmp/opencode") as directory:
        script = pathlib.Path(directory) / "parser.sh"
        script.write_text(parser)
        parsed = subprocess.run(
            ["bash", str(script), "--flake", ".#fixture", "--target-host", "root@fixture"]
            + [argument for option in options for argument in ("--ssh-option", option)],
            check=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
        )
    arguments = parsed.stdout.decode().rstrip("\0").split("\0")
    effective = subprocess.run(
        ["ssh", "-F", "/dev/null", "-G", *arguments, "root@fixture"],
        check=True,
        capture_output=True,
        text=True,
    )
    return dict(line.split(" ", 1) for line in effective.stdout.splitlines())


class SshOptions(unittest.TestCase):
    def test_legacy_first_install_defaults(self):
        options = effective_options([])
        self.assertEqual(options["stricthostkeychecking"], "false")
        self.assertEqual(options["userknownhostsfile"], "/dev/null")

    def test_explicit_bootstrap_trust_takes_precedence(self):
        options = effective_options(
            [
                "StrictHostKeyChecking=yes",
                "UserKnownHostsFile=/verified-bootstrap-hosts",
                "GlobalKnownHostsFile=/dev/null",
                "HostKeyAlias=ignitix-bootstrap-fixture",
                "HostKeyAlgorithms=ssh-ed25519",
                "ControlMaster=no",
                "ControlPath=none",
                # Target trust precedes both passthrough and media defaults.
                "StrictHostKeyChecking=no",
                "UserKnownHostsFile=/dev/null",
                "HostKeyAlgorithms=ssh-rsa",
                "ControlMaster=auto",
                "ControlPath=/unverified-master",
            ]
        )
        self.assertEqual(options["stricthostkeychecking"], "true")
        self.assertEqual(options["userknownhostsfile"], "/verified-bootstrap-hosts")
        self.assertEqual(options["globalknownhostsfile"], "/dev/null")
        self.assertEqual(options["hostkeyalias"], "ignitix-bootstrap-fixture")
        self.assertEqual(options["hostkeyalgorithms"], "ssh-ed25519")
        self.assertEqual(options["controlmaster"], "false")
        self.assertNotIn("controlpath", options)


if __name__ == "__main__":
    unittest.main()
