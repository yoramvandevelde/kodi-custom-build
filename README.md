# kodi-custom-build

A personal Kodi Android build for one specific device (a Google TV
streamer, 32-bit/armv7a only). The goal: clone this, run one script, get a
working install on that device: no manual step afterwards where you open
a file manager, browse to a web server, and drop `advancedsettings.xml`
into place by hand. That manual dance is the entire reason this exists.

## Why not just a fork

The obvious way to carry changes against a big upstream project is a fork:
clone it, branch, commit. The problem is upkeep: a fork's history needs to
stay in sync with upstream (fetch, rebase, resolve conflicts) even during
long stretches where nothing here actually changed, and merge conflicts in
a codebase this size are exactly the kind of thing that go wrong quietly.

This repo is a patch series instead: a handful of `.patch` files applied
with `git am` onto a freshly cloned, always-current `xbmc/xbmc`. No history
to keep in sync, nothing to merge. If a patch stops applying cleanly,
that's upstream having touched something this build also touches: an
explicit, loud failure to go look at, not a silent merge that papers over
the drift.

## Approach

- **Patches, not a fork.** See above. `install.sh` always starts from a
  clean upstream clone.
- **No personal config or secrets committed, ever.** Anything
  device-specific (database credentials, a webdav URL) is a placeholder in
  a `.xml.in` template, resolved from a required environment variable at
  CMake-configure time. Missing a value is a hard, immediate failure,
  never a silently-broken APK, since delivering this exact config is the
  only reason this build exists in the first place.
- **A small runtime hook bridges "baked into the APK" and "actually where
  Kodi reads it".** The Android packaging step bundles the resolved config
  files as read-only APK assets, but Kodi only ever reads them from the
  live, writable profile directory; nothing built into Kodi itself copies
  one into the other. So a small addition to the `Splash` activity (which
  already runs, in Java, before the native engine ever loads) copies each
  seed file into place before handing off.
- **Not every seed file gets the same write policy.** `advancedsettings.xml`
  is refreshed on every single start: the repo is the source of truth,
  full stop, since this file is never meaningfully hand-edited on-device.
  `sources.xml` / `mediasources.xml` are written only if missing, i.e.
  seeded once on first boot: sources you add later through Kodi's own GUI
  have to survive a rebuild or update, not get silently wiped by one.

## What changed, concretely

Two patches so far:

1. **Conditional `libshairplay.so` packaging.** The stock Android packaging
   Makefile bundled `libshairplay.so` unconditionally, even with
   `ENABLE_AIRTUNES=OFF` and the target never built. Now it's only added
   when the Shairplay CMake target actually exists.
2. **Bake per-device userdata config into the APK.** Three templated
   userdata files (`advancedsettings.xml`, `mediasources.xml`,
   `sources.xml`), resolved from required env vars, bundled as assets, and
   synced into the live profile directory by a new step in `Splash.java`;
   see the write-policy split above.

## Layout

- `install.sh`: clones xbmc/xbmc fresh, applies `patches/`, builds.
- `build-kodi.sh`: the build pipeline itself (depends, cmake, apk).
- `patches/`: the delta against upstream, as a `git am`-able series.
- `scripts/restore-buildcache.sh` / `save-buildcache.sh`: mount/restore
  and save/backup a tmpfs build cache across reboots.
- `scripts/kodi-env.sh.example`: template for the per-device config
  (credentials, webdav source, target ARCH). Copy to `kodi-env.sh`
  (gitignored) and fill in real values, never committed.

## Usage

First time on a machine? See [PREREQUISITES.md](PREREQUISITES.md) (system
packages, Android SDK/NDK, debug keystore) before the below.

```sh
cp scripts/kodi-env.sh.example scripts/kodi-env.sh
$EDITOR scripts/kodi-env.sh          # fill in real values
source scripts/kodi-env.sh

./scripts/restore-buildcache.sh      # if using the tmpfs build cache
./install.sh                         # clone xbmc/xbmc + apply patches + build
```

## Regenerating the patch series

After committing changes in a working xbmc/xbmc checkout:

```sh
git format-patch -N --output-directory /path/to/kodi-custom-build/patches HEAD
```

where `N` is how many of the most recent commits to export. Commits made on
a machine without a signing key attached can be signed at apply time
instead, on whichever machine does have it:

```sh
git am --gpg-sign patches/*.patch
```
