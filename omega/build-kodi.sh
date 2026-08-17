#!/usr/bin/env bash
# Full "clean clone -> APK" build pipeline for Kodi 21.3-Omega on tmpfs.
#
# Sibling of master/build-kodi.sh. Same shape, same tmpfs/ccache/rsync
# approach, but pinned to the 21.3-Omega RELEASE instead of tracking
# xbmc/xbmc master. See ../README.md for why both exist.
#
# The two targets are NOT interchangeable in their toolchain requirements --
# that is the entire reason this is a separate script rather than a flag on
# the other one:
#
#            master (untagged)      21.3-Omega (this script)
#   NDK      r28c, auto-detected    r21e, --with-ndk-path REQUIRED
#   ndk-api  24                     21
#   SDK      platform 37            platform 34 (hardcoded TARGET_SDK)
#   tools    build-tools 37.0.0     build-tools 33.0.1
#
# UNVALIDATED end-to-end as of writing. The patch series is confirmed to
# APPLY to 21.3-Omega (one conflict, resolved: upstream renamed the Shairplay
# CMake target from Shairplay::Shairplay to ${APP_NAME_LC}::Shairplay after
# 21.3), but this exact toolchain combination has not been built yet. Expect
# to fix a few things on the first real run.
set -euo pipefail

# --- Target architecture ----------------------------------------------------
# Identical semantics to master/build-kodi.sh on purpose: scripts/kodi-env.sh
# is shared between both targets, so ARCH has to mean the same thing here.
# arm64  -> arm64-v8a (aarch64-linux-android)   -- 64-bit devices
# armv7a -> armeabi-v7a (arm-linux-androideabi) -- 32-bit-only devices, e.g.
#           anything whose `adb shell getprop ro.product.cpu.abilist` doesn't
#           list arm64-v8a
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64)  HOST="aarch64-linux-android" ;;
  armv7a) HOST="arm-linux-androideabi" ;;
  *)
    echo "Unknown ARCH '$ARCH' (expected arm64 or armv7a)" >&2
    exit 1
    ;;
esac

# 21.3-Omega's tools/depends/configure.ac defaults use_ndk_api to 21, where
# master defaults to 24. Matching upstream's own default here rather than
# carrying master's value over: 21 is what Kodi's CI actually built and
# released 21.3 with, and TARGET_MINSDK in cmake/platform/android/android.cmake
# is 21 to match. It also feeds the depends dir name below, so it must agree
# with whatever ./configure ends up using or step 4 silently builds into the
# wrong prefix.
NDK_API=21

# --- MySQL library config (baked into advancedsettings.xml) ----------------
# This build's only purpose is delivering this config, so an unset value is a
# hard failure -- checked here too (not just by CMake later) so a missing var
# doesn't burn ~35-40 min of depends build before finding out.
for var in KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS; do
  if [ -z "${!var:-}" ]; then
    echo "$var is not set. This build exists solely to bake in the MySQL" >&2
    echo "library config; pass KODI_DB_HOST, KODI_DB_PORT, KODI_DB_USER and" >&2
    echo "KODI_DB_PASS as env vars on invocation, same as ARCH." >&2
    echo "(source scripts/kodi-env.sh -- shared with the master target.)" >&2
    exit 1
  fi
done

# --- Seed sources.xml / mediasources.xml (webdav source) -------------------
for var in KODI_WEBDAV_SOURCE_URL; do
  if [ -z "${!var:-}" ]; then
    echo "$var is not set. Pass it as an env var on invocation, same as" >&2
    echo "KODI_DB_HOST and ARCH." >&2
    exit 1
  fi
done

RAMDIR="/mnt/buildram"
SRC="$RAMDIR/src"
DEPENDS_PREFIX="$RAMDIR/xbmc-depends"
BUILD_DIR="$RAMDIR/kodi-build-release-$ARCH"
DEPENDS_DIR_NAME="$HOST-$NDK_API-release"   # matches configure.ac's
                                             # $use_host-$use_ndk_api-$build_type
CCACHE_DIR="$RAMDIR/ccache"

# NOTE ON RAMDISK SHARING: master/ and omega/ deliberately use the SAME
# ramdisk paths. Only one target is ever resident at a time; switching is
# `scripts/save-buildcache.sh <current>` then
# `scripts/restore-buildcache.sh <other>`, which swaps the whole tree via a
# per-target backup dir. Two complete depends+source+build trees do not
# comfortably share a 35G tmpfs, and interleaving them under subdirs would
# also mean two native-tools prefixes (each with their own cmake/ninja/python)
# for no benefit, since you only ever build one at a time anyway.
# The important consequence: NEVER run this straight after a master build
# without restoring omega's cache first, or step 2 will reconfigure a tree
# full of master's depends and rebuild far more than you expect.

# --- Android SDK/NDK: dedicated root, NOT shared with the master build -----
# Own SDK root on purpose. 21.3 needs platform 34 + build-tools 33.0.1 + NDK
# r21e, master needs platform 37 + build-tools 37.0.0 + NDK r28c, and
# tools/depends/configure.ac picks build-tools by
#   `ls $use_sdk_path/build-tools | sort -V | tail -n 1`
# i.e. ALWAYS the newest one installed, with no way to ask for an older one.
# Sharing one root would therefore silently hand this build master's
# build-tools 37.0.0 no matter what's documented. Two roots removes the
# ambiguity entirely instead of trying to work around that sort order.
NDK_SDK="${NDK_SDK:-$HOME/android-tools-omega/android-sdk-linux}"

# Unlike master, 21.3's configure has NO NDK auto-detection under the SDK
# root: tools/depends/configure.ac hard-errors with "NDK path is required for
# android" if --with-ndk-path is absent. So it's an explicit value here, and
# checked below rather than discovered halfway through ./configure.
NDK_VERSION="${NDK_VERSION:-21.4.7075529}"   # r21e, what Kodi's own
                                              # docs/README.Android.md for this
                                              # release recommends and what
                                              # their CI built 21.3 with
NDK_PATH="${NDK_PATH:-$NDK_SDK/ndk/$NDK_VERSION}"

# Shared with the master target: this is purely a download cache of upstream
# dependency tarballs, keyed by filename+version, so two Kodi versions asking
# for different dep versions just means both sets live here. Nothing to
# collide.
TARBALLS="${TARBALLS:-$HOME/android-tools/xbmc-tarballs}"

# Fail fast on toolchain layout, before anything expensive runs. Each of
# these otherwise surfaces as a confusing error deep inside ./configure or,
# worse, as a build that silently used the wrong component.
if [ ! -d "$NDK_SDK" ]; then
  echo "NDK_SDK ($NDK_SDK) does not exist." >&2
  echo "21.3-Omega needs its OWN sdk root, separate from the master build's" >&2
  echo "-- see ../PREREQUISITES.md. Override with NDK_SDK=/path if yours" >&2
  echo "lives elsewhere." >&2
  exit 1
fi
if [ ! -f "$NDK_PATH/source.properties" ] && [ ! -f "$NDK_PATH/RELEASE.TXT" ]; then
  echo "NDK_PATH ($NDK_PATH) is not an NDK directory." >&2
  echo "21.3 requires --with-ndk-path explicitly (no auto-detection), and" >&2
  echo "recommends r21e ($NDK_VERSION). Install it into that sdk root, or" >&2
  echo "override with NDK_VERSION=... / NDK_PATH=..." >&2
  exit 1
fi
if [ ! -d "$NDK_SDK/platforms/android-34" ]; then
  echo "Missing $NDK_SDK/platforms/android-34." >&2
  echo "cmake/platform/android/android.cmake in 21.3 hardcodes TARGET_SDK 34," >&2
  echo "which becomes gradle's compileSdk/targetSdk -- a newer platform does" >&2
  echo "not substitute for it. Install 'platforms;android-34'." >&2
  exit 1
fi
# Not fatal, but worth shouting about: configure takes the highest-versioned
# build-tools it finds, so an extra newer one here quietly wins over 33.0.1.
if [ -d "$NDK_SDK/build-tools" ]; then
  bt_count=$(ls -1 "$NDK_SDK/build-tools" 2>/dev/null | wc -l)
  bt_used=$(ls -1 "$NDK_SDK/build-tools" 2>/dev/null | sort -V | tail -n 1)
  if [ "$bt_count" -gt 1 ]; then
    echo "WARNING: $bt_count build-tools versions in $NDK_SDK/build-tools." >&2
    echo "         configure will use the newest ($bt_used) regardless of" >&2
    echo "         what this build was tested with (33.0.1)." >&2
  fi
fi

SOURCE_REPO="${SOURCE_REPO:-/home/yoram/kodi}" # local repo we clone from -- no network needed.
                                                # Overridable so install.sh can point this at a
                                                # fresh, patched 21.3-Omega checkout instead of
                                                # this machine's personal scratch clone.
if [ ! -d "$SOURCE_REPO/.git" ]; then
  echo "SOURCE_REPO ($SOURCE_REPO) is not a git checkout." >&2
  echo "Either run this via ../install.sh omega (which points SOURCE_REPO at" >&2
  echo "a fresh, patched 21.3-Omega clone automatically), or, for the fast" >&2
  echo "local edit-build-flash loop, put a working checkout at $SOURCE_REPO" >&2
  echo "yourself (or override with SOURCE_REPO=/path ./build-kodi.sh)." >&2
  exit 1
fi
JOBS=$(( $(nproc) - 1 ))                       # leave one core free for the rest of the system

CMAKE_BIN="$DEPENDS_PREFIX/x86_64-linux-gnu-native/bin/cmake"

# --- Own config: features stripped for a single-purpose Google TV Streamer box ---
# Carried over verbatim from master/build-kodi.sh, since the device and its
# purpose are identical. See that script for the per-option reasoning.
#
# CAVEAT worth checking on the first configure of this target: CMake silently
# ignores -D flags it doesn't recognise, so an option upstream renamed between
# 21.3 and master would look like it applied while changing nothing. Kodi
# prints an enabled/disabled dependency summary at the end of the configure
# step (step 6) -- eyeball it once against this list and fix any that didn't
# take, rather than assuming.
CMAKE_EXTRA_ARGUMENTS="\
  -DAPP_PACKAGE=org.xbmc.kodi.dev \
  -DENABLE_AIRTUNES=OFF \
  -DENABLE_ALSA=OFF \
  -DENABLE_AVAHI=OFF \
  -DENABLE_BLUETOOTH=OFF \
  -DENABLE_BLURAY=OFF \
  -DENABLE_ISO9660PP=OFF \
  -DENABLE_LIBUSB=OFF \
  -DENABLE_LIRCCLIENT=OFF \
  -DENABLE_MARIADBCLIENT=ON \
  -DENABLE_MICROHTTPD=OFF \
  -DENABLE_NFS=ON \
  -DENABLE_OPTICAL=OFF \
  -DENABLE_PLIST=OFF \
  -DENABLE_SMBCLIENT=OFF \
  -DENABLE_SNDIO=OFF \
  -DENABLE_UDFREAD=OFF \
  -DENABLE_UPNP=OFF \
  -DENABLE_X11=OFF"

export CCACHE_DIR

# Put the native-built cmake/ninja on PATH -- see master/build-kodi.sh for the
# full explanation (nested ExternalProject_Add reconfigures re-resolve ninja
# via PATH and only inherit the generator NAME, so without this it bites
# intermittently).
export PATH="$DEPENDS_PREFIX/x86_64-linux-gnu-native/bin:$PATH"

# Release APK signing: build.gradle.in's signingConfigs.release block is used
# for every buildType (debug included), read from these four env vars. Reuse
# the debug.keystore (self-signed, personal sideload use).
export KODI_ANDROID_KEY_ALIAS="androiddebugkey"
export KODI_ANDROID_KEY_PASSWORD="android"
export KODI_ANDROID_STORE_FILE="$HOME/.android/debug.keystore"
export KODI_ANDROID_STORE_PASSWORD="android"

mkdir -p "$RAMDIR" \
  "$DEPENDS_PREFIX/x86_64-linux-gnu-native" \
  "$DEPENDS_PREFIX/$DEPENDS_DIR_NAME" \
  "$BUILD_DIR" \
  "$CCACHE_DIR"

# --- 1. Source: sync the working tree onto ramdisk, every run --------------
# Deliberately rsync (via an explicit git-driven file list), not `git clone`:
# picks up uncommitted edits, and doesn't stamp every file's mtime to "now"
# the way a fresh clone would (which would make ninja rebuild the world).
# File list from `git ls-files` rather than a directory mirror, and no
# --delete, because tools/depends/target/* holds built dependency state that
# isn't all gitignored -- see master/build-kodi.sh for the full reasoning.
echo "==> Syncing kodi source into $SRC"
mkdir -p "$SRC"
git -C "$SOURCE_REPO" ls-files -z --cached --others --exclude-standard \
  | rsync -a --files-from=- --from0 "$SOURCE_REPO/" "$SRC/"

cd "$SRC/tools/depends"

# --- 2. Bootstrap + configure the depends system --------------------------
# Only reconfigure when needed: re-running ./configure rewrites
# Makefile.include, bumping its mtime, which invalidates every native/target
# package's .configured-* marker and triggers a full rebuild downstream.
# Checked against DEBUG_BUILD and HOST, since $SRC/tools/depends is shared
# across ARCH values within one checkout.
if [ ! -f Makefile.include ] || ! grep -q '^DEBUG_BUILD=no$' Makefile.include \
   || ! grep -q "^HOST=$HOST\$" Makefile.include; then
  [ -f Makefile.include ] || { echo "==> Bootstrapping tools/depends"; ./bootstrap; }
  echo "==> Configuring tools/depends (release, $ARCH, ndk-api $NDK_API)"
  ./configure \
    --with-tarballs="$TARBALLS" \
    --host="$HOST" \
    --with-ndk-api="$NDK_API" \
    --with-sdk-path="$NDK_SDK" \
    --with-ndk-path="$NDK_PATH" \
    --prefix="$DEPENDS_PREFIX" \
    --disable-debug
fi

# --- 3. Native build tools -------------------------------------------------
# cmake, ninja, python3, meson, bison, gettext, pkg-config, etc. Small/fast
# compared to step 4.
echo "==> Building native tools"
make -C native -j"$JOBS"

# --- 4. Target dependencies -------------------------------------------------
# curl, taglib, dav1d, gnutls, sqlite3, ... cross-compiled for $HOST. This is
# the expensive step the ramdisk checkpointing exists to let you skip.
#
# EXCLUDED_DEPENDS drops samba/samba-gplv3 (matches ENABLE_SMBCLIENT=OFF) and
# libplist/libshairplay (matches ENABLE_AIRTUNES=OFF, ENABLE_PLIST=OFF). Plain
# `=` assignment in target/Makefile, so a command-line override wins without
# patching the tracked Makefile. Keeps the android-default exclusions
# (libusb/libcdio/libcdio-gplv3) too, since an override replaces the whole
# value rather than appending.
echo "==> Building target depends"
make -C target -j"$JOBS" \
  EXCLUDED_DEPENDS="libusb libcdio libcdio-gplv3 samba samba-gplv3 libplist libshairplay"

# --- 5. Binary addons -------------------------------------------------------
# DISABLED, same as the master target and for the same unresolved reason:
# tools/depends/target/binary-addons pulls from the external community catalog
# (ADDONS_DEFINITION_DIR), not the ~50 addons curated in-repo under addons/,
# so excluding by those names fails silently (exit 0 despite an internal cmake
# error). The in-repo addons appear to be picked up by the main build itself.
# Still need to find the actual trim mechanism before re-enabling.
# make -j"$JOBS" -C tools/depends/target/binary-addons ADDONS="..."

# --- 6. Configure the Kodi CMake build itself ------------------------------
# GEN=Ninja over the default "Unix Makefiles" for better parallel scheduling.
# DEBUG_BUILD=no -> Configuration=Release -> -DCMAKE_BUILD_TYPE=Release (see
# tools/depends/target/cmakebuildsys/Makefile). cd back to $SRC first: steps
# 2-4 ran from $SRC/tools/depends and this target's path is relative to $SRC.
cd "$SRC"
echo "==> Configuring kodi-build (Ninja, Release)"
GEN=Ninja BUILD_DIR="$BUILD_DIR" DEBUG_BUILD=no \
  CMAKE_EXTRA_ARGUMENTS="$CMAKE_EXTRA_ARGUMENTS" \
  make -C tools/depends/target/cmakebuildsys

# --- 7. Build Kodi + package the APK ---------------------------------------
echo "==> Building kodi"
"$CMAKE_BIN" --build "$BUILD_DIR" -- -j"$JOBS"

echo "==> Packaging apk"
"$CMAKE_BIN" --build "$BUILD_DIR" --target apk

echo "==> Done. Look for the apk under $SRC or $BUILD_DIR/tools/android/packaging/xbmc/build/outputs/apk (release/*)"
