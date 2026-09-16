#!/usr/bin/env bash
#
# Build the MoviePilot native runtime payload consumed by the fnOS fpk.
#
# This runs inside a debian:12-slim container on purpose: fnOS is Debian 12
# (glibc 2.36) and anything linked against a newer glibc refuses to start
# there. Python therefore comes from python-build-standalone (glibc >= 2.17)
# rather than python:3.x-slim, which is built against a much newer glibc.
#
# Env:
#   TARGET_ARCH   amd64 | arm64      (matches fn-apps TARBALL_ARCH)
#   MP_VERSION    upstream git tag, e.g. v3.0.3
#   NODE_VERSION  bundled Node runtime                (default 20.12.1)
#   OUT_DIR       output directory                    (default /out)
#
set -euo pipefail

TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH is required (amd64|arm64)}"
MP_VERSION="${MP_VERSION:?MP_VERSION is required (e.g. v3.0.3)}"
NODE_VERSION="${NODE_VERSION:-20.12.1}"
OUT_DIR="${OUT_DIR:-/out}"

case "$TARGET_ARCH" in
    amd64) MP_PLATFORM="x86_64" ;;
    arm64) MP_PLATFORM="aarch64" ;;
    *) echo "unsupported TARGET_ARCH: $TARGET_ARCH" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Layout
#
# Everything the payload needs lives under BUILD_ROOT, and every absolute path
# written into the tree (pyvenv.cfg, script shebangs, the .pth entry) starts
# with that prefix. The fnOS installer therefore relocates the whole tree to
# ${TRIM_APPDEST}/runtime with a single textual rewrite -- no rebuild needed
# for each deployment path.
# ---------------------------------------------------------------------------
BUILD_ROOT="/opt/moviepilot"
VENV_DIR="$BUILD_ROOT/venv"
APP_DIR="$BUILD_ROOT/app"
BROWSER_DIR="$BUILD_ROOT/browser"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# uv's interpreter store and wheel cache must stay OUTSIDE BUILD_ROOT, or
# roughly a gigabyte of download cache ends up inside the fpk.
export UV_PYTHON_INSTALL_DIR="/opt/uv-python"
export UV_CACHE_DIR="/opt/uv-cache"
# Bake the stealth Chromium into the payload instead of the builder's ~/.cloakbrowser.
export CLOAKBROWSER_CACHE_DIR="$BROWSER_DIR"
# Upstream derives its temp/cache dirs from CONFIG_DIR; keep the payload clean.
export CONFIG_DIR="/tmp/moviepilot-bake"
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

log "apt: build tooling"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential ca-certificates curl git jq pkg-config libssl-dev \
    unzip xz-utils zstd
rm -rf /var/lib/apt/lists/*

log "install uv"
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
uv --version

log "install Python 3.14 (python-build-standalone, glibc 2.17+)"
mkdir -p "$BUILD_ROOT"
uv python install 3.14
PY_SRC="$(uv python find 3.14)"
mv "$(dirname "$(dirname "$PY_SRC")")" "$BUILD_ROOT/python"
PY_BIN="$BUILD_ROOT/python/bin/python3.14"
"$PY_BIN" -c 'import platform, sys; print(sys.version); print(platform.machine())'

log "clone MoviePilot ${MP_VERSION}"
git clone --depth 1 --branch "$MP_VERSION" \
    https://github.com/jxxghp/MoviePilot.git "$APP_DIR"
rm -rf "$APP_DIR/.git"

log "bake deps + frontend + site resources + browser"
cd "$APP_DIR"
"$PY_BIN" "$SCRIPT_DIR/bake_runtime.py" \
    --python "$PY_BIN" \
    --venv "$VENV_DIR" \
    --node-version "$NODE_VERSION"

log "make the venv self-relocating"
# uv points bin/python* at the base interpreter with absolute symlinks. Swapping
# them for relative ones means the payload keeps working after it is moved,
# even if someone unpacks it by hand instead of through the installer.
PY_REAL="$(readlink -f "$BUILD_ROOT/python/bin/python3.14")"
PY_REL="${PY_REAL#"$BUILD_ROOT"/}"
(
    cd "$VENV_DIR/bin"
    ln -sfn "../../${PY_REL}" python3.14
    ln -sfn python3.14 python3
    ln -sfn python3 python
)
ls -l "$VENV_DIR/bin/python" "$VENV_DIR/bin/python3" "$VENV_DIR/bin/python3.14"
"$VENV_DIR/bin/python" -c 'import sys; print("venv:", sys.prefix, sys.version_info[:3])'

log "finalize payload"
# Anything still pointing at the build prefix with an absolute symlink cannot be
# fixed by a textual rewrite. The installer rebuilds these, but surfacing them
# here keeps the two sides honest.
ABS_LINKS="$(find "$BUILD_ROOT/python" "$BUILD_ROOT/venv" "$BUILD_ROOT/app/.runtime" \
    -type l -lname '/*' 2>/dev/null || true)"
if [ -n "$ABS_LINKS" ]; then
    printf 'absolute symlinks found (rewritten by the installer):\n%s\n' "$ABS_LINKS"
else
    echo "no absolute symlinks in python/, venv/, app/.runtime/"
fi

cat > "$BUILD_ROOT/BUILD-INFO" <<EOF
moviepilot_version=${MP_VERSION}
frontend_version=$("$PY_BIN" -c 'import version; print(version.FRONTEND_VERSION)')
python_version=$("$PY_BIN" -c 'import platform; print(platform.python_version())')
node_version=${NODE_VERSION}
target_arch=${TARGET_ARCH}
mp_platform=${MP_PLATFORM}
build_prefix=${BUILD_ROOT}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Keep the application importable no matter what cwd the daemon is started in.
SITE_PACKAGES="$("$VENV_DIR/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
printf '%s\n' "$BUILD_ROOT/app" > "$SITE_PACKAGES/moviepilot.pth"

log "payload size"
du -sh "$BUILD_ROOT"/python "$BUILD_ROOT"/venv "$BUILD_ROOT"/app "$BUILD_ROOT"/browser

log "pack"
mkdir -p "$OUT_DIR"
ASSET="moviepilot-runtime-${TARGET_ARCH}.tar.zst"
tar --zstd -cf "$OUT_DIR/$ASSET" -C "$BUILD_ROOT" \
    python venv app browser BUILD-INFO
(
    cd "$OUT_DIR"
    sha256sum "$ASSET" | tee "$ASSET.sha256"
    ls -lh "$ASSET"
)

log "done: $OUT_DIR/$ASSET"
