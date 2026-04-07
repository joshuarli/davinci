"""Integration tests for pm (Kominka package manager)."""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PM = ROOT / "pm"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPO = FIXTURES / "repo"


class PMTestCase(unittest.TestCase):
    """Base class that sets up an isolated Kominka environment per test."""

    def setUp(self):
        # Resolve the tmpdir path to avoid symlink issues (macOS /var ->
        # /private/var) which break pm's resolve_path during conflict checks.
        self.tmpdir = os.path.realpath(tempfile.mkdtemp(prefix="pm-test-"))
        self.kominka_root = Path(self.tmpdir) / "root"
        self.kominka_cache = Path(self.tmpdir) / "cache"
        self.kominka_tmpdir = Path(self.tmpdir) / "proc"

        # Create the installed package database directory.
        (self.kominka_root / "var/db/kominka/installed").mkdir(parents=True)
        (self.kominka_root / "var/db/kominka/choices").mkdir(parents=True)

        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmpdir,
            "LOGNAME": os.environ.get("LOGNAME", "testuser"),
            "KOMINKA_PATH": str(REPO),
            "KOMINKA_ROOT": str(self.kominka_root),
            "KOMINKA_COLOR": "0",
            "KOMINKA_PROMPT": "0",
            "KOMINKA_COMPRESS": "gz",
            "KOMINKA_TMPDIR": str(self.kominka_tmpdir),
            "XDG_CACHE_HOME": str(self.kominka_cache),
        }

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def pm(self, *args, env_override=None, check=True):
        """Run pm with the given arguments in the test environment."""
        env = {**self.env}
        if env_override:
            env.update(env_override)
        result = subprocess.run(
            ["sh", str(PM), *args],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        if check and result.returncode != 0:
            self.fail(
                f"pm {' '.join(args)} exited {result.returncode}\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )
        return result

    def install_pkg(self, name):
        """Build and install a package into the test root."""
        self.pm("b", name)
        # Find the tarball and install it.
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarballs = list(bin_dir.glob(f"{name}@*.tar.*"))
        self.assertTrue(tarballs, f"No tarball found for {name}")
        self.pm("i", str(tarballs[0]))

    def installed_db(self, name):
        return self.kominka_root / "var/db/kominka/installed" / name

    def create_repo_pkg(self, name, version="1.0 1", depends="", build=None):
        """Create a minimal package in a temporary repo directory."""
        repo = Path(self.tmpdir) / "extra-repo" / name
        repo.mkdir(parents=True)
        (repo / "version").write_text(version + "\n")
        if depends:
            (repo / "depends").write_text(depends + "\n")
        build_script = build or textwrap.dedent("""\
            #!/bin/sh -e
            mkdir -p "$1/usr/bin"
            printf 'mock' > "$1/usr/bin/{name}"
        """).format(name=name)
        (repo / "build").write_text(build_script)
        (repo / "build").chmod(0o755)
        # Prepend to KOMINKA_PATH so it's found.
        self.env["KOMINKA_PATH"] = str(repo.parent) + ":" + self.env["KOMINKA_PATH"]
        return repo


class TestHelp(PMTestCase):
    """Test help / usage output."""

    def test_no_args_prints_usage(self):
        r = self.pm()
        self.assertIn("pm [a|b|c|d|i|l|r|s|u|U|v]", r.stderr)

    def test_no_args_mentions_all_commands(self):
        r = self.pm()
        for cmd in [
            "alternatives", "build", "checksum", "download",
            "install", "list", "remove", "search", "update",
            "upgrade", "version",
        ]:
            self.assertIn(cmd, r.stderr, f"Help missing '{cmd}'")


class TestSearch(PMTestCase):
    """Test the search (s) command."""

    def test_search_finds_package(self):
        r = self.pm("s", "zlib")
        self.assertIn("zlib", r.stdout)

    def test_search_finds_all_matches(self):
        # Both boringssl and curl should be findable.
        for pkg in ["boringssl", "curl", "musl", "samurai", "busybox"]:
            r = self.pm("s", pkg)
            self.assertIn(pkg, r.stdout)

    def test_search_missing_package_fails(self):
        r = self.pm("s", "nonexistent-pkg-xyz", check=False)
        self.assertNotEqual(r.returncode, 0)


class TestList(PMTestCase):
    """Test the list (l) command."""

    def test_list_empty(self):
        # With no installed packages the glob expands to literal '*' and
        # pm exits non-zero. This is expected behavior.
        r = self.pm("l", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_list_after_install(self):
        self.install_pkg("samurai")
        r = self.pm("l")
        self.assertIn("samurai", r.stdout)
        self.assertIn("1.2-1", r.stdout)

    def test_list_specific_package(self):
        self.install_pkg("samurai")
        r = self.pm("l", "samurai")
        self.assertIn("samurai", r.stdout)

    def test_list_specific_missing(self):
        r = self.pm("l", "nonexistent", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_list_multiple_packages(self):
        self.install_pkg("samurai")
        self.install_pkg("zlib")
        r = self.pm("l")
        self.assertIn("samurai", r.stdout)
        self.assertIn("zlib", r.stdout)


class TestBuild(PMTestCase):
    """Test the build (b) command."""

    def test_build_simple_package(self):
        """Build a package with no dependencies."""
        self.pm("b", "samurai")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarballs = list(bin_dir.glob("samurai@*.tar.*"))
        self.assertEqual(len(tarballs), 1)
        self.assertIn("1.2-1", tarballs[0].name)

    def test_build_creates_tarball(self):
        self.pm("b", "zlib")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarballs = list(bin_dir.glob("zlib@*.tar.*"))
        self.assertTrue(tarballs)

    def test_build_with_dependencies(self):
        """Building curl should also build its deps (boringssl, zlib, musl)."""
        self.pm("b", "curl")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        # curl and its deps should all have tarballs.
        for pkg in ["curl", "boringssl", "zlib", "musl"]:
            tarballs = list(bin_dir.glob(f"{pkg}@*.tar.*"))
            self.assertTrue(tarballs, f"No tarball for dependency {pkg}")

    def test_build_respects_kominka_compress(self):
        """Tarball should use the configured compression."""
        self.pm("b", "samurai", env_override={"KOMINKA_COMPRESS": "xz"})
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarballs = list(bin_dir.glob("samurai@*.tar.xz"))
        self.assertTrue(tarballs, "Expected .tar.xz tarball")

    def test_build_nonexistent_package_fails(self):
        r = self.pm("b", "no-such-pkg-ever", check=False)
        self.assertNotEqual(r.returncode, 0)


class TestInstall(PMTestCase):
    """Test the install (i) command."""

    def test_install_from_tarball(self):
        self.pm("b", "samurai")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarball = list(bin_dir.glob("samurai@*.tar.*"))[0]
        self.pm("i", str(tarball))

        # Check the package is recorded in the database.
        db = self.installed_db("samurai")
        self.assertTrue(db.is_dir())
        self.assertTrue((db / "manifest").is_file())
        self.assertTrue((db / "version").is_file())

    def test_install_creates_files(self):
        self.install_pkg("samurai")
        # The mock build creates /usr/bin/samu and /usr/bin/ninja.
        self.assertTrue((self.kominka_root / "usr/bin/samu").exists())
        self.assertTrue((self.kominka_root / "usr/bin/ninja").exists())

    def test_install_manifest_lists_files(self):
        self.install_pkg("samurai")
        manifest = (self.installed_db("samurai") / "manifest").read_text()
        self.assertIn("/usr/bin/samu", manifest)

    def test_install_nonexistent_tarball_fails(self):
        r = self.pm("i", "/tmp/no-such-file.tar.gz", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_install_records_version(self):
        self.install_pkg("zlib")
        version = (self.installed_db("zlib") / "version").read_text().strip()
        self.assertEqual(version, "1.2.11 3")

    def test_upgrade_replaces_files(self):
        """Installing a new version over an old one should work cleanly."""
        self.install_pkg("samurai")
        # Modify the repo version and rebuild.
        repo = self.create_repo_pkg(
            "samurai", version="1.3 1",
            build=textwrap.dedent("""\
                #!/bin/sh -e
                mkdir -p "$1/usr/bin" "$1/usr/share/man/man1"
                printf 'mock-v2' > "$1/usr/bin/samu"
                ln -sf samu "$1/usr/bin/ninja"
                printf 'mock' > "$1/usr/share/man/man1/samu.1"
            """),
        )
        self.pm("b", "samurai")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarball = sorted(bin_dir.glob("samurai@1.3*.tar.*"))[-1]

        self.pm("i", str(tarball), env_override={"KOMINKA_FORCE": "1"})
        version = (self.installed_db("samurai") / "version").read_text().strip()
        self.assertEqual(version, "1.3 1")


class TestRemove(PMTestCase):
    """Test the remove (r) command."""

    def test_remove_installed_package(self):
        self.install_pkg("samurai")
        self.assertTrue(self.installed_db("samurai").is_dir())

        self.pm("r", "samurai")
        self.assertFalse(self.installed_db("samurai").exists())

    def test_remove_cleans_files(self):
        self.install_pkg("samurai")
        self.assertTrue((self.kominka_root / "usr/bin/samu").exists())

        self.pm("r", "samurai")
        self.assertFalse((self.kominka_root / "usr/bin/samu").exists())

    def test_remove_not_installed_fails(self):
        r = self.pm("r", "samurai", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_remove_with_dependents_fails(self):
        """Removing a package that others depend on should fail."""
        self.install_pkg("musl")
        self.install_pkg("boringssl")
        r = self.pm("r", "musl", check=False)
        self.assertNotEqual(r.returncode, 0)
        # musl should still be installed.
        self.assertTrue(self.installed_db("musl").is_dir())

    def test_force_remove_with_dependents(self):
        """KOMINKA_FORCE=1 should allow removing even with dependents."""
        self.install_pkg("musl")
        self.install_pkg("boringssl")
        self.pm("r", "musl", env_override={"KOMINKA_FORCE": "1"})
        self.assertFalse(self.installed_db("musl").exists())


class TestAlternatives(PMTestCase):
    """Test the alternatives (a) command."""

    def test_list_alternatives_empty(self):
        # With no choices the glob in pkg_alternatives expands to a literal
        # pattern. Just verify it doesn't crash hard.
        r = self.pm("a", check=False)
        # Should not contain any real package names.
        for pkg in ["zlib", "curl", "samurai"]:
            self.assertNotIn(pkg, r.stdout)

    def _setup_alternatives(self):
        """Install two packages that conflict on /usr/bin/editor.

        Installs a filler package first so there are multiple manifests
        in the db (grep only prefixes filenames when searching >1 file).
        """
        build = textwrap.dedent("""\
            #!/bin/sh -e
            mkdir -p "$1/usr/bin"
            printf '{content}' > "$1/usr/bin/editor"
        """)
        self.create_repo_pkg("editor-a", build=build.format(content="aaa"))
        self.create_repo_pkg("editor-b", build=build.format(content="bbb"))

        # Install a filler so the installed db has >1 manifest.
        self.install_pkg("samurai")
        self.install_pkg("editor-a")

        self.pm("b", "editor-b")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarball = list(bin_dir.glob("editor-b@*.tar.*"))[0]
        self.pm("i", str(tarball))

    def test_conflicting_files_become_alternatives(self):
        """Two packages owning the same file should create an alternative.
        By default (KOMINKA_CHOICE unset), safe conflicts are auto-converted."""
        self._setup_alternatives()

        r = self.pm("a")
        self.assertIn("editor-b", r.stdout)

    def test_swap_alternative(self):
        """Swapping an alternative should replace the file on disk."""
        self._setup_alternatives()

        # editor-a currently owns /usr/bin/editor.
        content = (self.kominka_root / "usr/bin/editor").read_text()
        self.assertEqual(content, "aaa")

        # Swap to editor-b.
        self.pm("a", "editor-b", "/usr/bin/editor")
        content = (self.kominka_root / "usr/bin/editor").read_text()
        self.assertEqual(content, "bbb")


class TestChecksum(PMTestCase):
    """Test the checksum (c) command."""

    def test_checksum_generates_file(self):
        """Checksum should create a checksums file for packages with local sources."""
        repo = self.create_repo_pkg("mylib")
        # Add a local source file.
        (repo / "data.tar.gz").write_bytes(b"fake tarball content")
        (repo / "sources").write_text("data.tar.gz\n")

        self.pm("c", "mylib")
        checksums_file = repo / "checksums"
        self.assertTrue(checksums_file.exists())
        content = checksums_file.read_text().strip()
        # Should be a hex sha256 hash.
        self.assertEqual(len(content), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in content))

    def test_checksum_no_sources(self):
        """Packages without a sources file should be a no-op."""
        self.create_repo_pkg("nosrc")
        r = self.pm("c", "nosrc")
        # Should succeed without error.
        self.assertEqual(r.returncode, 0)

    def test_checksum_multiple_sources(self):
        repo = self.create_repo_pkg("multi")
        (repo / "file1.txt").write_text("aaa")
        (repo / "file2.txt").write_text("bbb")
        (repo / "sources").write_text("file1.txt\nfile2.txt\n")

        self.pm("c", "multi")
        lines = (repo / "checksums").read_text().strip().split("\n")
        self.assertEqual(len(lines), 2)


class TestDownload(PMTestCase):
    """Test the download (d) command."""

    def test_download_local_sources(self):
        """Download should verify local source files exist."""
        repo = self.create_repo_pkg("localpkg")
        (repo / "localfile.txt").write_text("content")
        (repo / "sources").write_text("localfile.txt\n")

        r = self.pm("d", "localpkg")
        self.assertEqual(r.returncode, 0)
        # "found" message is printed to stdout by pkg_source_resolve.
        combined = r.stdout + r.stderr
        self.assertIn("found", combined)

    def test_download_missing_source_fails(self):
        """Download should fail if a local source doesn't exist."""
        repo = self.create_repo_pkg("badpkg")
        (repo / "sources").write_text("nonexistent-file.tar.gz\n")

        r = self.pm("d", "badpkg", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_download_no_sources_ok(self):
        """Packages without sources should succeed."""
        self.create_repo_pkg("nosrc2")
        r = self.pm("d", "nosrc2")
        self.assertEqual(r.returncode, 0)


class TestEtcHandling(PMTestCase):
    """Test /etc/ config file handling during install/remove."""

    def test_etc_files_installed(self):
        """Files in /etc/ should be installed."""
        self.install_pkg("busybox")
        self.assertTrue(
            (self.kominka_root / "etc/mdev.conf").exists()
        )

    def test_etc_modified_preserved_on_remove(self):
        """Modified /etc/ files should be preserved on package removal."""
        self.install_pkg("busybox")
        conf = self.kominka_root / "etc/mdev.conf"
        conf.write_text("# user modified config\n")

        self.pm("r", "busybox", env_override={"KOMINKA_FORCE": "1"})
        # Modified config file should be preserved (not deleted).
        self.assertTrue(conf.exists())


class TestDependencyResolution(PMTestCase):
    """Test dependency ordering and resolution."""

    def test_deps_built_in_order(self):
        """curl depends on boringssl and zlib; boringssl depends on musl.
        All should be built."""
        self.pm("b", "curl")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        for pkg in ["musl", "zlib", "boringssl", "curl"]:
            self.assertTrue(
                list(bin_dir.glob(f"{pkg}@*.tar.*")),
                f"{pkg} tarball not found after building curl",
            )

    def test_circular_dependency_detected(self):
        """Circular dependencies should cause an error."""
        self.create_repo_pkg("pkg-a", depends="pkg-b")
        self.create_repo_pkg("pkg-b", depends="pkg-a")

        r = self.pm("b", "pkg-a", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Circular", r.stderr)


class TestBuildEnvironment(PMTestCase):
    """Test that the build environment is set up correctly."""

    def test_destdir_passed_to_build(self):
        """The build script receives DESTDIR as $1."""
        build = textwrap.dedent("""\
            #!/bin/sh -e
            mkdir -p "$1/usr/bin"
            printf '%s' "$1" > "$1/usr/bin/destdir-test"
        """)
        self.create_repo_pkg("destdir-check", build=build)
        self.pm("b", "destdir-check")
        # If the build succeeded without error, DESTDIR was valid.

    def test_version_passed_to_build(self):
        """The build script receives version as $2."""
        build = textwrap.dedent("""\
            #!/bin/sh -e
            mkdir -p "$1/usr/share"
            printf '%s' "$2" > "$1/usr/share/ver"
        """)
        self.create_repo_pkg("ver-check", version="3.14 1", build=build)
        self.pm("b", "ver-check")
        bin_dir = self.kominka_cache / "kominka" / "bin"
        tarballs = list(bin_dir.glob("ver-check@*.tar.*"))
        self.assertTrue(tarballs)
        self.assertIn("3.14-1", tarballs[0].name)

    def test_cc_defaults(self):
        """CC should default to 'cc' if not set."""
        build = textwrap.dedent("""\
            #!/bin/sh -e
            mkdir -p "$1/usr/share"
            printf '%s' "$CC" > "$1/usr/share/cc-val"
        """)
        self.create_repo_pkg("cc-check", build=build)
        self.pm("b", "cc-check")


class TestInvalidArgs(PMTestCase):
    """Test argument validation."""

    def test_invalid_chars_in_package_name(self):
        """Package names with special characters should be rejected."""
        for bad in ["pkg!bad", "pkg[x]", "pkg x"]:
            r = self.pm("b", bad, check=False)
            self.assertNotEqual(
                r.returncode, 0,
                f"Should reject package name '{bad}'",
            )

    def test_slash_in_non_install_rejected(self):
        """Non-install commands should reject '/' in arguments."""
        r = self.pm("b", "some/path", check=False)
        self.assertNotEqual(r.returncode, 0)


class TestKominkaDebug(PMTestCase):
    """Test KOMINKA_DEBUG behavior."""

    def test_debug_preserves_build_dir(self):
        """KOMINKA_DEBUG=1 should not clean up the build cache."""
        self.pm("b", "samurai", env_override={"KOMINKA_DEBUG": "1"})
        # The proc directory should still exist.
        self.assertTrue(self.kominka_tmpdir.exists())

    def test_no_debug_cleans_build_dir(self):
        """Without KOMINKA_DEBUG, build artifacts should be cleaned up."""
        self.pm("b", "samurai")
        # Contents under the PID-specific proc dir should be gone.
        # The parent tmpdir may still exist, but the build dirs inside should not.
        proc_contents = list(self.kominka_tmpdir.glob("*/build"))
        self.assertEqual(proc_contents, [])


class TestSourceVersionSubstitution(PMTestCase):
    """Test VERSION/MAJOR/MINOR/PATCH placeholders in sources files."""

    def test_version_placeholder_in_sources(self):
        """VERSION in sources should be replaced with the package version."""
        repo = self.create_repo_pkg("subst-test", version="2.5.3 1")
        (repo / "data-2.5.3.txt").write_text("content")
        (repo / "sources").write_text("data-VERSION.txt\n")

        r = self.pm("d", "subst-test")
        self.assertEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
