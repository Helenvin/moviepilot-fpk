#!/usr/bin/env python3
"""Bake the relocatable MoviePilot native runtime tree.

Runs inside the build container with the MoviePilot checkout as cwd.

It drives upstream's own ``scripts/local_setup.py`` so the payload is exactly
what ``moviepilot setup`` would have produced on a user machine, with two
deliberate differences:

* the frontend bundle is unpacked from a locally downloaded ``dist.zip``.
  Upstream resolves it through the unauthenticated GitHub API, which is
  limited to 60 requests/hour per IP and therefore unreliable on shared
  CI runner addresses.
* the build never runs ``init``. Database, superuser and API token are
  created on first start on the NAS, against the app's own data directory.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType

FRONTEND_REPO = "jxxghp/MoviePilot-Frontend"


def _load(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", required=True, help="interpreter to build the venv from")
    parser.add_argument("--venv", required=True, help="venv directory to create")
    parser.add_argument("--node-version", default="20.12.1")
    parser.add_argument("--root", default=os.getcwd(), help="MoviePilot checkout")
    parser.add_argument(
        "--skip-browser",
        action="store_true",
        help="skip the stealth Chromium download (debugging runs only)",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    os.chdir(root)

    local_setup = _load(root / "scripts" / "local_setup.py", "moviepilot_local_setup")
    version = _load(root / "version.py", "moviepilot_version")
    app_version = version.APP_VERSION
    frontend_version = version.FRONTEND_VERSION
    print(f"==> MoviePilot {app_version} / frontend {frontend_version}", flush=True)

    # 1. Backend dependencies. install_deps() also pre-fetches the stealth
    #    Chromium into CLOAKBROWSER_CACHE_DIR, which the caller exported.
    local_setup.install_deps(
        python_bin=args.python,
        venv_dir=Path(args.venv),
        recreate=True,
    )

    if args.skip_browser:
        print("==> skipping browser kernel (--skip-browser)", flush=True)
    elif not (Path(os.environ["CLOAKBROWSER_CACHE_DIR"]) / "").exists():
        raise RuntimeError("CLOAKBROWSER_CACHE_DIR was not exported by the caller")

    # 2. Frontend bundle, fetched straight from the release asset so no
    #    GitHub API call is involved.
    archive = Path("/tmp/moviepilot-frontend-dist.zip")
    url = (
        f"https://github.com/{FRONTEND_REPO}/releases/download/"
        f"{frontend_version}/dist.zip"
    )
    print(f"==> download frontend {url}", flush=True)
    local_setup.download_file(url, archive)

    local_setup.install_frontend(
        frontend_version,
        args.node_version,
        archive=archive,
    )

    # 3. Site adapters (.so bound to the interpreter version and machine type).
    local_setup.install_resources(None, None)

    # 4. Everything the payload must not carry.
    for junk in (".git", "tests", "docs", "skills", "frontend-dist"):
        target = root / junk
        if target.exists():
            print(f"==> prune {junk}", flush=True)
            if target.is_dir():
                import shutil

                shutil.rmtree(target)
            else:
                target.unlink()

    print("==> bake complete", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
