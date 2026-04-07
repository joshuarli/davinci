"""Cheap/fast tests for pm that don't require building packages.

These tests exercise search, list, dependency resolution, checksum,
source resolution, argument validation, and version output by
manually populating the installed database and repo directories.

Every test class is duplicated for the YSH port via subclassing.
"""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PM_SH = ROOT / "pm"
PM_YSH = ROOT / "pm.ysh"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
REPO = FIXTURES / "repo"
YSH = shutil.which("ysh") or "/usr/local/bin/ysh"
HAS_YSH = os.path.isfile(YSH) and os.access(YSH, os.X_OK)


class CheapPMTestCase(unittest.TestCase):
    """Base class with isolated KISS environment and manual db population."""

    # Subclasses override these to switch between sh/ysh.
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

    def setUp(self):
        self.tmpdir = os.path.realpath(tempfile.mkdtemp(prefix="pm-cheap-"))
        self.kiss_root = Path(self.tmpdir) / "root"
        self.kiss_cache = Path(self.tmpdir) / "cache"
        self.kiss_tmpdir = Path(self.tmpdir) / "proc"

        (self.kiss_root / "var/db/kiss/installed").mkdir(parents=True)
        (self.kiss_root / "var/db/kiss/choices").mkdir(parents=True)

        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmpdir,
            "LOGNAME": os.environ.get("LOGNAME", "testuser"),
            "KISS_PATH": str(REPO),
            "KISS_ROOT": str(self.kiss_root),
            "KISS_COLOR": "0",
            "KISS_PROMPT": "0",
            "KISS_COMPRESS": "gz",
            "KISS_TMPDIR": str(self.kiss_tmpdir),
            "XDG_CACHE_HOME": str(self.kiss_cache),
        }

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def pm(self, *args, env_override=None, check=True):
        env = {**self.env}
        if env_override:
            env.update(env_override)
        result = subprocess.run(
            [self.PM_INTERPRETER, str(self.PM_SCRIPT), *args],
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

    def fake_install(self, name, version="1.0 1", depends="", manifest=None):
        """Populate the installed db for a package without building it.

        Creates the db entry with version, build, manifest, and optionally
        depends files — mimicking what a real install leaves behind.
        """
        db = self.kiss_root / "var/db/kiss/installed" / name
        db.mkdir(parents=True, exist_ok=True)
        (db / "version").write_text(version + "\n")
        if depends:
            (db / "depends").write_text(depends + "\n")
        # pkg_find_version checks that the build file is executable.
        build = db / "build"
        build.write_text("#!/bin/sh\n")
        build.chmod(0o755)
        if manifest is None:
            # Real manifests include the db entries themselves.
            db_prefix = f"/var/db/kiss/installed/{name}"
            lines = [
                f"/usr/bin/{name}",
                f"{db_prefix}/manifest",
                f"{db_prefix}/version",
                f"{db_prefix}/build",
            ]
            if depends:
                lines.append(f"{db_prefix}/depends")
            lines.append(f"{db_prefix}/")
            manifest = "\n".join(lines) + "\n"
        (db / "manifest").write_text(manifest)
        return db

    def create_repo_pkg(self, name, version="1.0 1", depends="", sources="",
                        build=None):
        """Create a minimal package in a temporary repo directory."""
        repo = Path(self.tmpdir) / "extra-repo" / name
        repo.mkdir(parents=True)
        (repo / "version").write_text(version + "\n")
        if depends:
            (repo / "depends").write_text(depends + "\n")
        if sources:
            (repo / "sources").write_text(sources + "\n")
        build_script = build or textwrap.dedent("""\
            #!/bin/sh -e
            mkdir -p "$1/usr/bin"
            printf 'mock' > "$1/usr/bin/{name}"
        """).format(name=name)
        (repo / "build").write_text(build_script)
        (repo / "build").chmod(0o755)
        self.env["KISS_PATH"] = str(repo.parent) + ":" + self.env["KISS_PATH"]
        return repo


class HelpTests:
    def test_no_args_prints_usage(self):
        r = self.pm()
        self.assertIn("kiss [a|b|c|d|i|l|r|s|u|U|v]", r.stderr)

    def test_help_mentions_all_commands(self):
        r = self.pm()
        for cmd in ["alternatives", "build", "checksum", "download",
                     "install", "list", "remove", "search", "update",
                     "upgrade", "version"]:
            self.assertIn(cmd, r.stderr, f"Help missing '{cmd}'")

    def test_version(self):
        r = self.pm("v")
        self.assertIn("5.5.28", r.stdout)


class SearchTests:
    def test_search_finds_package(self):
        r = self.pm("s", "zlib")
        self.assertIn("zlib", r.stdout)

    def test_search_finds_multiple(self):
        for pkg in ["boringssl", "curl", "musl", "busybox"]:
            r = self.pm("s", pkg)
            self.assertIn(pkg, r.stdout)

    def test_search_missing_fails(self):
        r = self.pm("s", "nonexistent-pkg-xyz", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_search_finds_repo_pkg(self):
        """Search should find packages we add to the repo."""
        self.create_repo_pkg("mypkg")
        r = self.pm("s", "mypkg")
        self.assertIn("mypkg", r.stdout)

    def test_search_prints_all_matches(self):
        """If a package exists in multiple repos, all paths are printed."""
        self.create_repo_pkg("zlib", version="999.0 1")
        r = self.pm("s", "zlib")
        lines = [l for l in r.stdout.strip().split("\n") if "zlib" in l]
        self.assertGreaterEqual(len(lines), 2)


class ListTests:
    def test_list_empty(self):
        r = self.pm("l", check=False)
        # SH version errors (glob expands to literal *), YSH returns 0 (empty glob).
        # In either case, no package names should appear in output.
        self.assertEqual(r.stdout.strip(), "")

    def test_list_fake_installed(self):
        self.fake_install("mypkg", "2.3 1")
        r = self.pm("l")
        self.assertIn("mypkg", r.stdout)
        self.assertIn("2.3-1", r.stdout)

    def test_list_multiple(self):
        self.fake_install("alpha", "1.0 1")
        self.fake_install("bravo", "2.0 2")
        r = self.pm("l")
        self.assertIn("alpha", r.stdout)
        self.assertIn("bravo", r.stdout)

    def test_list_specific_package(self):
        self.fake_install("target", "3.0 1")
        self.fake_install("other", "1.0 1")
        r = self.pm("l", "target")
        self.assertIn("target", r.stdout)
        self.assertNotIn("other", r.stdout)

    def test_list_specific_missing(self):
        r = self.pm("l", "nonexistent", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_list_version_format(self):
        """Output should be 'name version-release'."""
        self.fake_install("fmt", "4.5.6 3")
        r = self.pm("l")
        self.assertIn("fmt 4.5.6-3", r.stdout)


class DependencyTests:
    def test_circular_dependency_detected(self):
        self.create_repo_pkg("pkg-a", depends="pkg-b")
        self.create_repo_pkg("pkg-b", depends="pkg-a")
        r = self.pm("b", "pkg-a", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Circular", r.stderr)

    def test_missing_dependency_fails(self):
        """A package depending on something that doesn't exist should fail."""
        self.create_repo_pkg("lonely", depends="ghost-pkg")
        r = self.pm("b", "lonely", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not found", r.stderr)

    def test_deep_dependency_chain(self):
        """A -> B -> C -> D. Building A should discover all deps."""
        self.create_repo_pkg("dep-d")
        self.create_repo_pkg("dep-c", depends="dep-d")
        self.create_repo_pkg("dep-b", depends="dep-c")
        self.create_repo_pkg("dep-a", depends="dep-b")
        r = self.pm("b", "dep-a", check=False)
        # Should get past dep resolution without circular or missing dep errors.
        self.assertNotIn("Circular", r.stderr)
        # Check specifically for "'X' not found" (package not found), not
        # generic "not found" which appears in tool discovery messages.
        self.assertNotIn("' not found", r.stderr)

    def test_diamond_dependency(self):
        """A -> B, A -> C, B -> D, C -> D. No circular error."""
        self.create_repo_pkg("dia-d")
        self.create_repo_pkg("dia-c", depends="dia-d")
        self.create_repo_pkg("dia-b", depends="dia-d")
        self.create_repo_pkg("dia-a", depends="dia-b\ndia-c")
        r = self.pm("b", "dia-a", check=False)
        self.assertNotIn("Circular", r.stderr)
        self.assertNotIn("' not found", r.stderr)


class ChecksumTests:
    def test_checksum_generates_file(self):
        repo = self.create_repo_pkg("ckpkg")
        (repo / "data.tar.gz").write_bytes(b"fake tarball content")
        (repo / "sources").write_text("data.tar.gz\n")

        self.pm("c", "ckpkg")
        checksums_file = repo / "checksums"
        self.assertTrue(checksums_file.exists())
        content = checksums_file.read_text().strip()
        self.assertEqual(len(content), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in content))

    def test_checksum_no_sources(self):
        self.create_repo_pkg("nosrc")
        r = self.pm("c", "nosrc")
        self.assertEqual(r.returncode, 0)

    def test_checksum_multiple_sources(self):
        repo = self.create_repo_pkg("multi")
        (repo / "file1.txt").write_text("aaa")
        (repo / "file2.txt").write_text("bbb")
        (repo / "sources").write_text("file1.txt\nfile2.txt\n")

        self.pm("c", "multi")
        lines = (repo / "checksums").read_text().strip().split("\n")
        self.assertEqual(len(lines), 2)

    def test_checksum_deterministic(self):
        """Running checksum twice should produce the same result."""
        repo = self.create_repo_pkg("det")
        (repo / "payload.bin").write_bytes(b"\x00\x01\x02" * 100)
        (repo / "sources").write_text("payload.bin\n")

        self.pm("c", "det")
        first = (repo / "checksums").read_text()
        self.pm("c", "det")
        second = (repo / "checksums").read_text()
        self.assertEqual(first, second)

    def test_checksum_skips_git_sources(self):
        """git+ sources should not generate checksums."""
        repo = self.create_repo_pkg("gitpkg")
        (repo / "local.txt").write_text("data")
        (repo / "sources").write_text(
            "git+https://example.com/repo\nlocal.txt\n"
        )
        self.pm("c", "gitpkg")
        checksums = (repo / "checksums").read_text().strip()
        # Generation skips git sources entirely — only local.txt gets a hash.
        lines = checksums.split("\n")
        self.assertEqual(len(lines), 1)
        self.assertEqual(len(lines[0]), 64)


class DownloadTests:
    def test_download_local_sources(self):
        repo = self.create_repo_pkg("localpkg")
        (repo / "localfile.txt").write_text("content")
        (repo / "sources").write_text("localfile.txt\n")

        r = self.pm("d", "localpkg")
        self.assertEqual(r.returncode, 0)
        combined = r.stdout + r.stderr
        self.assertIn("found", combined)

    def test_download_missing_source_fails(self):
        repo = self.create_repo_pkg("badpkg")
        (repo / "sources").write_text("nonexistent-file.tar.gz\n")

        r = self.pm("d", "badpkg", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_download_no_sources_ok(self):
        self.create_repo_pkg("nosrc2")
        r = self.pm("d", "nosrc2")
        self.assertEqual(r.returncode, 0)


class VersionSubstitutionTests:
    def test_version_placeholder(self):
        repo = self.create_repo_pkg("subst", version="2.5.3 1")
        (repo / "data-2.5.3.txt").write_text("content")
        (repo / "sources").write_text("data-VERSION.txt\n")

        r = self.pm("d", "subst")
        self.assertEqual(r.returncode, 0)

    def test_major_minor_patch_placeholders(self):
        """MAJOR, MINOR, PATCH should also be substituted."""
        repo = self.create_repo_pkg("mmp", version="3.7.11 1")
        (repo / "data-3-7-11.txt").write_text("content")
        (repo / "sources").write_text("data-MAJOR-MINOR-PATCH.txt\n")

        r = self.pm("d", "mmp")
        self.assertEqual(r.returncode, 0)


class ArgumentValidationTests:
    def test_invalid_chars_rejected(self):
        for bad in ["pkg!bad", "pkg[x]", "pkg x"]:
            r = self.pm("b", bad, check=False)
            self.assertNotEqual(
                r.returncode, 0,
                f"Should reject package name '{bad}'",
            )

    def test_slash_in_non_install_rejected(self):
        r = self.pm("b", "some/path", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_slash_in_install_allowed(self):
        """Install accepts '/' (for tarball paths)."""
        # This will fail because the file doesn't exist, but it should
        # NOT fail on argument validation.
        r = self.pm("i", "/tmp/no-such-file.tar.gz", check=False)
        # Should fail because file is missing, not because of '/'.
        self.assertNotEqual(r.returncode, 0)
        # The error should NOT be about invalid arguments.
        self.assertNotIn("Invalid argument", r.stderr)

    def test_wildcard_rejected(self):
        r = self.pm("b", "pkg*", check=False)
        self.assertNotEqual(r.returncode, 0)


class RemoveDependentTests:
    """Test remove's dependent checking without building."""

    def test_remove_blocks_on_dependents(self):
        """Can't remove a package that others depend on."""
        self.fake_install("base-lib", "1.0 1")
        self.fake_install("consumer", "1.0 1", depends="base-lib")
        r = self.pm("r", "base-lib", check=False)
        self.assertNotEqual(r.returncode, 0)

    def test_remove_force_overrides_dependent_check(self):
        self.fake_install("base-lib", "1.0 1")
        self.fake_install("consumer", "1.0 1", depends="base-lib")
        # Create the file that the manifest references.
        f = self.kiss_root / "usr/bin/base-lib"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("mock")
        r = self.pm("r", "base-lib", env_override={"KISS_FORCE": "1"})
        self.assertEqual(r.returncode, 0)

    def test_remove_orphan_succeeds(self):
        """Removing a package with no dependents should succeed."""
        self.fake_install("orphan", "1.0 1")
        # Create the file that the manifest references.
        f = self.kiss_root / "usr/bin/orphan"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("mock")
        r = self.pm("r", "orphan")
        self.assertEqual(r.returncode, 0)
        self.assertFalse(
            (self.kiss_root / "var/db/kiss/installed/orphan").exists()
        )


class SH_HelpTests(CheapPMTestCase, HelpTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_SearchTests(CheapPMTestCase, SearchTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_ListTests(CheapPMTestCase, ListTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_DependencyTests(CheapPMTestCase, DependencyTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_ChecksumTests(CheapPMTestCase, ChecksumTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_DownloadTests(CheapPMTestCase, DownloadTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_VersionSubstitutionTests(CheapPMTestCase, VersionSubstitutionTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_ArgumentValidationTests(CheapPMTestCase, ArgumentValidationTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH

class SH_RemoveDependentTests(CheapPMTestCase, RemoveDependentTests):
    PM_INTERPRETER = "sh"
    PM_SCRIPT = PM_SH


@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_HelpTests(CheapPMTestCase, HelpTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_SearchTests(CheapPMTestCase, SearchTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_ListTests(CheapPMTestCase, ListTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_DependencyTests(CheapPMTestCase, DependencyTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_ChecksumTests(CheapPMTestCase, ChecksumTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_DownloadTests(CheapPMTestCase, DownloadTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_VersionSubstitutionTests(CheapPMTestCase, VersionSubstitutionTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_ArgumentValidationTests(CheapPMTestCase, ArgumentValidationTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH

@unittest.skipUnless(HAS_YSH, "ysh interpreter not found")
class YSH_RemoveDependentTests(CheapPMTestCase, RemoveDependentTests):
    PM_INTERPRETER = YSH
    PM_SCRIPT = PM_YSH


if __name__ == "__main__":
    unittest.main()
