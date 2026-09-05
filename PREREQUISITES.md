# Prerequisites

Preparing a machine to run `install.sh` by hand. The two targets need
different Android toolchains, so step 2 is split; everything else is shared.

| | `omega` (21.3-Omega release) | `master` (pinned xbmc/xbmc master) |
|---|---|---|
| NDK | r21e (`21.4.7075529`) | r28c (`28.2.13676358`) |
| ndk-api | 21 | 24 |
| SDK platform | android-34 | android-37.0 |
| build-tools | 33.0.1 | 37.0.0 |
| SDK root | `$HOME/android-tools-omega/` | `$HOME/android-tools/` |
| library schema | `MyVideos131` / `MyMusic83` | `MyVideos148` / `MyMusic84` |

## 0. Build host

> [!IMPORTANT]
> The `omega` target needs a build host of roughly 2024 vintage. **Ubuntu
> 24.04 works with no workarounds.** Ubuntu 25.10 does not build it at all.

`tools/depends/native/` compiles 2023-era sources with the **host** compiler,
so the host's age is a compatibility constraint:

- GCC 15 defaults to C23, where `bool` is a keyword. That breaks m4's bundled
  gnulib and pkg-config's bundled glib.
- CMake 3.26.4 (what 21.3 pins) does not build against a 2025 libcurl
  (`CURL_NETRC_OPTION` became a long) or OpenSSL 3.5 (`SSL_get_peer_certificate`
  and `EVP_PKEY_id` are gone).

`tools/depends/target/` is unaffected: it builds against the pinned NDK, not
anything the distro ships. The `master` target's native pins are current, so it
does not have this constraint.

## 1. System packages

```sh
sudo apt update
sudo apt install autoconf bison build-essential ccache curl openjdk-17-jdk \
  flex gawk git gperf lib32stdc++6 lib32z1 lib32z1-dev libcurl4-openssl-dev \
  unzip zip zlib1g-dev rsync
```

`rsync` is this repo's requirement, not Kodi's: `build-kodi.sh` syncs the
source tree on every build.

`ccache` is optional. `tools/depends/configure.ac` picks it up whenever it is
on `PATH`, and both build scripts point `CCACHE_DIR` at the persistent cache.

> [!NOTE]
> On a 32-bit host, drop `lib32stdc++6 lib32z1 lib32z1-dev`.

`openjdk-17-jdk` by name, not `default-jdk`: `omega` ships the Gradle 8.3
wrapper, which supports up to Java 20 (Java 21 needs Gradle 8.5+). A newer JDK
fails at APK packaging, after the whole build has run.

```sh
java --version     # expect 17
```

If a newer JDK is already the system default, either switch it or point
`JAVA_HOME` at the 17 install:

```sh
sudo update-alternatives --config java
```

## 2. Android SDK + NDK

Not an apt package -- download and extract by hand. Download "Command line
tools only" from [developer.android.com/studio](https://developer.android.com/studio)
(the filename includes a build number that changes over time, adjust below).

> [!IMPORTANT]
> The two targets get **separate SDK roots**. `tools/depends/configure.ac`
> (line 589) picks build-tools with `ls $sdk/build-tools | sort -V | tail -n 1`,
> always the newest installed, with no way to ask for an older one. One shared
> root hands the omega build master's 37.0.0.

### 2a. For the `omega` target (21.3-Omega)

If you already set up the `master` root (2b), reuse its `sdkmanager` rather
than downloading the zip again: `--sdk_root` controls where packages are
installed, so one sdkmanager can populate any number of roots.

```sh
OMEGA="$HOME/android-tools-omega/android-sdk-linux"
mkdir -p "$OMEGA"
cd "$HOME/android-tools/android-sdk-linux/cmdline-tools/bin"

./sdkmanager --sdk_root="$OMEGA" --licenses
./sdkmanager --sdk_root="$OMEGA" "cmdline-tools;latest" platform-tools \
  "platforms;android-34" "build-tools;33.0.1" "ndk;21.4.7075529"
```

Otherwise, starting from the downloaded zip:

```sh
mkdir -p "$HOME/android-tools-omega/android-sdk-linux"
unzip commandlinetools-linux-*.zip -d "$HOME/android-tools-omega/android-sdk-linux/"

cd "$HOME/android-tools-omega/android-sdk-linux/cmdline-tools/bin"
./sdkmanager --sdk_root="$(pwd)/../.." --licenses
./sdkmanager --sdk_root="$(pwd)/../.." platform-tools
./sdkmanager --sdk_root="$(pwd)/../.." "platforms;android-34"
./sdkmanager --sdk_root="$(pwd)/../.." "build-tools;33.0.1"
./sdkmanager --sdk_root="$(pwd)/../.." "ndk;21.4.7075529"
```

> [!IMPORTANT]
> `"cmdline-tools;latest"` in the reuse route is not optional.
> `tools/depends/configure.ac` (line 578) requires an `sdkmanager` inside the
> SDK root being used, at `tools/bin/`, `cmdline-tools/bin/` or
> `cmdline-tools/latest/bin/`. Populating a root with another root's sdkmanager
> leaves none behind, so `./configure` fails on a root that looks complete.

Why these exact versions:

- **platform android-34** is the value, not a floor.
  `cmake/platform/android/android.cmake:7` hardcodes `TARGET_SDK 34`, which
  becomes gradle's `compileSdk`/`targetSdk`. A newer platform does not
  substitute for it.
- **NDK r21e** is what this release's `docs/README.Android.md` recommends.
  `omega/build-kodi.sh` passes it via `--with-ndk-path`, which 21.3 requires:
  `configure.ac:567` errors with "NDK path is required for android" without it.

### 2b. For the `master` target

```sh
mkdir -p "$HOME/android-tools/android-sdk-linux"
unzip commandlinetools-linux-*.zip -d "$HOME/android-tools/android-sdk-linux/"

cd "$HOME/android-tools/android-sdk-linux/cmdline-tools/bin"
./sdkmanager --sdk_root="$(pwd)/../.." --licenses
./sdkmanager --sdk_root="$(pwd)/../.." platform-tools
./sdkmanager --sdk_root="$(pwd)/../.." "platforms;android-37.0"
./sdkmanager --sdk_root="$(pwd)/../.." "build-tools;37.0.0"
./sdkmanager --sdk_root="$(pwd)/../.." "ndk;28.2.13676358"
```

> [!TIP]
> Neither path needs `sudo`. Keep them under `$HOME` rather than somewhere
> root-owned like `/opt`.

## 3. Debug signing keystore

Shared by both targets. A personal sideload build, so the debug keystore is
reused for release signing (see `build-kodi.sh`'s `KODI_ANDROID_*` defaults).
Generate one if `~/.android/debug.keystore` does not exist:

```sh
keytool -genkey -keystore ~/.android/debug.keystore -v \
  -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
  -keypass android -storepass android -keyalg RSA -keysize 2048 \
  -validity 10000
```

An "already exists" error means this step is done.

## 4. (Optional) SDK/NDK/tarballs paths

Each `build-kodi.sh` defaults `NDK_SDK` to its own root (step 2a/2b) and both
share `TARBALLS` at `$HOME/android-tools/xbmc-tarballs`. Sharing is safe: it is
a download cache keyed by filename+version, so both targets' sets coexist.

Only override if you installed things elsewhere:

```sh
NDK_SDK=/path/to/sdk TARBALLS=/path/to/tarballs ./omega/build-kodi.sh
```

`omega/build-kodi.sh` additionally accepts `NDK_VERSION` / `NDK_PATH` if your
NDK isn't at `$NDK_SDK/ndk/21.4.7075529`.

## 5. (Optional) tmpfs build cache

`scripts/restore-buildcache.sh` mounts a tmpfs, which needs root. To build on
disk instead, skip it and point `RAMDIR` in `build-kodi.sh` at a plain
directory.

The ramdisk holds **one target at a time**, with a separate backup dir per
target (`/home/yoram/build-cache-backup-{omega,master}`). Switching targets:

```sh
./scripts/save-buildcache.sh master      # checkpoint what's there now
./scripts/restore-buildcache.sh omega    # swap in the other target
```

`restore-buildcache.sh` writes a `.buildcache-target` stamp into the ramdisk
and will warn before overwriting a target you haven't saved.

## Next

With all of the above done:

```sh
cp scripts/kodi-env.sh.example scripts/kodi-env.sh
$EDITOR scripts/kodi-env.sh
source scripts/kodi-env.sh
./scripts/restore-buildcache.sh omega   # only if using the tmpfs cache from step 5
./install.sh omega
```
