# kodi-custom-build

A personal Kodi Android build for one device (Google TV streamer,
32-bit/armv7a). Clone, run one script, get a working install: no manual
step of dropping `advancedsettings.xml` onto the device by hand.

## Two build targets

```
./install.sh omega     # 21.3-Omega release      -> library schema MyVideos131
./install.sh master    # pinned xbmc/xbmc master -> library schema MyVideos148
```

Each has its own patch series, build script and Android toolchain (see
[PREREQUISITES.md](PREREQUISITES.md)). They're pinned to explicit refs, never
a branch, because Kodi's library schema is compiled into the binary and the
database is named after it (`MyVideos131`, `MyVideos148`). If it doesn't find
a database at its own schema version, Kodi silently copies the nearest older
one and migrates the copy, one-way. Building against a moving branch risks
forking the shared library without any error. Migrations only run upward,
so treat a downgrade as "rescan", not "revert".

- **`omega`** = `21.3-Omega`. Schema 131/83, same as any official Kodi build,
  so off-the-shelf Kodi (distro package, AppImage, APK) can share the library.
- **`master`** = a pinned commit of `xbmc/xbmc` master. Schema 148/84 exists
  in no release, so nothing off-the-shelf can share a library with it. Bump
  the pin deliberately and rebuild every device together.

## Why patches, not a fork

A fork needs its history kept in sync with upstream forever, and merge
conflicts in a codebase this size fail quietly. This repo instead applies a
handful of `.patch` files with `git am` onto a fresh, pinned `xbmc/xbmc`
clone. If a patch stops applying, that's an explicit, loud failure, not a
silent merge.

## Approach

- **No personal config or secrets committed.** Device-specific values
  (DB credentials, WebDAV URL) live as placeholders in `.xml.in` templates,
  resolved from required env vars at CMake-configure time. A missing value
  is a hard build failure, never a silently-broken APK.
- **A Splash.java hook bridges "baked into the APK" and "where Kodi actually
  reads config".** The Android packaging step bundles resolved config as
  read-only APK assets; nothing in Kodi copies them into the writable
  profile dir on its own, so a small addition to the `Splash` activity does
  it before the native engine loads.
- **Write policy differs per file.** `advancedsettings.xml` is refreshed on
  every start (repo is source of truth). `sources.xml` / `mediasources.xml`
  are written only if missing, so sources added later via the GUI survive a
  rebuild. This means a bad seed value (typo, wrong URL scheme) only
  self-corrects via a fresh install, not an APK update, that's intentional:
  fixing a bad out-of-the-box config and doing a fresh install are the same
  action here.

## What changed, concretely

Two patches per target, same two changes, each rebased onto its own ref:

1. **Conditional `libshairplay.so` packaging.** Only bundled when the
   Shairplay CMake target actually exists, instead of unconditionally.
2. **Bake per-device userdata config into the APK.** `advancedsettings.xml`,
   `mediasources.xml`, `sources.xml` templated, resolved from env vars,
   bundled as assets, synced by `Splash.java` (see write policy above).

Not interchangeable between targets: upstream renamed the Shairplay CMake
target after 21.3, so patch 1 differs between them.

## The scanner

The streamer is a client and can't be relied on to scan a large WebDAV
source in the background. Library scanning instead lives in
[`scanner/`](scanner/README.md): a disposable Alpine image that runs once a
night as a Kubernetes Job, updates the shared library, and exits. It builds
nothing, it runs stock `apk add kodi`, possible because the streamer is on
released Kodi (21.x speaks `MyVideos131`). This repo produces the image and
its build pipeline; the manifests that run it live in the GitOps repo,
against the runtime contract documented there.

## Layout

- `install.sh`: takes a target, clones xbmc/xbmc at its pinned ref, applies
  `patches/`, builds.
- `omega/`, `master/`: per-target `build-kodi.sh` and `patches/`.
- `scanner/`: the nightly library-scanner image (`Dockerfile`,
  `entrypoint.sh`, userdata templates).
- `scripts/restore-buildcache.sh` / `save-buildcache.sh`: mount/restore and
  save/backup the tmpfs build cache across reboots. Target-aware.
- `scripts/kodi-env.sh.example`: template for per-device config. Copy to
  `kodi-env.sh` (gitignored), fill in real values. Shared by both targets.

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

`N` = how many recent commits to export. Commits made without a signing key
can be signed at apply time instead:

```sh
git am --gpg-sign <target>/patches/*.patch
```

To move a series onto a different ref, `git am -3` it there and resolve
conflicts, that's how `omega/patches` was produced from `master/patches`.
