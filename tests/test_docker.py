"""Docker integration tests for Kominka images.

These tests build real Docker images and verify they work.
Slower than test_pm_cheap.py — run with: python3 -m pytest tests/test_docker.py -v
"""

import subprocess
import unittest


def docker(*args, timeout=300):
    """Run a docker command, return CompletedProcess."""
    return subprocess.run(
        ["docker", *args],
        capture_output=True, text=True, timeout=timeout,
    )


def docker_check(*args, timeout=300):
    """Run a docker command, fail on non-zero exit."""
    r = docker(*args, timeout=timeout)
    if r.returncode != 0:
        raise AssertionError(
            f"docker {' '.join(args)} exited {r.returncode}\n"
            f"stdout: {r.stdout[-500:]}\nstderr: {r.stderr[-500:]}"
        )
    return r


class TestCoreImage(unittest.TestCase):
    """Test kominka:core — the minimal base image."""

    @classmethod
    def setUpClass(cls):
        docker_check("build", "-t", "kominka:core", "--target", "core", ".",
                      timeout=120)

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
        for applet in ["gzip", "tar", "sh", "sed", "awk", "fdisk", "losetup"]:
            self.assertIn(applet, r.stdout, f"missing applet: {applet}")

    def test_curl_works(self):
        """curl can fetch a known file from R2."""
        r = docker("run", "--rm", "kominka:core",
                    "curl", "-ksfo", "/dev/null",
                    "https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev/"
                    "aarch64-linux-gnu/baselayout@1-8.tar.gz",
                    timeout=30)
        self.assertEqual(r.returncode, 0)


class TestBuildImage(unittest.TestCase):
    """Test kominka:build — the self-hosting toolchain image."""

    @classmethod
    def setUpClass(cls):
        docker_check("build", "-t", "kominka:build", "--target", "build", ".",
                      timeout=300)

    def test_pm_list_has_toolchain(self):
        r = docker_check("run", "--rm", "kominka:build", "pm", "l")
        for pkg in ["zig", "make", "cmake", "samurai", "go", "git"]:
            self.assertIn(pkg, r.stdout, f"missing package: {pkg}")

    def test_build_zlib(self):
        """Can build a package from source inside the image."""
        r = docker_check(
            "run", "--rm",
            "-e", "KOMINKA_FORCE=1",
            "-e", "KOMINKA_MIRROR=https://pub-ad5257645a73444c9056cf2aed244ac7.r2.dev",
            "-e", "KOMINKA_INSECURE=1",
            "kominka:build", "pm", "b", "zlib",
            timeout=120,
        )
        self.assertIn("Successfully created tarball", r.stderr + r.stdout)


if __name__ == "__main__":
    unittest.main()
