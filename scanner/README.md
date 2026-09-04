# Scanner

A disposable container that runs once, updates the shared video library, and
exits. The streamer is a client and can't be relied on to scan a large
WebDAV source in the background, so scanning moves here instead: a container
that exists only for the length of one library pass. It builds nothing, it's
the stock Alpine `kodi` package, because the whole point of the streamer
running 21.3 is that a released Kodi can share its library.

This directory produces the **image** and the pipeline that builds it. The
Kubernetes manifests that run it live elsewhere, in the GitOps repo; the
[runtime contract](#runtime-contract) below is the interface between the two.

## Version constraint

Kodi compiles its library schema into the binary and names the database
after it. Mismatches don't error, Kodi just copies the nearest older
database into a new one and migrates the copy, silently forking the library.

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
**refuses to build** anything but 21.x, so a careless bump of `FROM` fails
in CI instead of quietly forking the library at four in the morning. When
Kodi 22 lands in Alpine, move this deliberately and in step with rebuilding
the streamer APK.

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

`videolibrary.updateonstartup` in guisettings.xml makes Kodi scan on its own
at start, no need to reach into it from outside. It logs
`VideoInfoScanner: Finished scan. Scanning for video info took N ms` at
`LOGINFO` when done, so the entrypoint waits for that line and stops Kodi.

This replaced a custom service addon (`UpdateLibrary(video)` +
`onScanFinished`): Kodi registered it but `CServiceAddonManager` never
started it, no error either way. The JSON-RPC route
(`VideoLibrary.Scan` / poll `Library.IsScanningVideo`) was also skipped,
it needs the webserver enabled and polling races the scan start. Two
settings of XML beat both.

`setsid` matters because `/usr/bin/kodi` is a shell wrapper that does not
exec `kodi-x11`: signalling the wrapper's pid alone would leave Kodi
running. The old Proxmox container signalled every process owned by the
`kodi` user instead, which is no longer an option now that the entrypoint
itself runs as that user and would kill itself.

There is no sound hardware, and Kodi does not shrug that off: its audio
engine retries opening a sink every 500ms, forever, and never finishes
starting (`CActiveAESink::OpenSink - no sink was returned` in the log). The
image ships a null ALSA device so the open succeeds.

## It scans, it does not clean

`<videolibrary><cleanonupdate>` was removed: it's dangerous on a network
source. Clean decides what to delete by checking whether each path still
exists, and an unreachable WebDAV read looks the same as "gone". A run whose
connection died mid-clean silently removed ~700 good titles (the cleanup
tables log under a component that's off by default). NFOs let a rescan
restore the rows, but they come back as new `idFile` entries, watched state
and resume points for those titles are gone for good.

Delete entries for removed files by hand instead, when the source is known
healthy.

## Profile layout: RAM for throwaway, disk for the log

**RAM** (`~/.kodi`): userdata and artwork cache. Nothing here needs to
survive, the library lives in MySQL, and `Textures13.db` / `Thumbnails/` are
per-instance. Estuary's home screen starts pulling artwork into the cache as
soon as it loads, with nobody navigating anywhere, so it'd otherwise be
written just to be thrown away. (Don't fix this via
`<videolibrary><artworkLevel>`, that controls what's written to the shared
library and would starve the streamer's artwork too.)

**Disk** (`~/.kodi/temp` symlinked to `/var/log/kodi-scanner/temp`): the
log. At `loglevel 1` a full scan runs to hundreds of MB, and it's the only
diagnostic this container has. Each run is renamed to `kodi-<timestamp>.log`
afterwards (Kodi only keeps one), fortnight retention. A crash keeps its log
for free since it was never in RAM.

The entrypoint mounts nothing itself: `mount -t tmpfs` needs
`CAP_SYS_ADMIN`, which this container has no business holding. Whether
`~/.kodi` is RAM is the manifest's decision, and it runs either way.

### Sizing

A 256M memory-backed volume is a limit, not a reservation, and costs nothing
unless written to. If it fills, writes fail with `ENOSPC` and stop there.
The scan itself is unaffected either way (it writes to MySQL over the
network). Kodi itself is the real memory consumer, measured at roughly
**440 MB** for a full scan (~7600 movies plus TV shows).

### No watchdog, deliberately

No timeout anywhere, and none should be added in the manifest either
(`activeDeadlineSeconds` is the same mistake with a different name). If a
scan wedges, the container stays up with its log intact instead of a
watchdog destroying that evidence. A wedge shows as "the library stopped
updating", because only one scanner may run at a time and the next one is
therefore skipped.

The progress lines on stdout are the first place to look:

```
Scanning dir / Rescanning dir / Finished scan / ERROR
```

The filter drops the harmless `enable_tag_whitelist ... was not found` noise
from a TMDB scraper update. Everything else is in the timestamped log on the
log volume.

## Keeping the config in step

`sources.xml` must render **byte-identically** on the scanner and the
streamer, Kodi stores the path in the library's `path` table, so a trailing
slash makes it a different source and every title gets duplicated. The
streamer's templates live in `omega/patches/0002-*.patch`, the scanner's in
`scanner/userdata/`. Run after touching either side:

```sh
./scanner/check-templates.sh
```

Fails on any difference in `sources.xml.in`, or in the database blocks of
`advancedsettings.xml.in`. CI runs it before building the image.

## Only one machine should scan

Architecture constraint, not a preference. Kodi hashes each directory
(`CVideoInfoScanner::GetPathHash`) from path, size and an `m_dwSize`/`time_t`
pair read straight out of memory, and `time_t` is 4 bytes on 32-bit Android
vs 8 on x86_64 Linux. Streamer and scanner therefore produce **different
hashes for identical directories**. If both scan, each run invalidates the
other's hashes and both do a full walk forever; with only the scanner
scanning, its hashes stay self-consistent and later runs skip what's
unchanged.

So leave `videolibrary.updateonstartup` off on the streamer and any other
client (it defaults to off, verify rather than configure). A client
scanning once isn't fatal, it just costs the next scanner run a full walk.

Two scanner runs at once are worse than pointless for the same reason, on
top of both writing to one library. Whatever schedules this has to refuse
to start a second one.

## Status

The image builds and runs end to end: config renders, the null ALSA device
gets Kodi past audio init, Xvfb comes up, Kodi starts under its own process
group, the finish line is detected, the log is archived and the container
exits 0 (and 1 when Kodi dies first).

Carried over from the Proxmox container this replaces, which ran the same
Kodi and the same config: connects to `MyVideos131` without creating a
second database, works through the source tree at roughly five directories
per second once a listing is in. The first run walks everything (no path
hashes yet); WebDAV directory listings dominate (16s-3.5min per folder
depending on size, vs ~200ms per title once a listing arrives).
