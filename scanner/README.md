# Scanner

A disposable container that runs once, updates the shared video library and
exits. The streamer cannot be relied on to scan a large WebDAV source in the
background, so scanning happens here. It builds nothing: the stock Alpine
`kodi` package works because the streamer runs a released Kodi.

This directory produces the **image** and the pipeline that builds it. The
Kubernetes manifests that run it live elsewhere, in the GitOps repo; the
[runtime contract](#runtime-contract) below is the interface between the two.

## Version constraint

Kodi compiles its library schema into the binary and names the database after
it. A mismatch does not error: Kodi copies the nearest older database and
migrates the copy, forking the library silently.

| version | database | effect |
|---|---|---|
| 20.x | `MyVideos121` | separate library |
| **21.x** | **`MyVideos131`** | **correct** (matches streamer) |
| 22.x | `MyVideos148` | migrates 131, stranding the streamer |

The base image tag is the pin. `alpine:3.24` carries kodi 21.3, the same
release the streamer's APK is built from:

| Alpine | kodi |
|---|---|
| v3.22 | 21.2-r6 |
| v3.23 | 21.3-r1 |
| **v3.24** | **21.3-r4** |
| edge | 21.3-r6 |

The Dockerfile reads the installed version back out of apk's database and
**refuses to build** anything but 21.x, so a bumped `FROM` fails in CI rather
than forking the library. When Kodi 22 reaches Alpine, move this in step with
rebuilding the streamer APK.

## Building

```sh
docker build -t kodi-scanner scanner/
```

CI does the same on every push touching `scanner/`, and pushes to
`ghcr.io/<owner>/kodi-scanner` as `latest` plus the commit sha
(`.github/workflows/scanner-image.yml`). That workflow runs
`check-templates.sh` first, so template drift stops the build.

The published image is `linux/amd64`. A local build on an Apple Silicon
machine produces an arm64 image and works fine for testing, because Alpine
carries kodi 21.3 for aarch64 too.

## Runtime contract

What the thing running this image has to provide.

| | |
|---|---|
| **env** | `KODI_DB_HOST`, `KODI_DB_PORT`, `KODI_DB_USER`, `KODI_DB_PASS`, `KODI_WEBDAV_SOURCE_URL`. Same values as the APK builds. Any one missing and it exits 1 before starting Kodi, rather than building its own separate library. |
| **user** | uid/gid 1000, non-root (Kodi refuses to run as root). No capabilities, no privileged mode. |
| **`/home/kodi/.kodi`** | Mount RAM here, 256M (`emptyDir` with `medium: Memory`). Throwaway profile. Note a memory-backed volume counts against the container's memory limit. |
| **`/var/log/kodi-scanner`** | Mount persistent storage here for the log. Without it the log dies with the container. Needs to be writable by gid 1000 (`fsGroup: 1000`). |
| **memory** | ~440MB measured for a full scan, plus whatever the RAM profile holds. |
| **exit** | 0 once a scan finished, 1 if Kodi went away without finishing. Never a timeout of its own, see [No watchdog](#no-watchdog-deliberately). |
| **concurrency** | One at a time, and only ever this one scanner, see [Only one machine should scan](#only-one-machine-should-scan). |
| **stdout** | The scan-relevant lines only. The full log goes to the log volume. |

Nothing needs `advancedsettings.xml` or `sources.xml` handed to it: those
are rendered at start from the env vars above, so no credentials sit in an
image layer.

## Running it by hand

```sh
docker run --rm \
  --tmpfs /home/kodi/.kodi:size=256M,uid=1000,gid=1000 \
  -v kodi-scanner-logs:/var/log/kodi-scanner \
  -e KODI_DB_HOST=... -e KODI_DB_PORT=... \
  -e KODI_DB_USER=... -e KODI_DB_PASS=... \
  -e KODI_WEBDAV_SOURCE_URL=... \
  kodi-scanner
```

The `uid=1000,gid=1000` on the tmpfs is load-bearing: a bare `--tmpfs` mounts
root-owned and Kodi runs as 1000. A named volume for the log inherits its
ownership from the image; a bind-mounted host directory has to be made
writable by uid 1000 yourself.

## What happens on start

```
run the image
  └─ entrypoint.sh
       ├─ render userdata from env into ~/.kodi, symlink temp/ to the log volume
       ├─ start the log filter that puts scan progress on stdout
       ├─ start Xvfb, wait for it to accept connections
       ├─ start kodi --standalone (under setsid, in its own process group)
       │    └─ videolibrary.updateonstartup scans by itself
       ├─ wait for "VideoInfoScanner: Finished scan" in the log
       ├─ SIGTERM kodi's process group
       ├─ move kodi.log aside under a timestamp
       └─ exit 0
```

`videolibrary.updateonstartup` in guisettings.xml makes Kodi scan on its own,
so nothing has to reach in from outside. It logs `VideoInfoScanner: Finished
scan. Scanning for video info took N ms` at `LOGINFO`
(`VideoInfoScanner.cpp:172`), which is the line the entrypoint waits for.

Two routes that do not work, so they do not get tried again: a custom service
addon (`UpdateLibrary(video)` + `onScanFinished`) is registered but never
started by `CServiceAddonManager`, silently; and JSON-RPC (`VideoLibrary.Scan`,
polling `Library.IsScanningVideo`) needs the webserver enabled and the poll
races the scan start.

`setsid` is required: `/usr/bin/kodi` is a shell wrapper that does not exec
`kodi-x11`, so signalling the wrapper's pid leaves Kodi running. Signalling
every process owned by the `kodi` user is not an option either, since the
entrypoint runs as that user and would kill itself.

There is no sound hardware. Kodi's audio engine then retries opening a sink
every 500ms forever and never finishes starting
(`CActiveAESink::OpenSink - no sink was returned`, `ActiveAESink.cpp:954`), so
the image ships a null ALSA device.

## It scans, it does not clean

`<videolibrary><cleanonupdate>` is removed, and must stay removed. Clean
decides what to delete by checking whether each path still exists, and an
unreachable WebDAV read is indistinguishable from "gone". A run whose
connection died mid-clean removed ~700 good titles, and the cleanup tables log
under a component that is off by default. A rescan restores the rows from NFOs
but as new `idFile` entries, so watched state and resume points are gone.

Delete entries for removed files by hand, when the source is known healthy.

## Profile layout: RAM for throwaway, disk for the log

**RAM** (`~/.kodi`): userdata and artwork cache. Nothing here needs to survive:
the library is in MySQL, and `Textures13.db` / `Thumbnails/` are per-instance.
Estuary's home screen pulls artwork into the cache as soon as it loads, with
nobody navigating, so it would be written only to be discarded. Do not fix that
with `<videolibrary><artworkLevel>`: that controls what is written to the
shared library and would starve the streamer too.

**Disk** (`~/.kodi/temp` symlinked to `/var/log/kodi-scanner/temp`): the log.
At `loglevel 1` a full scan runs to hundreds of MB and it is the only
diagnostic this container has. Each run is renamed to `kodi-<timestamp>.log`
(Kodi keeps only one), fortnight retention.

The entrypoint mounts nothing itself: `mount -t tmpfs` needs `CAP_SYS_ADMIN`.
Whether `~/.kodi` is RAM is the manifest's decision; it runs either way.

### Sizing

A 256M memory-backed volume is a limit, not a reservation, and costs nothing
unless written to. If it fills, writes fail with `ENOSPC`; the scan is
unaffected, since it writes to MySQL. Kodi is the real consumer, measured at
roughly **440 MB** for a full scan (~7600 movies plus TV shows).

### No watchdog, deliberately

No timeout anywhere, and none in the manifest either (`activeDeadlineSeconds`
is the same thing under another name). A wedged scan should stay up with its
log intact rather than be destroyed by a watchdog. It shows up as "the library
stopped updating", since only one scanner runs at a time and the next is
skipped.

The progress lines on stdout are the first place to look:

```
Scanning dir / Rescanning dir / Finished scan / ERROR
```

The filter drops the `enable_tag_whitelist ... was not found` noise from a TMDB
scraper update. Everything else is in the timestamped log on the log volume.

## Keeping the config in step

`sources.xml` must render **byte-identically** on the scanner and the streamer.
Kodi stores the path in the library's `path` table, so a trailing slash makes it
a different source and duplicates every title. The streamer's templates are in
`omega/patches/0002-*.patch`, the scanner's in `scanner/userdata/`. After
touching either side:

```sh
./scanner/check-templates.sh
```

Fails on any difference in `sources.xml.in`, or in the database blocks of
`advancedsettings.xml.in`. CI runs it before building the image.

## Only one machine should scan

An architecture constraint, not a preference. `CVideoInfoScanner::GetPathHash`
(`VideoInfoScanner.cpp:2219-2229`) hashes the raw bytes of `m_dwSize` and a
`time_t`, and `time_t` is 4 bytes on 32-bit Android against 8 on x86_64 Linux.
Streamer and scanner therefore produce **different hashes for identical
directories**. If both scan, each run invalidates the other's hashes and both
walk everything forever.

So leave `videolibrary.updateonstartup` off on the streamer and any other
client; it defaults to off, so verify rather than configure. A client that
scans once costs the next scanner run a full walk, nothing worse.

Two scanner runs at once fail the same way, on top of both writing to one
library. Whatever schedules this must refuse to start a second one.

## What a run costs

WebDAV directory listings dominate: 16 seconds to 3.5 minutes per folder
depending on size, against roughly 200ms per title once a listing has arrived,
or about five directories per second. The first run walks everything, since
there are no path hashes yet.
