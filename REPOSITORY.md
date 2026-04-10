# Repository Design

## Overview

A package repository server so `pm i` works without a local git checkout of
package definitions. A Rust HTTP server backed by R2 via S3 APIs, with a
content-addressed package index. Downloading is public. Uploading requires
authentication.

Package definitions move from `davinci/tests/fixtures/repo/` to a new repo at
`~/d/repo`, which also contains the server code.

## Content-Addressed Binary Cache

Tarballs are named by a hash of their build inputs, not by version string.

```
hash = sha256(contents of PKGBUILD.ysh)
```

If anything in the package definition changes (version, dep, build script,
source URL), the hash changes. Does NOT include transitive dependency hashes —
avoids Nix-style rebuild cascades. Computable before building, which enables
cache-hit detection: if `{arch}/{pkg}/{hash}.tar.gz` exists on R2, skip the
build entirely.

```
Local:  ${bin_dir}/${pkg}@${hash}.tar.gz
R2:     ${arch}/${pkg}/${hash}.tar.gz
```

The installed database gains a `hash` file at
`/var/db/kominka/installed/{pkg}/hash`, written during `pkg_install`. This lets
`pkg_outdated` compare hashes instead of version-release strings — catches
cases where the build script changed without a version bump.

## Package Index

One JSON file per architecture, stored in R2, served by the server.

```json
{
  "_version": 1,
  "packages": {
    "curl": {
      "ver": "8.19.0",
      "rel": "6",
      "deps": ["boringssl", "zlib"],
      "hash": "a1b2c3d4...",
      "sha256": "e5f6a7b8..."
    },
    "core": {
      "ver": "1.0.0",
      "rel": "1",
      "deps": ["baselayout", "glibc", "busybox"],
      "hash": "f9e8d7c6...",
      "sha256": ""
    }
  }
}
```

- `_version` — index format version (for future evolution)
- `hash` — PKGBUILD.ysh content hash (R2 key / build identity)
- `sha256` — tarball content hash (download integrity verification; empty for
  metapackages)
- `deps` — runtime deps only (mkdeps not needed for `pm i`)

Updated server-side on each upload via read-modify-write. Server keeps the
index in memory and writes to S3 on mutation. On startup, reads from S3 to
hydrate.

## Repository Layout

```
~/d/repo/
  packages/                     # PKGBUILDs (from davinci/tests/fixtures/repo/)
    curl/PKGBUILD.ysh
    boringssl/PKGBUILD.ysh
    ...
  server/                       # Rust HTTP server
    Cargo.toml
    src/
      main.rs                   # entry point, config, server setup
      routes.rs                 # route dispatch
      packages.rs               # index serving, upload, download proxy
      auth.rs                   # token validation middleware
      s3.rs                     # S3 client (put, get, head)
    kominka-repo.service        # systemd unit file
    kominka-repo.env.example    # env config template
  scripts/
    seed-index.sh               # one-time: generate packages.json from PKGBUILDs
    build-deb.sh                # build .deb package
```

davinci keeps a minimal set of test-only PKGBUILDs in `tests/fixtures/`.

## Server

### Tech Stack

| Component | Crate | Role |
|-----------|-------|------|
| HTTP | `axum` + `tokio` | Async HTTP server |
| S3 | `aws-sdk-s3` | R2 via S3-compatible API |
| Logging | `tracing` | Request logging |

No TLS — listens on `127.0.0.1:3000` behind a reverse proxy. No database —
auth is a static API key in v1.

### Configuration

Env vars via systemd `EnvironmentFile`:

```sh
LISTEN_ADDR=127.0.0.1:3000
S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
S3_BUCKET=kominka-sources
S3_ACCESS_KEY_ID=...
S3_SECRET_ACCESS_KEY=...
S3_REGION=auto
API_KEY=<random 64 hex bytes>
```

### Deployment

systemd service:
```ini
[Unit]
Description=Kominka Package Repository
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/kominka-repo
EnvironmentFile=/etc/kominka-repo/env
StateDirectory=kominka-repo
User=kominka-repo
Group=kominka-repo

[Install]
WantedBy=multi-user.target
```

Packaged as `.deb` via `build-deb.sh` or `cargo-deb`:
- `/usr/bin/kominka-repo`
- `/lib/systemd/system/kominka-repo.service`
- `/etc/kominka-repo/env.example`
- postinst: create `kominka-repo` user, `mkdir -p /var/lib/kominka-repo`

### API

Public (no auth):

```
GET /{arch}/packages.json
```
Serves the package index from the in-memory cache. Returns
`Cache-Control: public, max-age=60`.

```
GET /{arch}/{pkg}/{hash}.tar.gz
```
Reads from R2 via S3 GetObject and streams the response body to the client.
Returns 404 if the object does not exist.

```
GET /health
```
Returns `200 {"status":"ok"}`.

Authenticated (`Authorization: Bearer {API_KEY}`):

```
POST /api/upload
Content-Type: application/octet-stream
X-Arch: aarch64-linux-gnu
X-Pkg: curl
X-Ver: 8.19.0
X-Rel: 6
X-Hash: a1b2c3d4...
X-Deps: boringssl,zlib
Body: <tarball bytes>
```

Server flow:
1. Compare bearer token against `API_KEY` env var
2. Validate headers (arch is known, pkg name matches `[a-z0-9][a-z0-9._-]*`)
3. Stream body to temp file, compute SHA-256 alongside
4. S3 PutObject: `{arch}/{pkg}/{hash}.tar.gz`
5. Update in-memory index, write to S3
6. Return `201 {"ok": true, "sha256": "..."}`

```
POST /api/publish
Content-Type: application/json
Authorization: Bearer {API_KEY}
Body: {"arch": "...", "pkg": "...", "ver": "...", "rel": "...",
       "hash": "...", "deps": [...]}
```

Registers a metapackage (no tarball). Updates the index only.

### Edge Cases

**Streaming uploads.** Server streams the request body to a temp file on disk,
computing SHA-256 while writing, then uploads to S3. Avoids buffering large
tarballs in memory. Configurable max body size (~500MB).

**Index concurrency.** Single-process server. Index updates are serialized via
a Mutex around the in-memory index + S3 write. One upload blocks while another
completes. S3 PutObject is atomic from the reader's perspective.

**VPS reboot.** systemd restarts the service. In-memory index cache rebuilds
from S3 on first request.

**Stale tarballs.** When a package is rebuilt (new hash), the old tarball
stays in R2 unreferenced. Harmless — cleanup can be a future script that diffs
R2 objects against index entries.

## pm.ysh Changes

### New environment variables

`KOMINKA_REPO` — repo server URL (e.g., `https://repo.kominka.org`).
`KOMINKA_TOKEN` — bearer token for uploads (env var or stored locally).

Both added to:
- Global declarations (~line 31)
- `ENV => get()` import block (~line 2425)
- `as_user` env passthrough (~line 2293)
- `KOMINKA_REPO` added to `config` dict (~line 2487)

### New globals

```ysh
var _remote_index = {}     # Dict of dicts, keyed by package name
var _remote_loaded = false
```

### New procs

`pkg_hash(pkg_dir; result Ref)` — SHA-256 of `${pkg_dir}/PKGBUILD.ysh` via
existing `_sh256` + `cmd_sha`.

`_download(dest, url)` — curl/wget wrapper extracted from `pkg_source_url`
(lines 774-793) without the package dict parameter. Used by `index_refresh`
and `pkg_cache`.

`index_load()` — parse `${cac_dir}/packages.json` into `_remote_index`:
```ysh
json read < "${cac_dir}/packages.json"
setglobal _remote_index = _reply["packages"]
```
Idempotent (checks `_remote_loaded`).

`index_refresh()` — download `${KOMINKA_REPO}/${sys_arch}/packages.json` to
`${cac_dir}/packages.json`. Resets `_remote_loaded = false`.

`auth_token_load(; result Ref)` — load the bearer token:
1. `KOMINKA_TOKEN` env var (for CI)
2. `security find-generic-password -s kominka-repo -w` (macOS Keychain)
3. `~/.config/kominka/token` (Linux fallback)

`auth_token_store(token)` — store the bearer token:
- macOS: `security add-generic-password -U -s kominka-repo -a kominka -w`
- Linux: `~/.config/kominka/token` (dir 0700, file 0600)

### Modified procs

**`pkg_load` (line 364)** — add `hash` to every package dict.

PKGBUILD.ysh branch: compute hash via `pkg_hash` after sourcing.

Installed db branch: read `${pkg_dir}/hash` if it exists (empty otherwise).

New remote branch: if `pkg_dir` starts with `"remote:"`, construct dict from
`_remote_index`:
```ysh
var _rname = ${pkg_dir#remote:}
index_load
var _ri = _remote_index[_rname]
setvar d = {
    name: _rname, ver: _ri["ver"], rel: _ri["rel"],
    deps: _ri["deps"], hash: _ri["hash"],
    sha256: _ri["sha256"],
    mkdeps: [], nostrip: false, sources: [], checksums: [],
    checksums_aarch64: [], checksums_x86_64: [],
}
```

**`_pkg_find` (line 454)** — remote index fallback.

After local KOMINKA_PATH + sys_db search returns nothing:
```ysh
if (test_flag === '' and mode === '' and KOMINKA_REPO !== '') {
    index_load
    if (name in _remote_index) {
        setglobal repo_dir = "remote:${name}"
        return 0
    }
}
```

**`pkg_tar` (line 1212)** — hash-based tarball naming.

```ysh
var tf_path = "${bin_dir}/$[p.name]@$[p.hash].tar.${KOMINKA_COMPRESS}"
```

**`pkg_cache` (line 616)** — hash-based cache lookup + integrity check.

Local lookup:
```ysh
setglobal tar_file = "${bin_dir}/${pkg}@$[p.hash].tar.${KOMINKA_COMPRESS}"
```

Remote download when `KOMINKA_REPO` is set:
```ysh
var _url = "${KOMINKA_REPO}/${sys_arch}/${pkg}/$[p.hash].tar.${KOMINKA_COMPRESS}"
setglobal tar_file = "${bin_dir}/${pkg}@$[p.hash].tar.${KOMINKA_COMPRESS}"
try { _download $tar_file $_url }
```

After download, verify integrity:
```ysh
_sh256 $tar_file
if (hash !== p.sha256 and p.sha256 !== '') {
    rm -f $tar_file
    die $pkg "Integrity check failed (expected $[p.sha256], got $hash)"
}
```

**`pkg_install_all` (line 1817)** — hash-based URLs for parallel downloads.

```ysh
var _name = "${pkg}@$[p.hash].tar.${KOMINKA_COMPRESS}"
var _dest = "${bin_dir}/${_name}"
var _url = "${KOMINKA_REPO}/${sys_arch}/${pkg}/$[p.hash].tar.${KOMINKA_COMPRESS}"
```

**`pkg_install` (line 1926)** — write hash to installed db.

After installation, before the success log:
```ysh
write -- $[p.hash] > "${sys_db}/${_ipkg}/hash"
```

Filename parsing unchanged: `curl@a1b2c3.tar.gz` → `${_ipkg%@*}` → `curl`.

**`pkg_outdated` (line 2083)** — compare hashes.

```ysh
if (inst.hash !== '' and repo_p.hash !== '') {
    if (inst.hash !== repo_p.hash) { ... }
} elif ("$[inst.ver]-$[inst.rel]" !== "$[repo_p.ver]-$[repo_p.rel]") {
    # Fallback for packages installed before hash tracking
    ...
}
```

**`pkg_upload` (line 570)** — POST to server.

```ysh
$cmd_get -X POST \
    -H "Authorization: Bearer ${_token}" \
    -H "X-Arch: ${sys_arch}" \
    -H "X-Pkg: ${_pkg}" \
    -H "X-Ver: $[_p.ver]" \
    -H "X-Rel: $[_p.rel]" \
    -H "X-Hash: ${_hash}" \
    -H "X-Deps: ${_deps_header}" \
    --data-binary "@${_tarball}" \
    "${KOMINKA_REPO}/api/upload"
```

For metapackages, POST JSON to `/api/publish`.

**`pkg_update` (line 2012)** — add `index_refresh` before git pull.

**`args` (line 2306)** — add `auth { pm_auth }` case. Update help text.

### Removed

- `KOMINKA_BUCKET` env var and all references
- `KOMINKA_BIN_MIRROR` env var and all references
- All `wrangler` usage in `pkg_upload`

## Implementation Order

1. Create `~/d/repo`, move `packages/`
2. Server skeleton — Cargo.toml, main.rs, config, axum routes, health endpoint
3. S3 layer — put, get, head
4. Package routes — GET index, GET tarball (proxy), POST upload, POST publish
5. Auth middleware — compare bearer token against `API_KEY`
6. Seed script — parse PKGBUILDs with ysh, generate packages.json
7. pm.ysh: `pkg_hash`, update `pkg_load` to include hash
8. pm.ysh: tarball naming — `pkg_tar`, `pkg_cache`, `pkg_install_all`,
   `pkg_install` (hash file)
9. pm.ysh: remote index — `index_load`, `index_refresh`, `_pkg_find` fallback,
   `pkg_load` remote branch
10. pm.ysh: upload — replace wrangler with POST
11. pm.ysh: `auth_token_load`/`auth_token_store`, `KOMINKA_TOKEN`
12. pm.ysh: cleanup — remove `KOMINKA_BUCKET`, `KOMINKA_BIN_MIRROR`, wrangler
13. `.deb` packaging + systemd service

## Verification

- `pm b curl` → produces `curl@{hash}.tar.gz` in local cache
- `pm p curl` → POST succeeds, tarball in R2 at `{arch}/curl/{hash}.tar.gz`,
  index updated
- `pm u` → fresh packages.json downloaded
- `pm i curl` (no git checkout) → deps resolved from index, tarballs
  downloaded, integrity verified, installed
- `pm o` → detects hash mismatches between installed and repo versions
- Corrupt a downloaded tarball → pm detects sha256 mismatch, refuses to install
- CI: `KOMINKA_TOKEN=<key> pm p curl` → upload succeeds

## V2: Passkey Authentication + JWT for CI

The static API key is sufficient for a single maintainer but doesn't scale to
multiple contributors and lacks the security properties of modern
authentication. V2 replaces it with browser passkeys for human auth and
JWT/OIDC for CI.

### Dependencies Added

| Crate | Role |
|-------|------|
| `rusqlite` (bundled) | Auth state: users, credentials, tokens, sessions |
| `webauthn-rs` | Passkey registration/authentication |
| `jsonwebtoken` | CI OIDC token verification |

### SQLite Schema

```sql
CREATE TABLE users (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE credentials (
  id         TEXT PRIMARY KEY,       -- base64url credential ID
  user_id    TEXT NOT NULL REFERENCES users(id),
  public_key BLOB NOT NULL,          -- COSE public key
  counter    INTEGER NOT NULL DEFAULT 0,
  transports TEXT,                   -- JSON array: ["internal","hybrid"]
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE tokens (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id),
  token_hash TEXT NOT NULL UNIQUE,   -- SHA-256 of bearer token
  name       TEXT NOT NULL DEFAULT 'cli',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_used  TEXT
);

CREATE TABLE sessions (
  id         TEXT PRIMARY KEY,       -- 64 hex chars
  token      TEXT,                   -- plaintext (ephemeral, returned once then cleared)
  challenge  TEXT,                   -- WebAuthn challenge
  user_id    TEXT,
  status     TEXT NOT NULL DEFAULT 'pending',  -- pending | completed | consumed
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### Configuration Added

```sh
ALLOWED_USERS=josh
RP_ID=repo.kominka.org
RP_ORIGIN=https://repo.kominka.org
DB_PATH=/var/lib/kominka-repo/auth.db
JWT_JWKS_URL=https://token.actions.githubusercontent.com/.well-known/jwks
JWT_ISSUER=https://token.actions.githubusercontent.com
JWT_AUDIENCE=kominka-repo
JWT_SUBJECT_PATTERN=repo:josh/*
```

### Passkey Auth Flow

```
pm auth
  1. openssl rand -hex 32 → session ID
  2. Open https://repo.kominka.org/auth?session={id} in browser
     (macOS: open, Linux: xdg-open, fallback: print URL)
  3. Poll GET /auth/poll?session={id} every 2s (up to 5 min)
  4. Browser: user taps passkey → server creates token → binds to session
  5. Poll returns token (once, then server clears it from session row)
  6. pm stores token via auth_token_store
```

Session expiry: 10 minutes. Token returned exactly once, then cleared.

### API Endpoints Added

```
GET  /auth?session={id}               # passkey HTML page
POST /auth/register/options            # registration challenge
POST /auth/register/verify             # verify + create user + token
POST /auth/authenticate/options        # authentication challenge
POST /auth/authenticate/verify         # verify assertion + create token
GET  /auth/poll?session={id}           # CLI polls for completed token
```

### Auth Page

Single HTML file with `@simplewebauthn/browser` bundled inline (pre-built with
esbuild, committed as static asset). Minimal styling (system font, centered
card, dark mode via `prefers-color-scheme`).

Flow:
1. Page reads `session` from query params
2. If user has no passkey registered: show Register button (enter username,
   tap passkey)
3. If registered: show Sign In button (tap passkey, discoverable)
4. On success: "Done — you can close this tab"

Allowed usernames hardcoded in `ALLOWED_USERS` env var. Registration rejects
unknown usernames.

### Auth Middleware (replaces static key check)

1. Extract bearer token from `Authorization` header
2. SHA-256 hash it, check `tokens` table → authenticated (passkey path)
3. If not found, attempt JWT decode + JWKS verification → authenticated (CI)
4. Neither → `401 Unauthorized`

Token properties: 64 random hex bytes (256 bits entropy). Stored as SHA-256
hash in DB — server never stores plaintext. No expiration (long-lived like SSH
keys). `last_used` updated on each upload.

JWT config is optional — if `JWT_JWKS_URL` is unset, only passkey-issued
tokens work.

### JWT/OIDC for CI

GitHub Actions provides a short-lived OIDC token. The CI job sets
`KOMINKA_TOKEN` and calls `pm p`. The server validates the JWT by:

1. Fetching JWKS keys from `JWT_JWKS_URL` (cached, periodically refreshed)
2. Verifying JWT signature against JWKS
3. Checking claims: `iss`, `aud`, `sub` against configured values

Example GitHub Actions usage:
```yaml
permissions:
  id-token: write
  contents: read

steps:
  - name: Get OIDC token
    run: |
      TOKEN=$(curl -s \
        -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=kominka-repo" | jq -r .value)
      echo "KOMINKA_TOKEN=$TOKEN" >> $GITHUB_ENV

  - name: Upload package
    run: pm p curl
    env:
      KOMINKA_REPO: https://repo.kominka.org
```

### pm.ysh: `pm auth` Command

```ysh
proc pm_auth () {
    if (KOMINKA_REPO === '') { die "KOMINKA_REPO not set" }

    var _session = ''
    try { setvar _session = $(openssl rand -hex 32 2>/dev/null) }
    if (_session === '') {
        try { setvar _session = $(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n') }
    }

    var _auth_url = "${KOMINKA_REPO}/auth?session=${_session}"
    log "Opening browser for authentication"
    write -- $_auth_url

    try { open $_auth_url 2>/dev/null }
    if failed { try { xdg-open $_auth_url 2>/dev/null } }

    log "Waiting for authentication..."

    var _poll_url = "${KOMINKA_REPO}/auth/poll?session=${_session}"
    var _attempts = 0
    while (_attempts < 150) {
        sleep 2
        var _body = ''
        try { setvar _body = $($cmd_get -sf "${_poll_url}") }
        if failed { setvar _attempts += 1; continue }

        echo $_body | json read
        case (_reply["status"]) {
            complete {
                auth_token_store $_reply["token"]
                log "Authenticated successfully"
                return
            }
            expired { die "Session expired" }
        }
        setvar _attempts += 1
    }
    die "Authentication timed out"
}
```

### V2 Presigned Downloads

Replace the proxy-based GET handler with presigned S3 URLs:

1. S3 HeadObject to verify existence → 404 if missing
2. Generate presigned S3 GET URL (1 hour TTL)
3. Return `302 Location: <presigned URL>`
4. On presign failure: fall back to proxy

curl (`-fLo`) and busybox wget both follow 302 redirects and preserve query
parameters in the redirect URL (where the S3 signature lives). This offloads
download bandwidth from the server to R2.

### Rate Limiting

In-memory token bucket:
- Auth endpoints: 10 requests/min per IP
- Uploads: 60 requests/min per token
- Index/tarball GETs: no limit (public, cacheable)
