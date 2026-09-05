#!/usr/bin/env bash
# Clean clone to signed APK, for the omega target, inside a container.
#
# Expects, as environment:
#   KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS KODI_WEBDAV_SOURCE_URL
#   ARCH      arm64 (default) or armv7a
#   REPO_REF  branch or tag of kodi-custom-build to build (default main)
#   OUT_DIR   where the finished APK is copied, if that directory exists
#
# And, to publish rather than leave it on a volume:
#   FORGEJO_URL    base URL of the Forgejo instance
#   FORGEJO_OWNER  the user or organisation the package belongs to
#   FORGEJO_TOKEN  a token with write:package
#   APK_PACKAGE    package name (default kodi-apk)
#
# The KODI_* values are baked into advancedsettings.xml and sources.xml, so they
# decide which library the resulting APK talks to. Get them wrong and the device
# silently ends up on the wrong database.
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

# Checked here too: there it costs a clone first.
KEYSTORE="${KODI_ANDROID_STORE_FILE:-$HOME/.android/debug.keystore}"
if [ ! -f "$KEYSTORE" ]; then
  echo "No keystore at $KEYSTORE." >&2
  echo "Mount one and point KODI_ANDROID_STORE_FILE at it. The image carries" >&2
  echo "none on purpose: a key generated per build cannot update its own" >&2
  echo "previous APK." >&2
  exit 1
fi

echo "==> Source: $REPO_URL @ $REPO_REF"
mkdir -p "$WORK"
cd "$WORK"
rm -rf kodi-custom-build
git clone --branch "$REPO_REF" --depth 1 "$REPO_URL" kodi-custom-build
cd kodi-custom-build

# Written at run time, not mounted: no credential lands in an image layer.
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

# install.sh ends by invoking omega/build-kodi.sh itself with SOURCE_REPO set,
# so do not call the build script again here.
echo "==> Clone, patch and build"
./install.sh omega "$WORK/xbmc-omega"

# Printed because the pod is gone by the time anyone looks, and "ran out of
# room" is the first thing worth ruling out on a failed build.
echo "==> Disk"
df -h "$WORK"
du -sh "$WORK"/* 2>/dev/null | sort -h | tail -5

echo "==> Collecting the APK"
apk=$(find "$WORK" -name '*.apk' -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$apk" ] || { echo "the build produced no apk" >&2; exit 1; }

version="$(date +%Y%m%d-%H%M%S)"
name="kodi-omega-$ARCH-$version.apk"

# The volume is optional now the APK can be published, but kept: a failed upload
# should not be the only copy.
if [ -d "$OUT_DIR" ]; then
  cp -v "$apk" "$OUT_DIR/$name"
  sha256sum "$OUT_DIR/$name"
fi

if [ -n "${FORGEJO_TOKEN:-}" ]; then
  : "${FORGEJO_URL:?FORGEJO_TOKEN is set but FORGEJO_URL is not}"
  : "${FORGEJO_OWNER:?FORGEJO_TOKEN is set but FORGEJO_OWNER is not}"
  package="${APK_PACKAGE:-kodi-apk}"
  url="$FORGEJO_URL/api/packages/$FORGEJO_OWNER/generic/$package/$version/$name"

  echo "==> Publishing to $url"
  # --fail-with-body to see what the server said. Retried because one dropped
  # connection would otherwise discard an hour of build.
  for attempt in 1 2 3; do
    if curl --fail-with-body -sS -X PUT \
         -H "Authorization: token $FORGEJO_TOKEN" \
         --upload-file "$apk" "$url"; then
      echo "==> Published $package $version"
      exit 0
    fi
    echo "   attempt $attempt failed" >&2
    sleep 5
  done

  echo "Upload failed three times." >&2
  [ -d "$OUT_DIR" ] && echo "The APK is still at $OUT_DIR/$name." >&2
  exit 1
fi

if [ ! -d "$OUT_DIR" ]; then
  echo "Nowhere to put the APK: no $OUT_DIR and no FORGEJO_TOKEN." >&2
  exit 1
fi
