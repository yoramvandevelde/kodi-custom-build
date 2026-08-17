# kodi-custom-build

A personal Kodi Android build for one specific device (a Google TV
streamer, 32-bit/armv7a only). The goal: clone this, run one script, get a
working install on that device: no manual step afterward where you open a
file manager, browse to a web server, and drop `advancedsettings.xml` into
place by hand. That manual dance is the entire reason this exists.

## Two build targets

```
./install.sh omega     # 21.3-Omega release      -> library schema MyVideos131
./install.sh master    # pinned xbmc/xbmc master -> library schema MyVideos148
```

Both live side by side, each with its own patch series, build script and
Android toolchain. They are not variants of one build; they are pinned to
different upstream refs and need genuinely different NDK/SDK versions (see
[PREREQUISITES.md](PREREQUISITES.md)).

### Why the split exists: the library schema

Kodi's shared MySQL library carries a schema version compiled into the
binary (`CVideoDatabase::GetSchemaVersion`), and the database is literally
named after it: `MyVideos131`, `MyVideos148`. On startup Kodi looks for a
database at exactly its own schema version. If it doesn't find one, it
**copies the nearest older database and migrates the copy**, one-way, leaving
the original untouched.

That behaviour is the whole reason pinning matters here. Building against a
moving branch means a rebuild can land on a newer schema, silently fork the
shared library into a new database, and leave every other device still
pointed at the old one. Nothing errors; the libraries just quietly stop being
the same library.

So both targets are pinned to an explicit ref, never a branch:

- **`omega`** is `21.3-Omega`, the newest actual release. Schema 131/83, the
  same schema any official Kodi build speaks, which means off-the-shelf Kodi
  (distro package, AppImage, official APK) can share this library.
- **`master`** is a specific commit of untagged `xbmc/xbmc` master. Schema
  148/84 exists in no released Kodi, so nothing off-the-shelf can ever share
  a library with it. Bump that pin deliberately, and rebuild every device
  together when you do.

Migrations only run upward. Individual steps are sometimes trivially
reversible (schema 148 just adds two defaulted columns to `streamdetails`),
but others rewrite data in place with no copy kept (schema 147 rewrites
`path.strPath` encodings), so treat downgrades as "rescan", not "revert".

## Why not just a fork

The obvious way to carry changes against a big upstream project is a fork:
clone it, branch, commit. The problem is upkeep: a fork's history needs to
stay in sync with upstream (fetch, rebase, resolve conflicts) even during
long stretches where nothing here actually changed, and merge conflicts in a
codebase this size are exactly the kind of thing that go wrong quietly.

This repo is a patch series instead: a handful of `.patch` files applied with
`git am` onto a freshly cloned, pinned `xbmc/xbmc`. No history to keep in
sync, nothing to merge. If a patch stops applying cleanly, that's upstream
having touched something this build also touches: an explicit, loud failure
to go look at, not a silent merge that papers over the drift.

## Approach

- **Patches, not a fork.** See above. `install.sh` always starts from a clean
  upstream clone at a pinned ref.
- **No personal config or secrets committed, ever.** Anything
  device-specific (database credentials, a webdav URL) is a placeholder in a
  `.xml.in` template, resolved from a required environment variable at
  CMake-configure time. Missing a value is a hard, immediate failure, never a
  silently-broken APK, since delivering this exact config is the only reason
  this build exists in the first place.
- **A small runtime hook bridges "baked into the APK" and "actually where
  Kodi reads it".** The Android packaging step bundles the resolved config
  files as read-only APK assets, but Kodi only ever reads them from the live,
  writable profile directory; nothing built into Kodi itself copies one into
  the other. So a small addition to the `Splash` activity (which already
  runs, in Java, before the native engine ever loads) copies each seed file
  into place before handing off.
- **Not every seed file gets the same write policy.** `advancedsettings.xml`
  is refreshed on every single start: the repo is the source of truth, full
  stop, since this file is never meaningfully hand-edited on-device.
  `sources.xml` / `mediasources.xml` are written only if missing, i.e. seeded
  once on first boot: sources you add later through Kodi's own GUI have to
  survive a rebuild or update, not get silently wiped by one.
- **Accepted risk: a wrong seed value only self-corrects via a fresh
  install.** `sources.xml`/`mediasources.xml` are seed-once by design (see
  above), so a wrong value in that first build (a typo, a wrong URL scheme)
  doesn't get fixed by a later APK update, Splash.java won't touch a file
  that already exists. That's not a gap to close: "fix a bad out-of-the-box
  config" and "put a fresh, correct install on the device" are the same
  action for a build whose entire purpose is exactly that, and adding a way
  to force-overwrite would undo the protection this write-once policy exists
  for in the first place. Wipe the app, run the (now-fixed) build again.

## What changed, concretely

Two patches per target, same two changes, each rebased onto its own ref:

1. **Conditional `libshairplay.so` packaging.** The stock Android packaging
   Makefile bundled `libshairplay.so` unconditionally, even with
   `ENABLE_AIRTUNES=OFF` and the target never built. Now it's only added when
   the Shairplay CMake target actually exists.
2. **Bake per-device userdata config into the APK.** Three templated userdata
   files (`advancedsettings.xml`, `mediasources.xml`, `sources.xml`), resolved
   from required env vars, bundled as assets, and synced into the live profile
   directory by a new step in `Splash.java`; see the write-policy split above.

The two series are not interchangeable: upstream renamed the Shairplay CMake
target from `Shairplay::Shairplay` to `${APP_NAME_LC}::Shairplay` after 21.3,
so patch 1 differs between them.

## The scanner

The streamer is a client: it gets started when someone wants to watch
something, and it cannot be relied on to scan a large WebDAV source in the
background with the screen off. So library scanning lives in
[`scanner/`](scanner/README.md): a disposable Alpine container that boots once
a night, updates and cleans the shared library, and powers itself off.

It builds nothing. It runs stock `apk add kodi`, which is only possible
because the streamer is on a released Kodi: 21.x speaks `MyVideos131`, so an
off-the-shelf package can share the library. That was the whole point of
moving off master.

## Layout

- `install.sh`: takes a target, clones xbmc/xbmc at that target's pinned ref,
  applies its `patches/`, builds.
- `omega/`, `master/`: per-target `build-kodi.sh` (depends, cmake, apk) and
  `patches/`.
- `scanner/`: the nightly library-scanner container. No build, stock package.
- `scripts/restore-buildcache.sh` / `save-buildcache.sh`: mount/restore and
  save/backup the tmpfs build cache across reboots. Shared, target-aware: the
  ramdisk holds one target at a time with a backup dir per target.
- `scripts/kodi-env.sh.example`: template for the per-device config
  (credentials, webdav source, target ARCH). Copy to `kodi-env.sh`
  (gitignored) and fill in real values, never committed. Shared by both
  targets; only the toolchain paths differ, and those live in each
  `build-kodi.sh`.

## Usage

First time on a machine? See [PREREQUISITES.md](PREREQUISITES.md) (system
packages, Android SDK/NDK **per target**, debug keystore) before the below.

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

where `N` is how many of the most recent commits to export. Commits made on a
machine without a signing key attached can be signed at apply time instead, on
whichever machine does have it:

```sh
git am --gpg-sign <target>/patches/*.patch
```

To move a series onto a different ref, `git am -3` it there and resolve what
conflicts: that's how `omega/patches` was produced from `master/patches`.
