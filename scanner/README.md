# Scanner

A disposable Alpine container that boots once a night, updates the shared
video library, and powers itself off.

## Why this exists

The Google TV streamer is a client. It is started when someone wants to watch
something, and it cannot be relied on to scan a large WebDAV source in the
background with the screen off. So the scanning moves somewhere that has no
opinion about screens: a container that exists only for the length of one
library pass.

Nothing here builds Kodi. Unlike the `master` and `omega` targets, this uses
the stock Alpine package, because the whole point of putting the streamer on
21.3 was that a released Kodi can share its library.

## The version constraint

Kodi compiles its library schema version into the binary and names the database
after it. The 21.x line is `MyVideos131`, which is what the streamer and the
existing library use.

That makes the Kodi version here a hard requirement, not a preference:

| version | database | effect |
|---|---|---|
| 20.x | `MyVideos121` | builds a second, separate library |
| **21.x** | **`MyVideos131`** | **correct** |
| 22.x | `MyVideos148` | copies 131 into 148 and migrates it, stranding the streamer |

None of the wrong outcomes report an error. Kodi looks for a database at its
own schema version and, not finding one, copies the nearest older one and
migrates the copy. The libraries simply stop being the same library.

`provision.sh` refuses to continue if the installed package is not 21.x, and
**you must pin `/etc/apk/repositories` to an Alpine release carrying 21.x.**
At time of writing every branch does:

| Alpine | Kodi |
|---|---|
| v3.22 | 21.2 |
| v3.23 | 21.3 |
| v3.24 | 21.3 |
| edge | 21.3 |

When Kodi 22 lands in Alpine, upgrading is a decision to make deliberately and
in step with rebuilding the streamer APK, not something to let `apk upgrade`
do on its own.

## Creating the container

On the Proxmox host. Adjust storage, bridge and IDs to taste; `onboot=0` is
the load-bearing part, since this container is meant to be started by cron and
to stop itself.

```sh
pveam update
pveam download local alpine-3.24-default_20260101_amd64.tar.xz   # adjust to what's listed

pct create 900 local:vztmpl/alpine-3.24-default_20260101_amd64.tar.xz \
  --hostname kodi-scanner \
  --cores 4 --memory 1024 --swap 0 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 0 \
  --unprivileged 1
```

1G is what this host had spare, and it is the number the rest of the design is
built around: 256M of it goes to the tmpfs profile, the log is kept out of RAM
entirely, and Kodi gets the remainder. Whether that remainder is comfortable
for a scan of this size is the first thing to measure on a real run (see
Sizing, below). Give it more if you have it.

## Provisioning

Inside the container, once:

```sh
apk add --no-cache git
git clone https://github.com/yoramvandevelde/kodi-custom-build.git
cd kodi-custom-build

cp scripts/kodi-env.sh.example scripts/kodi-env.sh
$EDITOR scripts/kodi-env.sh        # same values as the APK builds
. scripts/kodi-env.sh

./scanner/provision.sh
```

`provision.sh` installs Kodi and Xvfb, renders the userdata templates, gives
ALSA a null device, and hooks `scan-wrapper.sh` into boot via OpenRC's
`local.d`. It writes the rendered config to `/etc/kodi-scanner/` with mode 600,
since it contains the database password and the WebDAV credentials.

The null ALSA device is not optional. A container has no sound hardware, and
Kodi does not shrug that off: its audio engine retries opening a sink every
500ms forever and never finishes starting, so the scan never begins. It shows
up as a log full of `CActiveAESink::OpenSink - no sink was returned` and
nothing else happening.

The checkout is only needed for provisioning. Nothing reads from it at runtime.

## Scheduling

On the Proxmox host, one line:

```cron
0 4 * * *  /usr/sbin/pct start 900
```

That is the entire external interface. Everything else (scan, shut down)
happens inside.

## What happens on boot

```
pct start 900
  └─ OpenRC local.d → scan-wrapper.sh
       ├─ mount tmpfs at ~/.kodi, copy config in, symlink temp/ to disk
       ├─ start Xvfb, wait for it to accept connections
       ├─ start kodi --standalone
       │    └─ videolibrary.updateonstartup scans by itself
       ├─ wait for "VideoInfoScanner: Finished scan" in the log
       ├─ SIGTERM kodi
       ├─ move kodi.log aside under a timestamp
       └─ poweroff
```

### How the scan is triggered and noticed

One setting does the work, and nothing needs to reach into Kodi from outside:
`videolibrary.updateonstartup` in guisettings.xml makes Kodi scan on its own as
soon as it starts. When it is done it logs

```
VideoInfoScanner: Finished scan. Scanning for video info took N ms
```

so the wrapper waits for that single line and then stops Kodi. That is
`LOGINFO`, so it shows up even at `loglevel 0`.

This replaced a custom service addon that called `UpdateLibrary(video)` and
waited on `onScanFinished`. The addon was the tidier design on paper, because
it needed no pre-baked `guisettings.xml`, but it never ran: Kodi discovered it,
registered it, logged `service.kodi.scanner v1.0.0 installed`, and then
`CServiceAddonManager` simply never started it, with no error either way, while
`service.xbmc.versioncheck` started fine from the same profile. Two settings of
XML beat an addon that will not start.

The JSON-RPC route (POST `VideoLibrary.Scan`, poll `Library.IsScanningVideo`)
was never used: it needs the webserver enabled, which is also a guisettings
change, and polling races the start of the scan.

### It scans, it does not clean

`<videolibrary><cleanonupdate>` was in here and has been taken out, because on
a network source it is dangerous.

The clean decides what to delete by checking whether each path still exists. A
WebDAV source that stalls does not answer, unreachable reads as gone, and Kodi
deletes it. That is not hypothetical: a run whose connection died mid-clean
removed roughly 700 perfectly good titles, and since the tables it walks log
under a component that is off by default, it did so in complete silence. The
first visible sign was the movie count dropping by several hundred.

It repairs itself, because the NFOs sit beside the files and the next scan
reads them back. But the restored rows are new `idFile` entries, so watched
state and resume points for those titles are gone.

Delete entries for removed files by hand instead, at a moment when the source
is known healthy.

### RAM for the throwaway parts, disk for the log

The profile is split, because the two things filling it want opposite
treatment.

**In RAM** (`~/.kodi` on a 256M tmpfs): userdata and the artwork cache. None of
it needs to survive. The library lives in MySQL, and `Textures13.db` +
`Thumbnails/` are per-instance and never shared, so a container discarded after
each run would be writing them only to throw them away. Kodi caches images for
whatever the GUI shows, and Estuary's home screen widgets start pulling them as
soon as the skin loads, with nobody navigating anywhere.

That artwork caching is **not** something to fix with
`<videolibrary><artworkLevel>`: that controls which artwork URLs are written to
the library, and the library is shared, so turning it down here would starve
the streamer of artwork too. Keeping the cache in RAM sidesteps it without
touching what gets stored.

**On disk** (`~/.kodi/temp` symlinked to `/var/log/kodi-scanner/temp`): the
log. At `loglevel 1` a full scan logs every directory listing, scraper call and
query, running to hundreds of MB. It is also the only diagnostic this box has,
so it is the one thing worth keeping. Sizing the tmpfs around a file we
explicitly want to persist would be backwards, and on disk a few hundred MB is
unremarkable.

Each run's log is renamed to `kodi-<timestamp>.log` afterwards, since Kodi
itself only keeps one previous run. Fortnight retention. A crash keeps its log
for free, since it was never in RAM to begin with.

### Sizing

`size=256M` is a limit, not a reservation, so it costs nothing until written
to. With the log elsewhere, what remains is userdata and tens of megabytes of
cached images.

If it fills anyway, writes fail with `ENOSPC` and stop there. It cannot grow
into the container's memory, which is what the explicit `size=` is for; a tmpfs
mounted without one defaults to half of RAM and that warning would be real. The
scan is unaffected regardless, since that writes to MySQL over the network.

Kodi itself is the real memory consumer. Measured at roughly **440 MB** during
a full scan of this library (~7600 movies plus TV shows), so 1G leaves real
headroom. To check on a future run:

```sh
free -m
du -sh /home/kodi/.kodi/*
ls -lh /var/log/kodi-scanner/
```

### No watchdog, deliberately

There is no timeout anywhere. If a scan wedges, the container stays up with its
log intact, which is the state worth inspecting, and a watchdog would destroy
exactly that. A wedge is visible as "the library stopped updating", since the
next `pct start` is a no-op against an already-running container.

To look at a running or hung scan:

```sh
pct enter 900
tail -f /var/log/kodi-scanner/temp/kodi.log
```

At `loglevel 1` the scraper floods the log with `enable_tag_whitelist ... was
not found` warnings, two lines per item, which drown out the progress. That is
harmless noise: Kodi updates the TMDB scraper from the repo on startup, and the
newer version asks for settings the saved ones do not have. Filter it out:

```sh
tail -f /var/log/kodi-scanner/temp/kodi.log | grep -E "Scanning dir|Rescanning dir|Finished scan"
```

## Keeping the config in step

`sources.xml` must render **byte-identically** on the scanner and the streamer.
Kodi stores the source path in the library's `path` table, so a URL differing
by a trailing slash is a different source, and you get every title twice in one
library.

The streamer's templates live inside `omega/patches/0002-*.patch`; the
scanner's are in `scanner/userdata/`. Two copies of something that must stay
identical will drift, so:

```sh
./scanner/check-templates.sh
```

compares them and fails on any difference in `sources.xml.in`, or in the
database blocks of `advancedsettings.xml.in`. Run it after touching either
side.

## Only one machine should scan

Not a preference, an architecture constraint. Kodi decides whether a directory
changed by comparing an MD5 stored in the shared `path.strHash`, and
`CVideoInfoScanner::GetPathHash` builds it from raw memory:

```cpp
digest.Update(pItem->GetPath());
digest.Update(&pItem->m_dwSize, sizeof(pItem->m_dwSize));
time_t tt{};
pItem->m_dateTime.GetAsTime(tt);
digest.Update(&tt, sizeof(tt));
```

Note `sizeof(tt)`. `time_t` is 4 bytes on 32-bit Android and 8 on x86_64 Linux,
so the streamer (armv7a) and this scanner (x86_64) feed a different number of
bytes into the digest and produce **different hashes for identical
directories**. Kodi has already papered over neighbouring versions of this
problem, with comments about forcing sort order and dropping milliseconds "to
avoid hash mismatch between platforms", but not this one.

The consequence: if both machines scan, each run invalidates every hash for the
other, and both do a full walk every time, forever. With only the scanner
scanning, its hashes are self-consistent and subsequent runs skip everything
unchanged.

So leave `videolibrary.updateonstartup` off on the streamer and any other
client. It defaults to off, so this is a thing to verify rather than configure.
Nothing breaks if a client does scan once: it costs the next scanner run a full
walk, no more than that.

## Status

Runs end-to-end. Provisioned on an Alpine 3.24 container, connects to
`MyVideos131` without creating a second database, and works through the source
tree at roughly five directories per second once a listing is in.

The first run walks everything, because the scanner starts with no path hashes
of its own. Expect the WebDAV directory listings to dominate: measured between
16 seconds and 3.5 minutes per folder depending on size, against ~200ms per
title once a listing arrives.
