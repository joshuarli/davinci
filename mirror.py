#!/usr/bin/env python3
"""Download upstream sources and upload them to a Cloudflare R2 mirror.

Workflow:
    # Download upstream sources, skip what's already in R2
    mirror.py repo download -u https://pub-XXX.r2.dev

    # Upload local files to R2, skip what's already there
    mirror.py repo upload -b kominka-sources -u https://pub-XXX.r2.dev

    # Or do both in one pass
    mirror.py repo sync -b kominka-sources -u https://pub-XXX.r2.dev

    # Verify local files against repo checksums
    mirror.py repo verify

R2 bucket setup (one-time):
    wrangler login
    wrangler r2 bucket create kominka-sources
    # Then enable public access in the Cloudflare dashboard:
    #   R2 > kominka-sources > Settings > Public Access > Allow Access
    # Note the public URL (e.g. https://pub-<id>.r2.dev)

Downloads go to a temporary directory by default (auto-cleaned after
successful sync). Use -o to override. R2 object keys are <package>/<filename>.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

CHUNK_SIZE = 256 * 1024
MAX_RETRIES = 3
RETRY_BACKOFF = (2, 5, 15)
TIMEOUT = 120


def parse_version(version_file):
    """Read a package version file, return (version, release) tuple."""
    with open(version_file) as f:
        parts = f.read().strip().split()
    version = parts[0] if parts else ""
    release = parts[1] if len(parts) > 1 else "1"
    return version, release


def split_version(version):
    """Split version string into major, minor, patch, ident components."""
    m = re.match(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?(.*)", version)
    if not m:
        return version, "", "", ""
    return (
        m.group(1),
        m.group(2) or "",
        m.group(3) or "",
        m.group(4).lstrip(".") if m.group(4) else "",
    )


def resolve_placeholders(url, pkg_name, version, release):
    """Substitute VERSION, MAJOR, MINOR, PATCH, IDENT, PACKAGE in a URL."""
    major, minor, patch, ident = split_version(version)
    url = url.replace("VERSION", version)
    url = url.replace("RELEASE", release)
    url = url.replace("MAJOR", major)
    url = url.replace("MINOR", minor)
    url = url.replace("PATCH", patch)
    url = url.replace("IDENT", ident)
    url = url.replace("PACKAGE", pkg_name)
    return url


def find_packages(repo_dir):
    """Yield (pkg_name, pkg_dir) for each package with a sources file."""
    for entry in sorted(os.listdir(repo_dir)):
        pkg_dir = os.path.join(repo_dir, entry)
        sources = os.path.join(pkg_dir, "sources")
        version = os.path.join(pkg_dir, "version")
        if os.path.isdir(pkg_dir) and os.path.isfile(sources) and os.path.isfile(version):
            yield entry, pkg_dir


def parse_upstream_sources(sources_file):
    """Yield raw upstream URLs from a sources file (prefix stripped)."""
    with open(sources_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            src = line.split()[0]
            if src.startswith("upstream:"):
                yield src[len("upstream:"):]


def load_checksums(pkg_dir):
    """Load checksums for a package.

    Returns a list of hex digests corresponding to each non-mirror,
    non-git, non-local source line in the sources file (matching the
    order pkg_checksum_gen produces).
    """
    cksum_file = os.path.join(pkg_dir, "checksums")
    if not os.path.isfile(cksum_file):
        return []
    with open(cksum_file) as f:
        return [line.strip() for line in f if line.strip()]


def sha256_file(path):
    """Return hex SHA-256 digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def download_to_file(url, dest_fd):
    """Stream url contents into an open file descriptor. Returns bytes written."""
    req = urllib.request.Request(url, headers={"User-Agent": "kominka-mirror/1.0"})
    written = 0
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        content_length = resp.headers.get("Content-Length")
        while True:
            chunk = resp.read(CHUNK_SIZE)
            if not chunk:
                break
            os.write(dest_fd, chunk)
            written += len(chunk)

    if content_length is not None:
        expected = int(content_length)
        if written != expected:
            raise OSError(f"incomplete download: got {written} bytes, expected {expected}")

    if written == 0:
        raise OSError("empty response (0 bytes)")

    return written


def clean_stale_temps(dest_dir):
    """Remove leftover .mirror-* temp files from a previous interrupted run."""
    try:
        for name in os.listdir(dest_dir):
            if name.startswith(".mirror-"):
                path = os.path.join(dest_dir, name)
                try:
                    os.remove(path)
                except OSError:
                    pass
    except OSError:
        pass


def download(url, dest, dry_run=False):
    """Download url to dest atomically with retries. Returns True on success."""
    try:
        size = os.path.getsize(dest)
        if size > 0:
            print(f"  exists locally ({fmt_size(size)})")
            return True
        # 0-byte file is a partial/corrupt download — re-fetch.
        os.remove(dest)
    except OSError:
        pass

    if dry_run:
        print(f"  would download {url}")
        return True

    dest_dir = os.path.dirname(dest)
    os.makedirs(dest_dir, exist_ok=True)
    clean_stale_temps(dest_dir)
    print(f"  downloading {url}")

    last_err = None
    for attempt in range(MAX_RETRIES):
        if attempt > 0:
            delay = RETRY_BACKOFF[min(attempt - 1, len(RETRY_BACKOFF) - 1)]
            print(f"  retry {attempt}/{MAX_RETRIES - 1} in {delay}s...")
            time.sleep(delay)

        fd, tmp_path = tempfile.mkstemp(dir=dest_dir, prefix=".mirror-")
        try:
            nbytes = download_to_file(url, fd)
            os.close(fd)
            fd = -1
            os.rename(tmp_path, dest)
            tmp_path = None
            print(f"  ok ({fmt_size(nbytes)})")
            return True
        except KeyboardInterrupt:
            raise
        except (urllib.error.HTTPError, urllib.error.URLError, OSError) as e:
            last_err = e
            # 4xx errors won't resolve with retries.
            if isinstance(e, urllib.error.HTTPError) and 400 <= e.code < 500:
                print(f"  FAILED: {e}", file=sys.stderr)
                return False
        finally:
            if fd >= 0:
                os.close(fd)
            if tmp_path is not None:
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

    print(f"  FAILED after {MAX_RETRIES} attempts: {last_err}", file=sys.stderr)
    return False


def fmt_size(nbytes):
    """Format a byte count for display."""
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024:
            return f"{nbytes:.0f}{unit}" if unit == "B" else f"{nbytes:.1f}{unit}"
        nbytes /= 1024
    return f"{nbytes:.1f}TB"


def require_wrangler():
    """Check that wrangler is available on PATH."""
    if not shutil.which("wrangler"):
        print("error: wrangler not found on PATH", file=sys.stderr)
        print("install: npm install -g wrangler", file=sys.stderr)
        sys.exit(1)


def remote_exists(public_url, key):
    """Check if an object exists at the public R2 URL via HEAD request."""
    url = f"{public_url.rstrip('/')}/{key}"
    req = urllib.request.Request(url, method="HEAD",
                                headers={"User-Agent": "kominka-mirror/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status == 200
    except (urllib.error.HTTPError, urllib.error.URLError, OSError):
        return False


def r2_put(bucket, key, filepath):
    """Upload a file to R2. Returns True on success."""
    result = subprocess.run(
        ["wrangler", "r2", "object", "put", f"{bucket}/{key}",
         f"--file={filepath}", "--content-type=application/octet-stream",
         "--remote"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        print(f"  FAILED: {stderr}", file=sys.stderr)
        return False

    print(f"  uploaded ({fmt_size(os.path.getsize(filepath))})")
    return True


def collect_sources(repo_dir, packages=None):
    """Build list of (pkg_name, url, filename) to download.

    If packages is non-empty, only include those packages.
    """
    sources = []
    seen = set()

    for pkg_name, pkg_dir in find_packages(repo_dir):
        if packages and pkg_name not in packages:
            continue

        version, release = parse_version(os.path.join(pkg_dir, "version"))
        sources_file = os.path.join(pkg_dir, "sources")

        for raw_url in parse_upstream_sources(sources_file):
            url = resolve_placeholders(raw_url, pkg_name, version, release)
            filename = url.rsplit("/", 1)[-1]

            key = (pkg_name, filename)
            if key in seen:
                continue
            seen.add(key)

            sources.append((pkg_name, url, filename))

    return sources


def collect_local_files(out_dir):
    """Walk the output directory, yield (pkg_name, filename, filepath)."""
    if not os.path.isdir(out_dir):
        return

    for pkg_name in sorted(os.listdir(out_dir)):
        pkg_path = os.path.join(out_dir, pkg_name)
        if not os.path.isdir(pkg_path):
            continue
        for filename in sorted(os.listdir(pkg_path)):
            filepath = os.path.join(pkg_path, filename)
            if os.path.isfile(filepath) and not filename.startswith("."):
                yield pkg_name, filename, filepath


def cmd_download(args):
    """Download upstream sources, skipping what's already local or in R2."""
    repo_dir = os.path.abspath(args.repo)
    out_dir = os.path.abspath(args.outdir)
    packages = set(args.package) if args.package else None
    public_url = args.public_url

    if not os.path.isdir(repo_dir):
        print(f"error: repo directory not found: {repo_dir}", file=sys.stderr)
        return 1

    sources = collect_sources(repo_dir, packages)
    if not sources:
        print("nothing to download")
        return 0

    ok = 0
    skip = 0
    fail = 0

    try:
        for pkg_name, url, filename in sources:
            key = f"{pkg_name}/{filename}"
            dest = os.path.join(out_dir, pkg_name, filename)
            print(f"{pkg_name}: {filename}")

            if public_url and not os.path.exists(dest) and remote_exists(public_url, key):
                print(f"  already in bucket")
                skip += 1
                continue

            if download(url, dest, dry_run=args.dry_run):
                ok += 1
            else:
                fail += 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        fail += 1

    print(f"\n{ok} succeeded, {skip} already in bucket, {fail} failed")
    return 1 if fail else 0


def cmd_upload(args):
    """Upload local mirror tree to R2, skipping what's already there."""
    out_dir = os.path.abspath(args.outdir)
    bucket = args.bucket
    public_url = args.public_url
    packages = set(args.package) if args.package else None

    if not os.path.isdir(out_dir):
        print(f"error: output directory not found: {out_dir}", file=sys.stderr)
        return 1

    if not args.dry_run:
        require_wrangler()

    ok = 0
    skip = 0
    fail = 0

    try:
        for pkg_name, filename, filepath in collect_local_files(out_dir):
            if packages and pkg_name not in packages:
                continue

            key = f"{pkg_name}/{filename}"
            print(f"{pkg_name}: {filename}")

            if os.path.getsize(filepath) == 0:
                print(f"  skipping 0-byte file", file=sys.stderr)
                fail += 1
                continue

            if public_url and not args.force and remote_exists(public_url, key):
                print(f"  exists in bucket")
                skip += 1
                continue

            if args.dry_run:
                print(f"  would upload -> {key}")
                ok += 1
            elif r2_put(bucket, key, filepath):
                ok += 1
            else:
                fail += 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        fail += 1

    print(f"\n{ok} uploaded, {skip} already in bucket, {fail} failed")
    return 1 if fail else 0


def cmd_sync(args):
    """Download from upstream then upload to R2, skipping what's already mirrored."""
    repo_dir = os.path.abspath(args.repo)
    out_dir = os.path.abspath(args.outdir)
    packages = set(args.package) if args.package else None
    public_url = args.public_url

    if not os.path.isdir(repo_dir):
        print(f"error: repo directory not found: {repo_dir}", file=sys.stderr)
        return 1

    sources = collect_sources(repo_dir, packages)
    if not sources:
        print("nothing to sync")
        return 0

    if not args.dry_run:
        require_wrangler()

    ok = 0
    skip = 0
    fail = 0

    try:
        for pkg_name, url, filename in sources:
            key = f"{pkg_name}/{filename}"
            dest = os.path.join(out_dir, pkg_name, filename)
            print(f"{pkg_name}: {filename}")

            if public_url and remote_exists(public_url, key):
                print(f"  already in bucket")
                skip += 1
                continue

            if not download(url, dest, dry_run=args.dry_run):
                fail += 1
                continue

            if args.dry_run:
                print(f"  would upload -> {key}")
                ok += 1
            elif r2_put(args.bucket, key, dest):
                ok += 1
            else:
                fail += 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        fail += 1

    print(f"\n{ok} synced, {skip} already in bucket, {fail} failed")
    return 1 if fail else 0


def cmd_verify(args):
    """Verify downloaded sources against repo checksums."""
    repo_dir = os.path.abspath(args.repo)
    out_dir = os.path.abspath(args.outdir)
    packages = set(args.package) if args.package else None

    if not os.path.isdir(repo_dir):
        print(f"error: repo directory not found: {repo_dir}", file=sys.stderr)
        return 1

    ok = 0
    fail = 0
    skip = 0

    try:
        for pkg_name, pkg_dir in find_packages(repo_dir):
            if packages and pkg_name not in packages:
                continue

            checksums = load_checksums(pkg_dir)
            if not checksums:
                continue

            version, release = parse_version(os.path.join(pkg_dir, "version"))
            sources_file = os.path.join(pkg_dir, "sources")

            cksum_idx = 0
            seen = set()
            for raw_url in parse_upstream_sources(sources_file):
                url = resolve_placeholders(raw_url, pkg_name, version, release)
                filename = url.rsplit("/", 1)[-1]

                key = (pkg_name, filename)
                if key in seen:
                    continue
                seen.add(key)

                dest = os.path.join(out_dir, pkg_name, filename)

                if cksum_idx >= len(checksums):
                    break
                expected = checksums[cksum_idx]
                cksum_idx += 1

                if expected == "SKIP":
                    print(f"{pkg_name}: {filename} SKIP")
                    skip += 1
                    continue

                if not os.path.isfile(dest):
                    print(f"{pkg_name}: {filename} MISSING")
                    fail += 1
                    continue

                actual = sha256_file(dest)
                if actual == expected:
                    print(f"{pkg_name}: {filename} OK")
                    ok += 1
                else:
                    print(f"{pkg_name}: {filename} MISMATCH", file=sys.stderr)
                    print(f"  expected {expected}", file=sys.stderr)
                    print(f"  got      {actual}", file=sys.stderr)
                    fail += 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        fail += 1

    print(f"\n{ok} ok, {fail} failed, {skip} skipped")
    return 1 if fail else 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("repo", help="path to the package repo (e.g. tests/fixtures/repo)")
    p.add_argument("-o", "--outdir",
                   help="output directory for downloads (default: auto tmpdir)")
    p.add_argument("-p", "--package", action="append", default=[],
                   help="only process these packages (repeatable)")

    sub = p.add_subparsers(dest="command")

    dl = sub.add_parser("download", help="download upstream sources")
    dl.add_argument("-u", "--public-url",
                    help="public R2 URL — skip sources already mirrored")
    dl.add_argument("-n", "--dry-run", action="store_true")

    up = sub.add_parser("upload", help="upload local files to R2")
    up.add_argument("-b", "--bucket", required=True, help="R2 bucket name")
    up.add_argument("-u", "--public-url",
                    help="public R2 URL — skip files already in bucket")
    up.add_argument("-n", "--dry-run", action="store_true")
    up.add_argument("-f", "--force", action="store_true",
                    help="re-upload even if already in bucket")

    sy = sub.add_parser("sync", help="download + upload in one pass")
    sy.add_argument("-b", "--bucket", required=True, help="R2 bucket name")
    sy.add_argument("-u", "--public-url",
                    help="public R2 URL — skip sources already mirrored")
    sy.add_argument("-n", "--dry-run", action="store_true")

    sub.add_parser("verify", help="verify downloads against repo checksums")

    args = p.parse_args()
    cmd = args.command

    # Default outdir to a temporary directory.
    tmp_dir = None
    if not args.outdir:
        tmp_dir = tempfile.mkdtemp(prefix="mirror-")
        args.outdir = tmp_dir
        print(f"cache: {tmp_dir}")

    rc = 0
    if cmd is None or cmd == "download":
        if not hasattr(args, "dry_run"):
            args.dry_run = False
        if not hasattr(args, "public_url"):
            args.public_url = None
        rc = cmd_download(args)
    elif cmd == "upload":
        rc = cmd_upload(args)
    elif cmd == "sync":
        if not hasattr(args, "public_url"):
            args.public_url = None
        rc = cmd_sync(args)
    elif cmd == "verify":
        rc = cmd_verify(args)

    # Clean up temp dir after successful sync (files are in R2 now).
    if tmp_dir and cmd == "sync" and rc == 0:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        print(f"cleaned up {tmp_dir}")

    sys.exit(rc)


if __name__ == "__main__":
    main()
