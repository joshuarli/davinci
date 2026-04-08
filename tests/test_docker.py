"""Docker integration tests for Kominka images.

Slower than test_pm_cheap.py — run with: python3 -m pytest tests/test_docker.py -v
"""

import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.join(ROOT, "tests", "fixtures", "repo")


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

    @classmethod
    def setUpClass(cls):
        docker_check("build", "-t", "kominka:core", ".", timeout=120)

    def test_pm_list(self):
        r = docker_check("run", "--rm", "kominka:core", "pm", "l")
        self.assertIn("glibc", r.stdout)
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
        for applet in ["gzip", "tar", "sh", "sed", "awk", "fdisk",
                        "losetup", "cpio", "wget"]:
            self.assertIn(applet, r.stdout, f"missing applet: {applet}")

    def test_curl_works(self):
        """curl can fetch a known file from R2."""
        r = docker("run", "--rm", "kominka:core",
                    "curl", "-ksfo", "/dev/null",
                    "https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev/"
                    "aarch64-linux-gnu/baselayout@1-8.tar.gz",
                    timeout=30)
        self.assertEqual(r.returncode, 0)

    def test_pm_install_package(self):
        """pm can install an additional package from R2."""
        r = docker_check(
            "run", "--rm",
            "-v", f"{REPO}:/packages",
            "-e", "KOMINKA_PATH=/packages",
            "-e", "KOMINKA_FORCE=1",
            "-e", "KOMINKA_INSECURE=1",
            "-e", "KOMINKA_BIN_MIRROR=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev",
            "kominka:core", "pm", "i", "e2fsprogs",
            timeout=30,
        )
        combined = r.stdout + r.stderr
        self.assertIn("Installed successfully", combined)


if __name__ == "__main__":
    unittest.main()
