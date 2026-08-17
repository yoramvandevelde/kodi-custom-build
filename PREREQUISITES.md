# Prerequisites

Steps to prepare a clean machine before running `install.sh`. Verified
against what this project's Kodi builds actually need (cross-checked with
upstream's own `docs/README.Android.md` for each target), not copied blind.

There are two build targets and **they need different Android toolchains**.
Step 2 below is therefore split. Everything else is shared.

| | `omega` (21.3-Omega release) | `master` (pinned xbmc/xbmc master) |
|---|---|---|
| NDK | r21e (`21.4.7075529`) | r28c (`28.2.13676358`) |
| ndk-api | 21 | 24 |
| SDK platform | android-34 | android-37.0 |
| build-tools | 33.0.1 | 37.0.0 |
| SDK root | `$HOME/android-tools-omega/` | `$HOME/android-tools/` |
| library schema | `MyVideos131` / `MyMusic83` | `MyVideos148` / `MyMusic84` |

## 1. System packages

```sh
sudo apt update
sudo apt install autoconf bison build-essential ccache curl openjdk-17-jdk \
  flex gawk git gperf lib32stdc++6 lib32z1 lib32z1-dev libcurl4-openssl-dev \
  unzip zip zlib1g-dev rsync
```

`rsync` isn't part of upstream Kodi's own prerequisites -- it's needed by
this project's `build-kodi.sh` scripts, which sync the source tree onto tmpfs
on every build (see the comments at the top of either script for why).

`ccache` isn't strictly required either, but `tools/depends/configure.ac`
auto-detects and uses it whenever it's on `PATH` (on by default, no flag
needed), and both build scripts already point `CCACHE_DIR` at the persistent
tmpfs cache -- skip it only if you don't want that.

> [!NOTE]
> On a 32-bit host, drop `lib32stdc++6 lib32z1 lib32z1-dev`.

`openjdk-17-jdk` is named explicitly rather than `default-jdk` because "the
default" is a per-release moving target, and newer is not better here: the
`omega` target ships the Gradle 8.3 wrapper, which supports up to Java 20
(Java 21 needs Gradle 8.5+). A JDK that's too new fails at the very last
step, APK packaging, after the whole build has already run.

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
> The two targets get **separate SDK roots**, and that is deliberate.
> `tools/depends/configure.ac` picks build-tools with
> `ls $sdk/build-tools | sort -V | tail -n 1`, i.e. always the newest one
> installed, with no way to ask for an older one. Putting both targets'
> build-tools in one root would silently hand the omega build master's
> 37.0.0 no matter what any doc says. Two roots removes the ambiguity
> instead of trying to outsmart that sort order.

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
> `tools/depends/configure.ac` (line 578) requires an `sdkmanager` inside
> the SDK root being used, at `tools/bin/`, `cmdline-tools/bin/` or
> `cmdline-tools/latest/bin/`. Populating a root with another root's
> sdkmanager gets you the NDK, platforms and build-tools but leaves no
> cmdline-tools behind, so `./configure` fails on a root that otherwise
> looks complete. `omega/build-kodi.sh` checks for this up front.

Why these exact versions:

- **platform android-34** is not a floor, it's the value.
  `cmake/platform/android/android.cmake` in 21.3 hardcodes `TARGET_SDK 34`,
  which becomes gradle's `compileSdk`/`targetSdk`. A newer platform installed
  instead does not substitute for it.
- **NDK r21e** is what Kodi's own `docs/README.Android.md` recommends for
  this release ("CI/CD platforms currently use r21e for build testing and
  releases"). `omega/build-kodi.sh` passes it explicitly via
  `--with-ndk-path`, which 21.3 **requires** -- unlike master, its configure
  has no NDK auto-detection and hard-errors with "NDK path is required for
  android" without it.

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
> Neither path needs `sudo`. (An earlier machine used `/opt/android-tools`
> instead, which is root-owned and needs `sudo` just to create the directory
> -- avoid that unless you have a reason for it.)

## 3. Debug signing keystore

Shared by both targets. This is a personal sideload build, so it reuses the
debug keystore for release signing too (see either `build-kodi.sh`'s
`KODI_ANDROID_*` defaults). Generate one if `~/.android/debug.keystore`
doesn't already exist:

```sh
keytool -genkey -keystore ~/.android/debug.keystore -v \
  -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
  -keypass android -storepass android -keyalg RSA -keysize 2048 \
  -validity 10000
```

If it prints an "already exists" error, that's fine -- it means this step is
already done.

## 4. (Optional) SDK/NDK/tarballs paths

Each `build-kodi.sh` defaults `NDK_SDK` to its own root (step 2a/2b) and both
share `TARBALLS` at `$HOME/android-tools/xbmc-tarballs`. Sharing the tarball
cache is safe: it's purely a download cache of upstream dependency tarballs
keyed by filename+version, so two Kodi versions wanting different dependency
versions just means both sets live there.

Only override if you installed things elsewhere:

```sh
NDK_SDK=/path/to/sdk TARBALLS=/path/to/tarballs ./omega/build-kodi.sh
```

`omega/build-kodi.sh` additionally accepts `NDK_VERSION` / `NDK_PATH` if your
NDK isn't at `$NDK_SDK/ndk/21.4.7075529`.

## 5. (Optional) tmpfs build cache

`scripts/restore-buildcache.sh` mounts a tmpfs and needs root to do so
(`mount`). If you don't want a RAM-backed build (slower, but no root needed
and no RAM budget to plan around), skip it and adjust `RAMDIR` in the
relevant `build-kodi.sh` to point at a plain directory on disk instead.

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
