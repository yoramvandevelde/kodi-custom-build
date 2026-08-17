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
# target-dir defaults to ./xbmc-<target>. Re-running with an existing
# target-dir reuses that checkout instead of re-cloning (patches are applied
# via `git am`, so re-running against an already-patched checkout will fail
# loudly on the second `git am` -- that's deliberate, not a bug: it means you
# already have a patched tree, go straight to <target>/build-kodi.sh instead,
# or remove target-dir to start clean).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBMC_UPSTREAM="https://github.com/xbmc/xbmc.git"

# --- Target selection ------------------------------------------------------
# Both targets are pinned to an explicit ref, never to a moving branch. That
# matters more than it looks: Kodi's library schema version is compiled in
# (CVideoDatabase::GetSchemaVersion) and the MySQL database is literally named
# after it (MyVideos131, MyVideos148, ...). A Kodi that finds no database at
# its own schema version COPIES the nearest older one and migrates the copy,
# one-way. So an unpinned build that drifts to a newer commit can silently
# fork the shared library into a new database that the devices still running
# the old build can no longer see. Pinning is what keeps every instance
# pointed at the same schema on purpose rather than by luck.
TARGET="${1:-}"
case "$TARGET" in
  omega)
    # 21.3-Omega: the newest actual RELEASE. Schema: MyVideos131 / MyMusic83.
    XBMC_REF="21.3-Omega"
    ;;
  master)
    # Untagged xbmc/xbmc master, pinned to the commit this repo was last built
    # and validated against. Schema: MyVideos148 / MyMusic84 -- a schema that
    # exists in no released Kodi, which is exactly why nothing off-the-shelf
    # (distro package, AppImage, official APK) can share a library with it.
    # Bump deliberately, never casually, and rebuild every device together.
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

# Separate checkout per target by default. They sit at different refs with
# different patches applied, so sharing one directory would mean re-cloning
# (or hard-resetting) on every switch.
if [ ! -d "$XBMC_DIR/.git" ]; then
  echo "==> Cloning $XBMC_UPSTREAM into $XBMC_DIR"
  git clone "$XBMC_UPSTREAM" "$XBMC_DIR"
else
  echo "==> Reusing existing checkout at $XBMC_DIR"
fi

echo "==> Checking out pinned ref $XBMC_REF"
# Detached on purpose: this is a build input, not a branch to develop on. A
# named branch here would invite `git pull` and quietly undo the pin.
git -C "$XBMC_DIR" fetch --tags origin
git -C "$XBMC_DIR" checkout --detach "$XBMC_REF"

# git am creates commits, so it needs a committer identity, and a freshly
# installed machine has none configured -- it fails with "Committer identity
# unknown" before applying anything. Set one, but ONLY in this clone (never
# --global: this is a disposable build artifact, not a reason to touch the
# machine's git config), and only when nothing is configured anywhere, so a
# machine that already has a real identity keeps using it.
#
# This identity is the committer, not the author: `git am` preserves each
# patch's original From: line, so authorship survives regardless of what's
# set here. Override with GIT_COMMITTER_NAME / GIT_COMMITTER_EMAIL if you
# want these commits attributed to you instead.
if ! git -C "$XBMC_DIR" config user.email >/dev/null 2>&1; then
  echo "==> No git identity configured; setting a local one for this clone"
  git -C "$XBMC_DIR" config user.name "${GIT_COMMITTER_NAME:-kodi-custom-build}"
  git -C "$XBMC_DIR" config user.email "${GIT_COMMITTER_EMAIL:-build@localhost}"
fi

echo "==> Applying patch series from $TARGET_DIR/patches"
git -C "$XBMC_DIR" am "$TARGET_DIR"/patches/*.patch

echo "==> Building ($TARGET)"
SOURCE_REPO="$XBMC_DIR" "$TARGET_DIR/build-kodi.sh"
