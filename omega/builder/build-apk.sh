#!/usr/bin/env bash
# Clean clone to signed APK, for the omega target, inside a container.
#
# Expects, as environment:
#   KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS KODI_WEBDAV_SOURCE_URL
#   ARCH      arm64 (default) or armv7a
#   REPO_REF  branch or tag of kodi-custom-build to build (default main)
#   OUT_DIR   where the finished APK is copied (default /out)
#
# The KODI_* values are baked into advancedsettings.xml and sources.xml, so
# they decide which library the resulting APK talks to. Building the household
# streamer's APK against the play library would move the TV onto the test
# database, and the first film someone tried to play would be how you found
# out.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/yoramvandevelde/kodi-custom-build.git}"
REPO_REF="${REPO_REF:-main}"
OUT_DIR="${OUT_DIR:-/out}"
ARCH="${ARCH:-arm64}"
WORK="${WORK:-/mnt/buildram}"

for var in KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS KODI_WEBDAV_SOURCE_URL; do
  if [ -z "${!var:-}" ]; then
    echo "$var is not set. CMake fails at configure time on an empty value," >&2
    echo "but check it here rather than 40 minutes into a build." >&2
    exit 1
  fi
done

echo "==> Source: $REPO_URL @ $REPO_REF"
mkdir -p "$WORK"
cd "$WORK"
rm -rf kodi-custom-build
git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" kodi-custom-build
cd kodi-custom-build

# Written at run time rather than mounted, so no credential is ever on disk
# outside this container and none of it can end up in an image layer.
umask 077
cat > scripts/kodi-env.sh <<ENV
export ARCH=$ARCH
export KODI_DB_HOST=$KODI_DB_HOST
export KODI_DB_PORT=$KODI_DB_PORT
export KODI_DB_USER=$KODI_DB_USER
export KODI_DB_PASS=$KODI_DB_PASS
export KODI_WEBDAV_SOURCE_URL=$KODI_WEBDAV_SOURCE_URL
ENV
umask 022
# shellcheck disable=SC1091
. scripts/kodi-env.sh

# install.sh clones Kodi at the pinned ref, applies the patch series, and ends
# by invoking omega/build-kodi.sh itself with SOURCE_REPO set. Calling the
# build script separately afterwards would build a second time, against the
# wrong tree.
echo "==> Clone, patch and build"
./install.sh omega "$WORK/xbmc-omega"

echo "==> Collecting the APK"
mkdir -p "$OUT_DIR"
apk=$(find "$WORK" -name '*.apk' -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$apk" ] || { echo "the build produced no apk" >&2; exit 1; }

dest="$OUT_DIR/kodi-omega-$ARCH-$(date +%Y%m%d-%H%M%S).apk"
cp -v "$apk" "$dest"
sha256sum "$dest"
