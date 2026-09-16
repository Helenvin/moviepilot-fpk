# moviepilot-fpk

Relocatable runtime payloads for running [MoviePilot](https://github.com/jxxghp/MoviePilot)
v3 **natively** on fnOS, packaged as an `.fpk` by
[Helenvin/fn-apps](https://github.com/Helenvin/fn-apps).

This repository ships no application code of its own. It builds and publishes
the heavy, architecture-specific payload that the fpk cannot reasonably
assemble on a NAS, and nothing else.

## Why this exists

MoviePilot v3 officially supports a non-Docker deployment, but it assumes it
owns the machine: it wants Python 3.14+, it downloads Node on first install,
it manages its own daemons through a CLI, and its browser adapters need a
stealth Chromium plus a pile of system libraries. On a NAS that is a lot to
ask of the host, and the fnOS Debian 12 userland cannot be assumed to have
any of it.

So everything is baked here, off-device, and shipped as one archive per
architecture.

## What goes into a payload

| Component | Notes |
|---|---|
| CPython 3.14 | from [python-build-standalone](https://github.com/astral-sh/python-build-standalone), glibc >= 2.17 |
| Backend virtualenv | `uv sync --locked --no-dev`, upstream dependency groups |
| Node 20.12.1 | the same runtime upstream's installer would fetch |
| Frontend bundle | `dist.zip` from `jxxghp/MoviePilot-Frontend` |
| Site adapters | `user.sites.v3.bin` + `sites.cpython-314-<machine>-linux-gnu.so` |
| Stealth Chromium | via `python -m cloakbrowser install` (free kernel, no licence key) |

## Build base

Everything is built inside `debian:12-slim`, because **fnOS is Debian 12**.
A wheel or interpreter linked against a newer glibc produces a payload that
dies on the NAS with a bare `GLIBC_2.xx not found`. That is also why CPython
comes from python-build-standalone rather than the official `python:3.14-slim`
image, which targets a much newer glibc.

`arm64` is built on GitHub's native arm64 runner rather than under QEMU, so
neither architecture is emulated.

## Relocatability

The payload is baked under a fixed prefix:

```
/opt/moviepilot/
├── python/     CPython 3.14
├── venv/       backend virtualenv (bin/python* are relative symlinks)
├── app/        MoviePilot checkout: app/, public/, .runtime/node/
├── browser/    CloakBrowser cache directory
└── BUILD-INFO
```

Every absolute path written into the tree points at that prefix, so the
installer rewrites the whole thing to `${TRIM_APPDEST}/runtime` with one
pass over the venv's text files (`pyvenv.cfg` and the script shebangs). The
`bin/python*` symlinks are already relative, so they survive relocation
untouched.

## Releases

Assets are published on `runtime/<upstream tag>` releases:

```
moviepilot-runtime-amd64.tar.zst   (+ .sha256)
moviepilot-runtime-arm64.tar.zst   (+ .sha256)
```

To cut a payload for a specific upstream version, run the
**Build MoviePilot native runtime** workflow with `version` set to that tag.
Leaving it empty tracks the newest `v3.*` upstream release. Both payloads
already present on the release cause the work to be skipped unless `force`
is set.

## Cost

Expect roughly half a gigabyte per architecture once compressed — the
dependency tree is large and the Chromium kernel alone is a couple of hundred
megabytes. That is the price of a self-contained, offline-installable native
package.
