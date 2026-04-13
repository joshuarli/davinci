"""Docker integration tests for Kominka images.

Slower than test_pm_cheap.py — run with: python3 -m pytest tests/test_docker.py -v

Requires: kominka:core image already built (make core) and repo server running.
"""

import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGES_DIR = os.path.join(ROOT, "packages")
KOMINKA_REPO = os.environ.get("KOMINKA_REPO", "http://localhost:3000")


def docker(*args, timeout=300):
    return subprocess.run(
        ["docker", *args],
        capture_output=True, text=True, timeout=timeout,
    )


def docker_check(*args, timeout=300):
    r = docker(*args, timeout=timeout)
    if r.returncode != 0:
        raise AssertionError(
            f"docker {' '.join(args)} exited {r.returncode}\n"
            f"stdout: {r.stdout[-500:]}\nstderr: {r.stderr[-500:]}"
        )
    return r


class TestCoreImage(unittest.TestCase):
    """Test kominka:core — the base image."""

    def test_pm_list(self):
        r = docker_check("run", "--rm", "kominka:core", "pm", "l")
        self.assertIn("musl", r.stdout)
        self.assertIn("busybox", r.stdout)
        self.assertIn("ysh", r.stdout)
        self.assertIn("curl", r.stdout)
        self.assertIn("core", r.stdout)

    def test_ysh_works(self):
        r = docker_check("run", "--rm", "kominka:core",
                          "ysh", "-c", "echo hello")
        self.assertIn("hello", r.stdout)

    def test_busybox_applets(self):
        r = docker_check("run", "--rm", "kominka:core",
                          "busybox", "--list")
        for applet in ["gzip", "tar", "sh", "sed", "awk", "fdisk", "wget"]:
            self.assertIn(applet, r.stdout, f"missing applet: {applet}")

    def test_https_works(self):
        """curl HTTPS works with CA certificates (no -k needed)."""
        r = docker("run", "--rm", "kominka:core",
                    "curl", "-sfo", "/dev/null", "https://www.google.com",
                    timeout=15)
        self.assertEqual(r.returncode, 0)

    def test_pm_install_package(self):
        """pm can install an additional package from the repo server."""
        r = docker_check(
            "run", "--rm",
            "-v", f"{PACKAGES_DIR}:/packages",
            "-e", "KOMINKA_PATH=/packages",
            "-e", "KOMINKA_FORCE=1",
            "-e", "KOMINKA_INSECURE=1",
            "-e", f"KOMINKA_REPO={KOMINKA_REPO}",
            "kominka:core", "pm", "i", "e2fsprogs",
            timeout=30,
        )
        combined = r.stdout + r.stderr
        self.assertIn("Installed successfully", combined)


if __name__ == "__main__":
    unittest.main()
