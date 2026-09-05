#!/usr/bin/env bash
# Clone xbmc/xbmc fresh at a pinned ref, apply that target's patch series on
# top, then build.
#
# Usage:
#   cp scripts/kodi-env.sh.example scripts/kodi-env.sh   # once, fill in real values
#   source scripts/kodi-env.sh
#   ./install.sh omega [target-dir]
#   ./install.sh master [target-dir]
#
# target-dir defaults to ./xbmc-<target>. An existing target-dir is reused, so
# a second run fails on `git am` against an already-patched tree. Remove
# target-dir to start clean, or run <target>/build-kodi.sh directly.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBMC_UPSTREAM="https://github.com/xbmc/xbmc.git"

# --- Target selection ------------------------------------------------------
# Pinned to an explicit ref, never a branch. The library schema version is
# compiled in (CVideoDatabase::GetSchemaVersion) and the MySQL database is named
# after it (MyVideos131). A Kodi that finds no database at its own version
# copies the nearest older one and migrates the copy, one way, so a build that
# drifts forks the shared library away from every device still on the old one.
TARGET="${1:-}"
case "$TARGET" in
  omega)
    # 21.3-Omega: the newest actual RELEASE. Schema: MyVideos131 / MyMusic83.
    XBMC_REF="21.3-Omega"
    ;;
  master)
    # Untagged xbmc/xbmc master, pinned to the last commit built and validated.
    # Schema MyVideos148 / MyMusic84 exists in no released Kodi, so nothing
    # off-the-shelf can share a library with it. Bumping means rebuilding every
    # device together.
    XBMC_REF="62ff01403b"
    ;;
  ""|-h|--help)
    echo "Usage: $0 {omega|master} [target-dir]" >&2
    echo >&2
    echo "  omega   21.3-Omega release        (library schema MyVideos131)" >&2
    echo "  master  pinned xbmc/xbmc master   (library schema MyVideos148)" >&2
    exit 1
    ;;
  *)
    echo "Unknown target '$TARGET' (expected 'omega' or 'master')." >&2
    exit 1
    ;;
esac

TARGET_DIR="$SELF_DIR/$TARGET"
if [ ! -d "$TARGET_DIR" ]; then
  echo "No such target directory: $TARGET_DIR" >&2
  exit 1
fi

XBMC_DIR="${2:-$SELF_DIR/xbmc-$TARGET}"

# Separate checkout per target: different refs, different patches.
if [ ! -d "$XBMC_DIR/.git" ]; then
  echo "==> Cloning $XBMC_UPSTREAM into $XBMC_DIR"
  git clone "$XBMC_UPSTREAM" "$XBMC_DIR"
else
  echo "==> Reusing existing checkout at $XBMC_DIR"
fi

echo "==> Checking out pinned ref $XBMC_REF"
# Detached on purpose: a named branch invites `git pull`, which undoes the pin.
git -C "$XBMC_DIR" fetch --tags origin
git -C "$XBMC_DIR" checkout --detach "$XBMC_REF"

# git am needs a committer identity and a fresh machine has none. Set locally,
# never --global, and only when nothing is configured. Committer only: `git am`
# keeps each patch's From: line.
if ! git -C "$XBMC_DIR" config user.email >/dev/null 2>&1; then
  echo "==> No git identity configured; setting a local one for this clone"
  git -C "$XBMC_DIR" config user.name "${GIT_COMMITTER_NAME:-kodi-custom-build}"
  git -C "$XBMC_DIR" config user.email "${GIT_COMMITTER_EMAIL:-build@localhost}"
fi

echo "==> Applying patch series from $TARGET_DIR/patches"
git -C "$XBMC_DIR" am "$TARGET_DIR"/patches/*.patch

echo "==> Building ($TARGET)"
SOURCE_REPO="$XBMC_DIR" "$TARGET_DIR/build-kodi.sh"
