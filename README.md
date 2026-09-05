# kodi-custom-build

A personal Kodi Android build for a Google TV Streamer 4K. One install and the
device is configured: no dropping `advancedsettings.xml` on it by hand.

Built for **armv7a**, not arm64. The hardware is 64-bit capable but the Android
build shipped for it is not, so `ARCH=armv7a` has to be set explicitly; the
build scripts default to `arm64`.

## Two build targets

```
./install.sh omega     # 21.3-Omega release      -> library schema MyVideos131
./install.sh master    # pinned xbmc/xbmc master -> library schema MyVideos148
```

Each has its own patch series, build script and Android toolchain (see
[PREREQUISITES.md](PREREQUISITES.md)). Pinned to explicit refs, never a branch:
the library schema is compiled into the binary and the database is named after
it. A Kodi that finds no database at its own version copies the nearest older
one and migrates the copy, one way, so a drifting build forks the shared
library silently. Migrations only run upward, so a downgrade means a rescan.

- **`omega`** = `21.3-Omega`. Schema 131/83, same as any official Kodi build,
  so off-the-shelf Kodi (distro package, AppImage, APK) can share the library.
- **`master`** = a pinned commit of `xbmc/xbmc` master. Schema 148/84 exists
  in no release, so nothing off-the-shelf can share a library with it. Bump
  the pin deliberately and rebuild every device together.

## Why patches, not a fork

A fork has to be kept in sync forever, and merge conflicts in a codebase this
size fail quietly. This applies `.patch` files with `git am` onto a fresh,
pinned clone instead: a patch that stops applying fails loudly.

## Approach

- **No secrets committed.** Device-specific values live as placeholders in
  `.xml.in` templates, resolved from env vars at CMake-configure time. A
  missing value fails the build.
- **A `Splash.java` hook puts config where Kodi reads it.** The packaging step
  bundles resolved config as read-only APK assets, and nothing in Kodi copies
  those into the writable profile, so the `Splash` activity does it before the
  native engine loads.
- **Write policy differs per file.** `advancedsettings.xml` is refreshed on
  every start. `sources.xml` / `mediasources.xml` are written only if missing,
  so sources added through the GUI survive a rebuild. A bad seed value
  therefore only corrects on a fresh install, not on an update.

## What changed, concretely

See `<target>/patches/`. Each patch's commit message says what it does and why;
that is the authoritative list, not a copy of it here.

The series are not interchangeable between targets. Upstream renamed the
Shairplay CMake target after 21.3, among other things.

## The scanner

The streamer cannot be relied on to scan a large WebDAV source in the
background, so scanning lives in [`scanner/`](scanner/README.md): a disposable
Alpine image that runs nightly as a Kubernetes Job and exits. It builds
nothing and runs stock `apk add kodi`, which works because the streamer is on
a released Kodi. This repo produces the image; the manifests that run it live
in the GitOps repo.

## Layout

- `install.sh`: takes a target, clones xbmc/xbmc at its pinned ref, applies
  `patches/`, builds.
- `omega/`, `master/`: per-target `build-kodi.sh` and `patches/`.
- `scanner/`: the nightly library-scanner image (`Dockerfile`,
  `entrypoint.sh`, userdata templates).
- `scripts/restore-buildcache.sh` / `save-buildcache.sh`: save and restore the
  tmpfs build cache across reboots. Target-aware.
- `scripts/kodi-env.sh.example`: template for per-device config. Copy to
  `kodi-env.sh` (gitignored) and fill in real values.

## Usage

First time on a machine, see [PREREQUISITES.md](PREREQUISITES.md) first.

```sh
cp scripts/kodi-env.sh.example scripts/kodi-env.sh
$EDITOR scripts/kodi-env.sh          # fill in real values
source scripts/kodi-env.sh

./scripts/restore-buildcache.sh omega   # if using the tmpfs build cache
./install.sh omega                      # clone + checkout ref + patch + build
```

Switching targets swaps the whole ramdisk:

```sh
./scripts/save-buildcache.sh omega
./scripts/restore-buildcache.sh master
./install.sh master
```

## Regenerating a patch series

After committing changes in a working xbmc/xbmc checkout:

```sh
git format-patch -N --output-directory /path/to/kodi-custom-build/<target>/patches HEAD
```

`N` = how many recent commits to export. Commits made without a signing key can
be signed at apply time:

```sh
git am --gpg-sign <target>/patches/*.patch
```

To move a series onto a different ref, `git am -3` it there and resolve the
conflicts.
