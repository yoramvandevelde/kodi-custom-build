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
  --cores 4 --memory 4096 --swap 0 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --onboot 0 \
  --unprivileged 1
```

Memory matters more than cores: the profile is a tmpfs (see below) and a full
scan of a library this size holds a fair amount in flight.

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

`provision.sh` installs Kodi and Xvfb, renders the userdata templates, stages
the service addon, and hooks `scan-wrapper.sh` into boot via OpenRC's
`local.d`. It writes the rendered config to `/etc/kodi-scanner/` with mode 600,
since it contains the database password and the WebDAV credentials.

The checkout is only needed for provisioning. Nothing reads from it at runtime.

## Scheduling

On the Proxmox host, one line:

```cron
0 4 * * *  /usr/sbin/pct start 900
```

That is the entire external interface. Everything else (scan, clean, shut
down) happens inside.

## What happens on boot

```
pct start 900
  └─ OpenRC local.d → scan-wrapper.sh
       ├─ mount tmpfs at ~/.kodi, copy config + addon in
       ├─ start Xvfb, wait for it to accept connections
       ├─ start kodi --standalone
       │    └─ service.kodi.scanner:
       │         UpdateLibrary(video) → wait onScanFinished
       │         CleanLibrary(video)  → wait onCleanFinished
       │         Quit
       ├─ copy kodi.log to /var/log/kodi-scanner/
       └─ poweroff
```

### Why a service addon instead of JSON-RPC

The obvious approach is to enable Kodi's webserver, POST `VideoLibrary.Scan`,
and poll `Library.IsScanningVideo` until it goes false. That needs the
webserver turned on, which is a Kodi *setting* rather than something
`advancedsettings.xml` can do, so it means pre-baking `guisettings.xml`. It
also has a race: the first poll can read "not scanning" before the scan has
begun.

A service addon has neither problem. It starts automatically, needs no open
port, and registers its Monitor before triggering the scan, so the finished
notification cannot be missed however fast the scan runs.

### Why the profile is on tmpfs

Not primarily for the log. Once a library exists, Kodi caches artwork for
whatever the GUI displays, and Estuary's home screen widgets start pulling
images as soon as the skin loads, without anyone navigating anywhere. Artwork
caches are per-instance and never shared, so on a container that is discarded
after every run that is thousands of images written and then binned, nightly.

This is **not** fixable with `<videolibrary><artworkLevel>`: that controls
which artwork URLs are written to the library, and the library is shared, so
turning it down here would starve the streamer of artwork too. Keeping the
whole profile in RAM sidesteps it without touching what gets stored.

The log is copied out to `/var/log/kodi-scanner/` before poweroff, so a crashed
run still leaves something to read. Kept for a fortnight.

### No watchdog, deliberately

There is no timeout anywhere. If a scan wedges, the container stays up with its
log intact, which is the state worth inspecting, and a watchdog would destroy
exactly that. A wedge is visible as "the library stopped updating", since the
next `pct start` is a no-op against an already-running container.

To look at a running or hung scan:

```sh
pct enter 900
tail -f /home/kodi/.kodi/temp/kodi.log
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

## Status

Written but **not yet run end-to-end.** No container has been provisioned with
it. Expect to fix things on the first real run, particularly around whether
Kodi auto-enables a service addon dropped into a fresh profile, which is the
step most likely to need a nudge.
