#!/bin/sh
# One library pass, then power the container off.
#
# Run at boot by OpenRC via /etc/local.d/kodi-scanner.start. The whole
# container exists for the duration of this script: Proxmox starts it, this
# runs, the container stops itself.
#
# Deliberately no timeout or watchdog. If Kodi wedges mid-scan the container
# stays up with its log in place, which is the state worth inspecting; a
# watchdog would destroy that evidence and force-killing during a library
# write is not obviously safer than leaving it hung. A hung container also
# means the next `pct start` is a no-op on an already-running container, so a
# wedge shows up as "the library stopped updating" rather than silently
# retrying forever.
set -eu

KODI_USER="kodi"
KODI_HOME="/home/$KODI_USER"
CONFIG_DIR="/etc/kodi-scanner"
ADDON_ID="service.kodi.scanner"
DISPLAY_NUM=":99"
LOG_KEEP_DIR="/var/log/kodi-scanner"

# --- Fresh tmpfs profile on every boot -------------------------------------
# Nothing inside ~/.kodi needs to survive: the library lives in the shared
# MySQL database, and the artwork cache (Textures13.db + Thumbnails/) is
# per-instance and never reused, since this container is discarded after each
# run. Keeping the profile in RAM avoids writing it only to bin it, and means
# each run starts from a known-clean state.
#
# Filled mainly by the debug log, secondarily by cached artwork: Kodi caches
# images for whatever the GUI shows, and the home screen widgets start pulling
# them as soon as the skin loads, with nobody navigating anywhere.
#
# Worth knowing: the artwork side is NOT something to fix with
# <videolibrary><artworkLevel>. That controls which artwork URLs get written to
# the library, and the library is shared, so turning it down here would starve
# the streamer of artwork too.
#
# size= is a limit, not a reservation. If it fills, writes fail with ENOSPC and
# stop there; it cannot grow into the container's memory. The scan is unaffected
# either way, since that writes to MySQL over the network, so a full tmpfs costs
# log fidelity rather than data.
echo "==> Mounting tmpfs profile at $KODI_HOME/.kodi"
mkdir -p "$KODI_HOME/.kodi"
mountpoint -q "$KODI_HOME/.kodi" || mount -t tmpfs -o size=2G tmpfs "$KODI_HOME/.kodi"

mkdir -p "$KODI_HOME/.kodi/userdata" \
         "$KODI_HOME/.kodi/addons/$ADDON_ID" \
         "$KODI_HOME/.kodi/temp"

cp "$CONFIG_DIR/advancedsettings.xml" "$KODI_HOME/.kodi/userdata/"
cp "$CONFIG_DIR/sources.xml"          "$KODI_HOME/.kodi/userdata/"
cp -r "$CONFIG_DIR/addon/$ADDON_ID/." "$KODI_HOME/.kodi/addons/$ADDON_ID/"

chown -R "$KODI_USER:$KODI_USER" "$KODI_HOME/.kodi"

# --- Virtual display --------------------------------------------------------
# Kodi has no headless/null windowing platform, so it needs a display even
# though nothing is ever meant to look at it.
echo "==> Starting Xvfb on $DISPLAY_NUM"
Xvfb "$DISPLAY_NUM" -screen 0 1024x768x16 -nolisten tcp &
XVFB_PID=$!

# Wait for the display to accept connections rather than sleeping a guessed
# number of seconds: Kodi exits immediately if it starts first.
tries=0
until DISPLAY="$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -gt 30 ]; then
    echo "Xvfb did not come up on $DISPLAY_NUM" >&2
    exit 1
  fi
  sleep 1
done

# --- The actual run ---------------------------------------------------------
# Blocks until service.py has finished scanning and cleaning and called Quit.
echo "==> Starting kodi"
su -s /bin/sh "$KODI_USER" -c "DISPLAY=$DISPLAY_NUM HOME=$KODI_HOME kodi --standalone" || \
  echo "kodi exited non-zero ($?)" >&2

kill "$XVFB_PID" 2>/dev/null || true

# --- Keep the log ------------------------------------------------------------
# The profile is tmpfs, so the log dies with the poweroff below. Copy it out
# first: a crash still reaches this line, and a crashed run is exactly when the
# log is worth having. One sequential write, rather than the constant dribble
# of writing the log to disk as it is produced.
if [ -f "$KODI_HOME/.kodi/temp/kodi.log" ]; then
  mkdir -p "$LOG_KEEP_DIR"
  cp "$KODI_HOME/.kodi/temp/kodi.log" "$LOG_KEEP_DIR/kodi-$(date +%Y%m%d-%H%M%S).log"
  # Keep a fortnight; these are debug-level logs of a full library scan and
  # they are not small.
  find "$LOG_KEEP_DIR" -name 'kodi-*.log' -mtime +14 -delete 2>/dev/null || true
fi

echo "==> Powering off"
poweroff
