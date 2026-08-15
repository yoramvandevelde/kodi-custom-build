# Prerequisites

Steps to prepare a clean machine before running `install.sh`. Verified
against what this project's Kodi fork actually needs (cross-checked with
upstream's own `docs/README.Android.md`), not copied blind.

## 1. System packages

```sh
sudo apt update
sudo apt install autoconf bison build-essential curl default-jdk flex \
  gawk git gperf lib32stdc++6 lib32z1 lib32z1-dev libcurl4-openssl-dev \
  unzip zip zlib1g-dev rsync
```

`rsync` isn't part of upstream Kodi's own prerequisites -- it's needed by
this project's `build-kodi.sh`, which syncs the source tree onto tmpfs on
every build (see the comments at the top of that script for why).

> [!NOTE]
> On a 32-bit host, drop `lib32stdc++6 lib32z1 lib32z1-dev`.

Check Java is 17+ (Gradle 8+ requires it):
```sh
java --version
```
If it's older, install a newer JDK and point `JAVA_HOME` at it.

## 2. Android SDK + NDK

This is not an apt package -- download and extract it by hand. This build
uses NDK r28c (28.2.13676358); the SDK build-tools/platform versions below
match what this project currently targets.

```sh
mkdir -p "$HOME/android-tools/android-sdk-linux"
```

Download "Command line tools only" from
[developer.android.com/studio](https://developer.android.com/studio) (the
filename includes a build number that changes over time -- adjust below),
then:

```sh
unzip commandlinetools-linux-*.zip -d "$HOME/android-tools/android-sdk-linux/"

cd "$HOME/android-tools/android-sdk-linux/cmdline-tools/bin"
./sdkmanager --sdk_root="$(pwd)/../.." --licenses
./sdkmanager --sdk_root="$(pwd)/../.." platform-tools
./sdkmanager --sdk_root="$(pwd)/../.." "platforms;android-37.0"
./sdkmanager --sdk_root="$(pwd)/../.." "build-tools;37.0.0"
./sdkmanager --sdk_root="$(pwd)/../.." "ndk;28.2.13676358"
```

> [!TIP]
> `$HOME/android-tools` needs no `sudo` at all. (An earlier machine used
> `/opt/android-tools` instead, which is root-owned and needs `sudo` just to
> create the directory -- avoid that unless you have a reason for it.)

## 3. Debug signing keystore

This is a personal sideload build, so it reuses the debug keystore for
release signing too (see `build-kodi.sh`'s `KODI_ANDROID_*` defaults).
Generate one if `~/.android/debug.keystore` doesn't already exist:

```sh
keytool -genkey -keystore ~/.android/debug.keystore -v \
  -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
  -keypass android -storepass android -keyalg RSA -keysize 2048 \
  -validity 10000
```

If it prints a "already exists" error, that's fine -- it means this step is
already done.

## 4. (Optional) SDK/NDK/tarballs path

`build-kodi.sh` defaults `NDK_SDK` to `$HOME/android-tools/android-sdk-linux`
and `TARBALLS` (the depends download cache) to
`$HOME/android-tools/xbmc-tarballs` -- matching step 2, no sudo needed for
either. Only override if you installed the SDK/NDK somewhere else:

```sh
NDK_SDK=/path/to/sdk TARBALLS=/path/to/tarballs ./build-kodi.sh
```

or edit the `NDK_SDK=` / `TARBALLS=` lines near the top of `build-kodi.sh`
by hand.

## 5. (Optional) tmpfs build cache

`scripts/restore-buildcache.sh` mounts a tmpfs and needs root to do so
(`mount`). If you don't want a RAM-backed build (slower, but no root
needed and no RAM budget to plan around), skip it and adjust `RAMDIR` in
`build-kodi.sh` to point at a plain directory on disk instead.

## Next

With all of the above done:

```sh
cp scripts/kodi-env.sh.example scripts/kodi-env.sh
$EDITOR scripts/kodi-env.sh
source scripts/kodi-env.sh
./scripts/restore-buildcache.sh   # only if using the tmpfs cache from step 5
./install.sh
```
