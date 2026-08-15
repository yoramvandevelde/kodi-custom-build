#!/usr/bin/env bash
# Full "clean clone -> APK" build pipeline for Kodi on tmpfs.
#
# Companion to restore-buildcache.sh / save-buildcache.sh: those two handle
# mounting the tmpfs and saving/restoring a checkpoint of it across reboots.
# THIS script drives the actual build once the ramdisk is mounted (either
# freshly empty, or restored from a checkpoint).
#
# Steps 1-4 (source clone, depends bootstrap/configure, native tools, target
# depends) are validated end-to-end as of this session. Steps 5-6 (kodi's own
# cmake configure + ninja build + apk packaging) follow docs/README.Android.md
# but have NOT been run end-to-end yet in this exact ramdisk layout -- expect
# to need small tweaks once we get there.
set -euo pipefail

# --- Target architecture ----------------------------------------------------
# arm64  -> arm64-v8a (aarch64-linux-android)   -- 64-bit devices
# armv7a -> armeabi-v7a (arm-linux-androideabi) -- 32-bit-only devices, e.g.
#           anything whose `adb shell getprop ro.product.cpu.abilist` doesn't
#           list arm64-v8a
# Override with: ARCH=armv7a ./build-kodi.sh
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64)  HOST="aarch64-linux-android" ;;
  armv7a) HOST="arm-linux-androideabi" ;;
  *)
    echo "Unknown ARCH '$ARCH' (expected arm64 or armv7a)" >&2
    exit 1
    ;;
esac
NDK_API=24   # same default for every arch, see tools/depends/configure.ac

# --- MySQL library config (baked into advancedsettings.xml) ----------------
# This build's only purpose is delivering this config, so an unset value is a
# hard failure -- checked here too (not just by CMake later) so a missing var
# doesn't burn ~35-40 min of depends build before finding out.
# Pass on invocation, e.g.: KODI_DB_HOST=... KODI_DB_PORT=... KODI_DB_USER=... \
#   KODI_DB_PASS=... ./build-kodi.sh
for var in KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS; do
  if [ -z "${!var:-}" ]; then
    echo "$var is not set. This build exists solely to bake in the MySQL" >&2
    echo "library config; pass KODI_DB_HOST, KODI_DB_PORT, KODI_DB_USER and" >&2
    echo "KODI_DB_PASS as env vars on invocation, same as ARCH." >&2
    exit 1
  fi
done

# --- Seed sources.xml / mediasources.xml (webdav source) -------------------
# Same fail-fast reasoning as the MySQL vars above.
for var in KODI_WEBDAV_SOURCE_URL; do
  if [ -z "${!var:-}" ]; then
    echo "$var is not set. Pass it as an env var on invocation, same as" >&2
    echo "KODI_DB_HOST and ARCH." >&2
    exit 1
  fi
done

RAMDIR="/mnt/buildram"
SRC="$RAMDIR/src"                              # kodi source tree lives on ramdisk too,
                                                # so every read during compilation hits RAM
DEPENDS_PREFIX="$RAMDIR/xbmc-depends"
# Release build: both the depends (curl/ffmpeg/etc, --disable-debug below)
# and Kodi itself (DEBUG_BUILD=no below) build as Release now, not Debug.
# Own build dir per arch: CMake does not pick up a changed CMAKE_TOOLCHAIN_FILE
# on an already-configured build dir, so reusing another arch's (or debug's)
# kodi-build here would silently keep linking that other toolchain/depends.
# The old debug tree (kodi-build, xbmc-depends/*-debug) is left untouched on disk.
BUILD_DIR="$RAMDIR/kodi-build-release-$ARCH"
DEPENDS_DIR_NAME="$HOST-$NDK_API-release"   # matches configure.ac's
                                             # $use_host-$use_ndk_api-$build_type
CCACHE_DIR="$RAMDIR/ccache"                    # persistent compiler cache, also on ramdisk

# These two stay on real disk on purpose: read-only/static, get OS page-cached
# after the first read anyway, so ramdisk-ing them would only cost budget.
# Default under $HOME so no sudo/chown is needed on a clean machine (see
# PREREQUISITES.md's note on why /opt is best avoided here); override either
# if you installed the SDK/NDK elsewhere.
NDK_SDK="${NDK_SDK:-$HOME/android-tools/android-sdk-linux}"
TARBALLS="${TARBALLS:-$HOME/android-tools/xbmc-tarballs}"

SOURCE_REPO="${SOURCE_REPO:-/home/yoram/kodi}" # local repo we clone from -- no network needed.
                                                # Overridable so install.sh can point this at a
                                                # fresh, patched xbmc/xbmc checkout instead of this
                                                # machine's personal scratch clone.
if [ ! -d "$SOURCE_REPO/.git" ]; then
  echo "SOURCE_REPO ($SOURCE_REPO) is not a git checkout." >&2
  echo "Either run this via install.sh (which points SOURCE_REPO at a fresh," >&2
  echo "patched xbmc/xbmc clone automatically), or, for the fast local" >&2
  echo "edit-build-flash loop, put a working checkout at $SOURCE_REPO yourself" >&2
  echo "(or override with SOURCE_REPO=/path/to/checkout ./build-kodi.sh)." >&2
  exit 1
fi
JOBS=$(( $(nproc) - 1 ))                       # leave one core free for the rest of the system

# No system cmake is installed on purpose -- tools/depends/native builds its
# own and the depends Makefiles already call it via this full path. Step 7
# below needs the same binary explicitly since it invokes cmake directly
# rather than through a Makefile variable.
CMAKE_BIN="$DEPENDS_PREFIX/x86_64-linux-gnu-native/bin/cmake"

# --- Own config: features stripped for a single-purpose Google TV Streamer box ---
# See ~/kodi-build-options.md for the full option inventory and reasoning.
#
# APP_PACKAGE: gives this build its own applicationId (org.xbmc.kodi is the
# official one). Without this, `adb install` fails with
# INSTALL_FAILED_UPDATE_INCOMPATIBLE against an existing official Kodi
# install, since that's signed with a key we don't have and this build uses
# the debug keystore below. With a different id, it installs as a separate
# app alongside the official one instead of trying to replace it.
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

# Binary addons to skip. "all" builds everything under addons/, "-<id>" excludes
# by exact id or regex (see cmake/addons/README.md). Keeping: skin.estuary,
# video scrapers (metadata.local / .themoviedb.org.python / tvshows.themoviedb.org.python),
# repository.xbmc.org, resource.* (language/images/uisounds), the two builtin
# screensavers, and script.module.{pil,pycryptodome} (other addons depend on them).
ADDONS_TO_BUILD="all \
  -audioencoder.kodi.builtin.aac \
  -audioencoder.kodi.builtin.wma \
  -game.controller.default \
  -game.controller.keyboard \
  -game.controller.mouse \
  -game.controller.snes \
  -metadata.album.universal \
  -metadata.artists.universal \
  -metadata.common.allmusic.com \
  -metadata.common.fanart.tv \
  -metadata.common.musicbrainz.org \
  -metadata.common.theaudiodb.com \
  -metadata.generic.albums \
  -metadata.generic.artists \
  -metadata.demo.movies \
  -metadata.demo.tv \
  -service.xbmc.versioncheck \
  -webinterface.default"

export CCACHE_DIR

# Put the native-built cmake/ninja on PATH. The top-level build works either
# way (tools/depends' Makefiles call cmake/ninja by full path), but any
# NESTED cmake reconfigure -- e.g. CMake's ExternalProject_Add-based bundled
# deps (nlohmann_json, utfcpp, brotli, fmt, libandroidjni, crossguid,
# libnfs, mariadb, tinyxml2, pcre2, libdvdcss -- see cmake/scripts/common/
# ModuleHelpers.cmake) -- spawns its OWN cmake configure that only inherits
# the generator NAME ("Ninja"), not CMAKE_MAKE_PROGRAM, and re-resolves ninja
# via PATH. That reconfigure only triggers when ninja decides build.ninja
# itself is stale, so without this it bites intermittently and
# unpredictably depending on which dependency's reconfigure lands at that
# moment, not a bug in the dependency itself. Setting PATH here makes the
# build's success stop depending on whatever the invoking shell happens to
# have set.
export PATH="$DEPENDS_PREFIX/x86_64-linux-gnu-native/bin:$PATH"

# Release APK signing: build.gradle.in's signingConfigs.release block is used
# for every buildType (debug included), read from these four env vars. Reuse
# the debug.keystore (self-signed, personal sideload use -- see 3.3 in
# docs/README.Android.md for how it was generated).
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
# this needs to pick up uncommitted edits too (fast local edit-build-flash
# loop, not "commit first to test"). A fresh `git clone` would also stamp
# every file's mtime to "now", making ninja think the whole tree changed and
# rebuild far more than necessary -- rsync only touches files that actually
# differ, so an unrelated file's mtime (and ninja's incremental build) is
# undisturbed.
#
# The file list comes from `git ls-files` (tracked + untracked-but-not-
# ignored), NOT a plain directory mirror: tools/depends/target/* holds each
# dependency's extracted/built source tree, and only a handful of those
# (ffmpeg, dav1d, the libdvd* ones) are actually listed in .gitignore -- the
# rest (openssl, python3, sqlite3, ...) aren't, so a blanket `rsync --delete`
# would silently nuke ~35-40 min of already-built depends state on every run.
# Deliberately no --delete either, for the same reason: this only ever adds/
# updates files git considers part of the tree, never removes anything else
# already sitting in $SRC. Trade-off: a file *removed* in $SOURCE_REPO stays
# stale in $SRC until it's wiped and re-synced by hand -- acceptable for a
# fast local loop where that's rare, but worth remembering if something
# stubbornly won't go away.
echo "==> Syncing kodi source into $SRC"
mkdir -p "$SRC"
git -C "$SOURCE_REPO" ls-files -z --cached --others --exclude-standard \
  | rsync -a --files-from=- --from0 "$SOURCE_REPO/" "$SRC/"

cd "$SRC/tools/depends"

# --- 2. Bootstrap + configure the depends system --------------------------
# Only reconfigure when needed. Re-running ./configure rewrites
# Makefile.include, which bumps its mtime -- every native/target package's
# .configured-* marker depends on that file, so a stray reconfigure silently
# invalidates all of them and triggers a full rebuild of everything
# downstream (native tools rebuild is small/fast; target depends is not,
# which is why we only force this when the debug flag or the arch actually
# changed -- $SRC/tools/depends is shared across ARCH values, since it's one
# source checkout, so switching ARCH here on a checkpoint left at the other
# arch's HOST must be caught, or target depends would silently build for the
# wrong architecture).
if [ ! -f Makefile.include ] || ! grep -q '^DEBUG_BUILD=no$' Makefile.include \
   || ! grep -q "^HOST=$HOST\$" Makefile.include; then
  [ -f Makefile.include ] || { echo "==> Bootstrapping tools/depends"; ./bootstrap; }
  echo "==> Configuring tools/depends (release, $ARCH: --disable-debug)"
  ./configure \
    --with-tarballs="$TARBALLS" \
    --host="$HOST" \
    --with-ndk-api="$NDK_API" \
    --with-sdk-path="$NDK_SDK" \
    --prefix="$DEPENDS_PREFIX" \
    --disable-debug
fi

# --- 3. Native build tools -------------------------------------------------
# cmake, ninja, python3, meson, bison, gettext, pkg-config, etc: the tools
# needed to build everything else. Small/fast compared to step 4.
echo "==> Building native tools"
make -C native -j"$JOBS"

# --- 4. Target dependencies -------------------------------------------------
# curl, taglib, dav1d, gnutls, sqlite3, ... cross-compiled for $HOST.
# This is the expensive step (the one the ramdisk checkpointing exists to
# let you skip on subsequent runs) -- and per-arch, since $HOST changed.
#
# EXCLUDED_DEPENDS below drops samba/samba-gplv3 (SMB, matches ENABLE_SMBCLIENT=OFF)
# and libplist/libshairplay (AirTunes/plist, matches ENABLE_AIRTUNES=OFF and
# ENABLE_PLIST=OFF) from the build. This is a plain `=` assignment in
# target/Makefile, so a command-line override wins -- no need to patch the
# (upstream, tracked) Makefile itself. Keeps the android-default exclusions
# (libusb/libcdio/libcdio-gplv3) too, since a command-line override replaces
# the whole value rather than appending to it.
echo "==> Building target depends"
make -C target -j"$JOBS" \
  EXCLUDED_DEPENDS="libusb libcdio libcdio-gplv3 samba samba-gplv3 libplist libshairplay"

# --- 5. Binary addons -------------------------------------------------------
# DISABLED for now. tools/depends/target/binary-addons pulls from the large
# community addon catalog (ADDONS_DEFINITION_DIR defaults to cmake/addons/addons,
# bootstrapped separately), NOT the ~50 curated addons already sitting in this
# repo's own addons/ dir (skin.estuary, metadata.*, etc). Excluding by those
# names against the wrong catalog fails (silently -- exit 0 despite an internal
# cmake configure error). Those in-repo addons appear to be picked up by the
# main kodi build itself; still need to find the actual trim mechanism for them
# before re-enabling this. See ~/kodi-build-options.md.
# cd "$SRC"
# make -j"$JOBS" -C tools/depends/target/binary-addons ADDONS="$ADDONS_TO_BUILD"

# --- 6. Configure the Kodi CMake build itself ------------------------------
# GEN=Ninja switches the generator from the default "Unix Makefiles" to
# Ninja, which schedules the parallel build graph better -- fewer idle cores
# waiting on the critical path. DEBUG_BUILD=no -> Configuration=Release ->
# -DCMAKE_BUILD_TYPE=Release (see tools/depends/target/cmakebuildsys/Makefile).
# cd back to $SRC first: steps 2-4 ran from $SRC/tools/depends (cd on line
# above), and this target's path is relative to $SRC, not to that subdir --
# pre-existing bug, never triggered before since steps 5-6 hadn't run yet.
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
