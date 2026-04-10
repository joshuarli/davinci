# Repository Design

Notes on future repository and package cache design.

## Content-Addressed Binary Cache

Today packages are stored by version: `{arch}/{pkg}/{ver}-{rel}.tar.gz`.
This means "what's on R2 right now" is ambiguous — a rebuild increments `rel`
but the old tarball lingers, and there's no way to verify a tarball corresponds
to a specific source+build combination.

**Proposal:** Name tarballs by a hash of their inputs:
`{arch}/{pkg}/{hash}.tar.gz`

Where `hash` is derived from:
- The source URLs + their checksums (what went in)
- The build script content (how it was built)
- The dependency closure hashes (what it was built against)

Benefits:
- Reproducibility is verifiable: same inputs → same hash → same binary
- No "stale release" confusion — if the build script changes, hash changes
- Cache hits are exact: if the hash exists, it's correct by definition
- Old tarballs naturally expire (nothing references them)
- Version string becomes metadata only, not the cache key

The package database would still track human-readable versions for `pm l`,
`pm U`, etc. The hash is purely a cache key.

This is similar to how Nix/Guix address store paths, but without requiring
a full functional package manager. R2 is just a content-addressed blob store.

## Open Questions

- How to handle the initial hash bootstrap (need to build to know the hash)
- Whether to hash just the direct inputs or the full transitive closure
- Migration path from the current version-addressed layout
