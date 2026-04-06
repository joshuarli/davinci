"""Integration tests that build real KISS core packages inside Docker using YSH.

Mirrors test_docker_build.py but uses Dockerfile.ysh (which installs ysh)
and runs pm.ysh instead of the POSIX pm.

Requires:
  - Docker daemon running
  - Source tarballs downloaded (run ./download_sources.sh first)

Usage:
  python3 -m pytest tests/test_docker_build_ysh.py -v --tb=short
  python3 -m unittest tests.test_docker_build_ysh -v
"""

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
IMAGE_NAME = "pm-ysh-integration-test"


def docker(*args, check=True, **kwargs):
    """Run a docker command."""
    return subprocess.run(
        ["docker", *args],
        capture_output=True,
        text=True,
        timeout=3600,
        check=check,
        **kwargs,
    )


def docker_exec(container, cmd, check=True):
    """Run a command inside the test container."""
    r = subprocess.run(
        ["docker", "exec", container, "sh", "-c", cmd],
        capture_output=True,
        text=True,
        timeout=3600,
    )
    if check and r.returncode != 0:
        raise AssertionError(
            f"Command failed (rc={r.returncode}): {cmd}\n"
            f"stdout: {r.stdout[-2000:]}\n"
            f"stderr: {r.stderr[-2000:]}"
        )
    return r


def setUpModule():
    """Build the Docker image once for all tests."""
    sources = TESTS / "fixtures" / "sources"
    if not any(sources.glob("*//*.tar.*")):
        raise unittest.SkipTest(
            "Source tarballs not downloaded. Run: cd tests && ./download_sources.sh"
        )

    print(f"\nBuilding Docker image {IMAGE_NAME}...")
    r = subprocess.run(
        ["docker", "build", "-t", IMAGE_NAME, "-f", str(TESTS / "Dockerfile.ysh"), "."],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=600,
    )
    if r.returncode != 0:
        raise RuntimeError(f"Docker build failed:\n{r.stderr[-3000:]}")
    print("Docker image built.")


class DockerYSHPMTestCase(unittest.TestCase):
    """Base class that runs YSH pm tests inside a persistent Docker container."""

    container = None

    @classmethod
    def setUpClass(cls):
        cls.container = f"pm-ysh-test-{cls.__name__.lower()}"
        docker("rm", "-f", cls.container, check=False)
        docker(
            "run", "-d",
            "--name", cls.container,
            IMAGE_NAME,
            "sleep", "infinity",
        )
        docker_exec(cls.container, "mkdir -p /kiss-root/var/db/kiss/installed")
        docker_exec(cls.container, "mkdir -p /kiss-root/var/db/kiss/choices")

    @classmethod
    def tearDownClass(cls):
        if cls.container:
            docker("rm", "-f", cls.container, check=False)

    def pm(self, *args, check=True):
        cmd = "KISS_ROOT=/kiss-root ysh /usr/bin/kiss " + " ".join(args)
        return docker_exec(self.container, cmd, check=check)

    def pm_build(self, pkg):
        """Build and install a package."""
        self.pm("b", pkg)
        self.pm("i", pkg)

    def assertInstalled(self, pkg):
        r = docker_exec(self.container, f"test -d /kiss-root/var/db/kiss/installed/{pkg}")
        self.assertEqual(r.returncode, 0, f"{pkg} not installed")

    def assertFileInRoot(self, path):
        r = docker_exec(
            self.container, f"test -e /kiss-root{path}", check=False
        )
        self.assertEqual(r.returncode, 0, f"{path} not found in KISS_ROOT")


class TestChecksumVerification(DockerYSHPMTestCase):
    """Test that pm.ysh correctly verifies checksums for real packages."""

    def test_checksum_valid_package(self):
        """Checksums for musl sources should verify successfully."""
        r = self.pm("d", "musl")
        self.assertEqual(r.returncode, 0)

    def test_checksum_mismatch_detected(self):
        """Corrupting a source should cause checksum failure."""
        src = "/home/kiss/sources/zlib/zlib-1.2.11.tar.gz"
        docker_exec(self.container, f"cp {src} {src}.bak")
        docker_exec(self.container, f"echo corrupt >> {src}")
        r = self.pm("b", "zlib", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Checksum", r.stderr)
        docker_exec(self.container, f"mv {src}.bak {src}")


class TestBuildBaseSystem(DockerYSHPMTestCase):
    """Build the base system packages in dependency order.

    Tests are ordered alphabetically by name, and we prefix with numbers
    to enforce the correct build order. Each test builds on packages
    installed by earlier tests.
    """

    ALL_PACKAGES = [
        "baseinit", "baselayout", "bison", "busybox", "bzip2",
        "curl", "flex", "kiss", "linux-headers", "m4", "make",
        "musl", "openssl", "pigz", "xz", "zlib",
    ]

    def test_00_search_all_packages(self):
        """All core packages should be searchable."""
        for pkg in self.ALL_PACKAGES:
            r = self.pm("s", pkg)
            self.assertIn(pkg, r.stdout, f"search failed for {pkg}")

    def test_01_build_baselayout(self):
        """baselayout has no deps and just creates directories."""
        self.pm_build("baselayout")
        r = self.pm("l")
        self.assertIn("baselayout", r.stdout)
        self.assertFileInRoot("/etc/passwd")
        self.assertFileInRoot("/etc/group")
        self.assertFileInRoot("/usr/bin")

    def test_02_build_musl(self):
        """musl is the C library — foundation of everything."""
        self.pm_build("musl")
        r = self.pm("l")
        self.assertIn("musl", r.stdout)
        self.assertFileInRoot("/usr/lib/libc.so")
        self.assertFileInRoot("/usr/include/stdio.h")

    def test_03_build_linux_headers(self):
        self.pm_build("linux-headers")
        r = self.pm("l")
        self.assertIn("linux-headers", r.stdout)

    def test_04_build_zlib(self):
        self.pm_build("zlib")
        r = self.pm("l")
        self.assertIn("zlib", r.stdout)
        self.assertFileInRoot("/usr/lib/libz.so")

    def test_05_build_bzip2(self):
        self.pm_build("bzip2")
        r = self.pm("l")
        self.assertIn("bzip2", r.stdout)

    def test_06_build_xz(self):
        self.pm_build("xz")
        r = self.pm("l")
        self.assertIn("xz", r.stdout)

    def test_07_build_m4(self):
        self.pm_build("m4")
        r = self.pm("l")
        self.assertIn("m4", r.stdout)

    def test_08_build_make(self):
        self.pm_build("make")
        r = self.pm("l")
        self.assertIn("make", r.stdout)

    def test_09_build_busybox(self):
        """busybox is the core userland — largest of the base packages."""
        self.pm_build("busybox")
        r = self.pm("l")
        self.assertIn("busybox", r.stdout)
        self.assertFileInRoot("/usr/bin/busybox")

    def test_10_build_baseinit(self):
        self.pm_build("baseinit")
        r = self.pm("l")
        self.assertIn("baseinit", r.stdout)

    def test_11_build_openssl(self):
        self.pm_build("openssl")
        r = self.pm("l")
        self.assertIn("openssl", r.stdout)

    def test_12_build_curl(self):
        """curl depends on openssl and zlib (already built)."""
        self.pm_build("curl")
        r = self.pm("l")
        self.assertIn("curl", r.stdout)

    def test_13_build_pigz(self):
        self.pm_build("pigz")
        r = self.pm("l")
        self.assertIn("pigz", r.stdout)

    def test_14_build_bison(self):
        self.pm_build("bison")
        r = self.pm("l")
        self.assertIn("bison", r.stdout)

    def test_15_build_flex(self):
        self.pm_build("flex")
        r = self.pm("l")
        self.assertIn("flex", r.stdout)

    def test_16_build_kiss(self):
        """The package manager packages itself."""
        self.pm_build("kiss")
        r = self.pm("l")
        self.assertIn("kiss", r.stdout)

    def test_90_list_all_installed(self):
        """After building everything, list should show all 16 packages."""
        r = self.pm("l")
        installed = r.stdout.strip().split("\n")
        for pkg in self.ALL_PACKAGES:
            found = any(pkg in line for line in installed)
            self.assertTrue(found, f"{pkg} not in installed list")

    def test_91_rootfs_has_essential_dirs(self):
        """The rootfs should have a proper directory structure."""
        for d in ["/usr/bin", "/usr/lib", "/etc", "/var", "/tmp"]:
            self.assertFileInRoot(d)

    def test_92_rootfs_has_c_library(self):
        self.assertFileInRoot("/usr/lib/libc.so")

    def test_93_remove_and_reinstall(self):
        """Removing and reinstalling a leaf package should work."""
        r = self.pm("l", "pigz", check=False)
        if r.returncode != 0:
            self.skipTest("pigz not installed")
        self.pm("r", "pigz")
        r = self.pm("l", "pigz", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.pm("i", "pigz")

    def test_94_all_artifacts_produced(self):
        """Every package should have a built tarball in the cache."""
        r = docker_exec(
            self.container,
            "ls /root/.cache/kiss/bin/",
        )
        tarballs = r.stdout.strip().split("\n")
        for pkg in self.ALL_PACKAGES:
            found = any(t.startswith(f"{pkg}@") for t in tarballs)
            self.assertTrue(found, f"no artifact tarball for {pkg}")

    def test_95_manifests_exist(self):
        """Every installed package should have a non-empty manifest."""
        for pkg in self.ALL_PACKAGES:
            r = docker_exec(
                self.container,
                f"test -s /kiss-root/var/db/kiss/installed/{pkg}/manifest",
                check=False,
            )
            self.assertEqual(
                r.returncode, 0,
                f"manifest missing or empty for {pkg}",
            )


if __name__ == "__main__":
    unittest.main()
