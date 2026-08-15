#!/usr/bin/env bash
# Clone xbmc/xbmc fresh, apply this repo's patch series on top, then build.
#
# Usage:
#   cp scripts/kodi-env.sh.example scripts/kodi-env.sh   # once, fill in real values
#   source scripts/kodi-env.sh
#   ./install.sh [target-dir]
#
# target-dir defaults to ./xbmc next to this script. Re-running with an
# existing target-dir reuses that checkout instead of re-cloning (patches
# are applied via `git am`, so re-running against an already-patched
# checkout will fail loudly on the second `git am` -- that's deliberate,
# not a bug: it means you already have a patched tree, go straight to
# build-kodi.sh instead, or remove target-dir to start clean).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBMC_DIR="${1:-$SELF_DIR/xbmc}"
XBMC_UPSTREAM="https://github.com/xbmc/xbmc.git"

if [ ! -d "$XBMC_DIR/.git" ]; then
  echo "==> Cloning $XBMC_UPSTREAM into $XBMC_DIR"
  git clone "$XBMC_UPSTREAM" "$XBMC_DIR"
else
  echo "==> Reusing existing checkout at $XBMC_DIR"
fi

echo "==> Applying patch series from $SELF_DIR/patches"
git -C "$XBMC_DIR" am "$SELF_DIR"/patches/*.patch

echo "==> Building"
SOURCE_REPO="$XBMC_DIR" "$SELF_DIR/build-kodi.sh"
