#!/usr/bin/env bash
# Clean clone to APK for Kodi 21.3-Omega.
#
# A separate script from master/build-kodi.sh rather than a flag on it, because
# the toolchains do not overlap:
#
#            master (untagged)      21.3-Omega (this script)
#   NDK      r28c, auto-detected    r21e, --with-ndk-path REQUIRED
#   ndk-api  24                     21
#   SDK      platform 37            platform 34 (hardcoded TARGET_SDK)
#   tools    build-tools 37.0.0     build-tools 33.0.1
#
# Build host: Ubuntu 24.04 or similar vintage. tools/depends/native compiles
# 2023-era sources with the HOST compiler, and GCC 15 (C23 by default) breaks
# m4's gnulib and pkg-config's glib. Only native/ is exposed to the host;
# target/ sits behind the pinned NDK.
set -euo pipefail

# --- Target architecture ----------------------------------------------------
# Same meaning as in master/build-kodi.sh: scripts/kodi-env.sh is shared.
# arm64  -> arm64-v8a (aarch64-linux-android)
# armv7a -> armeabi-v7a (arm-linux-androideabi), for devices whose
#           `adb shell getprop ro.product.cpu.abilist` lacks arm64-v8a
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64)  HOST="aarch64-linux-android" ;;
  armv7a) HOST="arm-linux-androideabi" ;;
  *)
    echo "Unknown ARCH '$ARCH' (expected arm64 or armv7a)" >&2
    exit 1
    ;;
esac

# Upstream's own default for this release: tools/depends/configure.ac:92 and
# TARGET_MINSDK in cmake/platform/android/android.cmake:9. Also feeds
# DEPENDS_DIR_NAME below, so it must match what ./configure uses or step 4
# builds into the wrong prefix.
NDK_API=21

# --- MySQL library config (baked into advancedsettings.xml) ----------------
# Checked here as well as by CMake, so a missing value costs a second instead of
# 40 minutes of depends build.
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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAMDIR="/mnt/buildram"
SRC="$RAMDIR/src"
DEPENDS_PREFIX="$RAMDIR/xbmc-depends"
BUILD_DIR="$RAMDIR/kodi-build-release-$ARCH"
DEPENDS_DIR_NAME="$HOST-$NDK_API-release"   # matches configure.ac's
                                             # $use_host-$use_ndk_api-$build_type
CCACHE_DIR="$RAMDIR/ccache"

# master/ and omega/ share these paths, so only one target is resident at a
# time. Switching is scripts/save-buildcache.sh then scripts/restore-buildcache.sh.
# Running this straight after a master build without restoring first makes step 2
# reconfigure a tree full of master's depends.

# --- Android SDK/NDK: dedicated root, NOT shared with the master build -----
# tools/depends/configure.ac:589 picks build-tools with `sort -V | tail -n 1`,
# always the newest installed, with no way to ask for an older one. One shared
# root would hand this build master's build-tools 37.0.0.
NDK_SDK="${NDK_SDK:-$HOME/android-tools-omega/android-sdk-linux}"

# No NDK auto-detection in this release: tools/depends/configure.ac:567 errors
# with "NDK path is required for android" without --with-ndk-path.
NDK_VERSION="${NDK_VERSION:-21.4.7075529}"   # r21e, per this release's
                                              # docs/README.Android.md
NDK_PATH="${NDK_PATH:-$NDK_SDK/ndk/$NDK_VERSION}"

# Shared with master: a download cache keyed by filename+version, so both
# targets' dependency sets coexist here.
TARBALLS="${TARBALLS:-$HOME/android-tools/xbmc-tarballs}"

# Fail fast on toolchain layout. Each of these otherwise surfaces deep inside
# ./configure, or as a build that silently used the wrong component.
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
# configure.ac wants an sdkmanager inside the sdk root itself, at one of three
# fixed paths. Populating a root with another root's sdkmanager gets you the
# ndk/platforms/build-tools but leaves no cmdline-tools here.
if [ ! -f "$NDK_SDK/tools/bin/sdkmanager" ] \
   && [ ! -f "$NDK_SDK/cmdline-tools/bin/sdkmanager" ] \
   && [ ! -f "$NDK_SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "No sdkmanager found in $NDK_SDK." >&2
  echo "tools/depends/configure.ac requires one at tools/bin/sdkmanager," >&2
  echo "cmdline-tools/bin/sdkmanager or cmdline-tools/latest/bin/sdkmanager." >&2
  echo "Populating this root with another sdk root's sdkmanager does not put" >&2
  echo "one here; add it with:" >&2
  echo "  sdkmanager --sdk_root=\"$NDK_SDK\" \"cmdline-tools;latest\"" >&2
  exit 1
fi
if [ ! -d "$NDK_SDK/platforms/android-34" ]; then
  echo "Missing $NDK_SDK/platforms/android-34." >&2
  echo "cmake/platform/android/android.cmake in 21.3 hardcodes TARGET_SDK 34," >&2
  echo "which becomes gradle's compileSdk/targetSdk -- a newer platform does" >&2
  echo "not substitute for it. Install 'platforms;android-34'." >&2
  exit 1
fi
# Not fatal: configure takes the highest-versioned build-tools it finds, so an
# extra newer one wins over 33.0.1.
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

JOBS="${JOBS:-$(( $(nproc) - 1 ))}"
CMAKE_BIN="$DEPENDS_PREFIX/x86_64-linux-gnu-native/bin/cmake"

# --- Features stripped for a single-purpose Google TV Streamer box ---------
# Same list as master/build-kodi.sh; see that script for the per-option reasons.
#
# ENABLE_OPTICAL is ON here and OFF in master. Turning it off in 21.3 means
# backporting master's optical-optional refactor: this release guards the use of
# cdio but not the includes, so FileFactory.cpp, MusicDatabase.cpp and
# music/tags/CMakeLists.txt all break. Not worth a few hundred kB.
#
# CMake ignores -D flags it does not recognise, so an option renamed between
# 21.3 and master looks applied while changing nothing. Check this list against
# the dependency summary Kodi prints at the end of step 6.
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
  -DENABLE_OPTICAL=ON \
  -DENABLE_PLIST=OFF \
  -DENABLE_SMBCLIENT=OFF \
  -DENABLE_SNDIO=OFF \
  -DENABLE_UDFREAD=OFF \
  -DENABLE_UPNP=OFF \
  -DENABLE_X11=OFF"

export CCACHE_DIR

# Native-built cmake/ninja on PATH: nested ExternalProject_Add reconfigures
# re-resolve ninja via PATH and inherit only the generator name.
export PATH="$DEPENDS_PREFIX/x86_64-linux-gnu-native/bin:$PATH"

# build.gradle.in's signingConfigs.release block is used for every buildType,
# read from these four env vars. Defaults to the workstation's Android debug
# keystore. Overridable because the signing identity decides whether an APK can
# update an installed one: a different key means INSTALL_FAILED_UPDATE_INCOMPATIBLE
# and a reinstall, which costs the device its texture cache.
export KODI_ANDROID_KEY_ALIAS="${KODI_ANDROID_KEY_ALIAS:-androiddebugkey}"
export KODI_ANDROID_KEY_PASSWORD="${KODI_ANDROID_KEY_PASSWORD:-android}"
export KODI_ANDROID_STORE_FILE="${KODI_ANDROID_STORE_FILE:-$HOME/.android/debug.keystore}"
export KODI_ANDROID_STORE_PASSWORD="${KODI_ANDROID_STORE_PASSWORD:-android}"

if [ ! -f "$KODI_ANDROID_STORE_FILE" ]; then
  echo "Keystore not found: $KODI_ANDROID_STORE_FILE" >&2
  echo "Set KODI_ANDROID_STORE_FILE, or create the Android debug keystore." >&2
  exit 1
fi

mkdir -p "$RAMDIR" \
  "$DEPENDS_PREFIX/x86_64-linux-gnu-native" \
  "$DEPENDS_PREFIX/$DEPENDS_DIR_NAME" \
  "$BUILD_DIR" \
  "$CCACHE_DIR"

# --- 1. Source: sync the working tree into $SRC, every run -----------------
# rsync from a git-driven file list, not `git clone`: keeps uncommitted edits
# and does not stamp every mtime to now, which would make ninja rebuild
# everything. No --delete: tools/depends/target/* holds built state that is not
# all gitignored.
echo "==> Syncing kodi source into $SRC"
mkdir -p "$SRC"
git -C "$SOURCE_REPO" ls-files -z --cached --others --exclude-standard \
  | rsync -a --files-from=- --from0 "$SOURCE_REPO/" "$SRC/"

# --- 1b. Fetch the addons this build ships with ----------------------------
# The skin and its dependencies, from addons.txt, into bundled-addons/ next to
# the source tree. The patched cmake/scripts/android/Install.cmake picks them up
# from there. Not into the source tree's own addons/: nothing globs that.
ADDON_LIST="${ADDON_LIST:-$SELF_DIR/addons.txt}"
ADDON_CACHE="${ADDON_CACHE:-$RAMDIR/addon-zips}"
ADDON_MIRROR="${ADDON_MIRROR:-https://mirrors.kodi.tv/addons/omega}"
ADDON_DIR="$SRC/bundled-addons"

if [ -f "$ADDON_LIST" ]; then
  mkdir -p "$ADDON_CACHE"
  n=0
  while read -r addon version _rest; do
    case "$addon" in ''|\#*) continue ;; esac
    [ -n "$version" ] || { echo "No version for $addon in $ADDON_LIST" >&2; exit 1; }

    if [ -d "$ADDON_DIR/$addon" ]; then
      continue
    fi

    zip="$ADDON_CACHE/$addon-$version.zip"
    if [ ! -f "$zip" ]; then
      echo "==> Fetching $addon $version"
      # -f so a 404 fails here rather than unzipping an error page. Written to
      # a temp name first: a half-downloaded zip in the cache would be treated
      # as good on the next run.
      curl -fsSL -o "$zip.part" "$ADDON_MIRROR/$addon/$addon-$version.zip" \
        || { echo "Not on the mirror: $addon $version" >&2; rm -f "$zip.part"; exit 1; }
      mv "$zip.part" "$zip"
    fi

    unzip -q -o "$zip" -d "$ADDON_DIR"
    [ -f "$ADDON_DIR/$addon/addon.xml" ] \
      || { echo "$zip did not unpack to $addon/ with an addon.xml" >&2; exit 1; }
    n=$((n + 1))
  done < "$ADDON_LIST"
  echo "==> Bundled $n addon(s) from $ADDON_LIST"
fi

# --- 1c. Userdata that ships with the build --------------------------------
# The skin's settings and the skinshortcuts menu. Copied into the source tree
# rather than carried in a patch: it is data, and a patch would need
# regenerating every time one of the files changes.
#
# Splash.java decides what happens with it on the device, and it seeds rather
# than enforces: written on a clean install, left alone afterwards.
if [ -d "$SELF_DIR/userdata" ]; then
  echo "==> Bundling userdata from $SELF_DIR/userdata"
  mkdir -p "$SRC/userdata"
  cp -R "$SELF_DIR/userdata/." "$SRC/userdata/"
fi

cd "$SRC/tools/depends"

# --- 2. Bootstrap + configure the depends system --------------------------
# Only reconfigure when needed: ./configure rewrites Makefile.include, and its
# mtime invalidates every package's .configured-* marker. Checked against
# DEBUG_BUILD and HOST, since tools/depends is shared across ARCH values.
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
# cmake, ninja, python3, meson, bison, gettext, pkg-config. Fast next to step 4.
echo "==> Building native tools"
make -C native -j"$JOBS"

# --- 4. Target dependencies -------------------------------------------------
# curl, taglib, dav1d, gnutls, sqlite3 and the rest, cross-compiled for $HOST.
# The expensive step.
#
# EXCLUDED_DEPENDS drops samba/samba-gplv3 (ENABLE_SMBCLIENT=OFF) and
# libplist/libshairplay (ENABLE_AIRTUNES=OFF, ENABLE_PLIST=OFF). Plain `=` in
# target/Makefile, so an override on the command line wins.
#
# The override replaces the whole value, so it must repeat the platform's own
# defaults. For android in this release those are "libusb gtest"
# (tools/depends/target/Makefile:70-71), not master's set.
echo "==> Building target depends"
make -C target -j"$JOBS" \
  EXCLUDED_DEPENDS="libusb gtest samba samba-gplv3 libplist libshairplay"

# --- 5. Binary addons -------------------------------------------------------
# DISABLED, same as master, reason not yet resolved:
# tools/depends/target/binary-addons pulls from the external catalog
# (ADDONS_DEFINITION_DIR), so excluding by in-repo addon names fails silently
# (exit 0 despite an internal cmake error). Find the real trim mechanism before
# re-enabling.
# make -j"$JOBS" -C tools/depends/target/binary-addons ADDONS="..."

# --- 6. Configure the Kodi CMake build itself ------------------------------
# GEN=Ninja for parallel scheduling. DEBUG_BUILD=no becomes
# -DCMAKE_BUILD_TYPE=Release via tools/depends/target/cmakebuildsys/Makefile.
# cd back to $SRC: steps 2-4 ran from tools/depends.
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
