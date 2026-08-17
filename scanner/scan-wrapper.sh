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
DISPLAY_NUM=":99"
LOG_DIR="/var/log/kodi-scanner"

# --- Fresh tmpfs profile on every boot -------------------------------------
# Nothing the profile holds needs to survive: the library lives in the shared
# MySQL database, and the artwork cache (Textures13.db + Thumbnails/) is
# per-instance and never reused, since this container is discarded after each
# run. Keeping it in RAM avoids writing it only to bin it, and guarantees each
# run starts from a known-clean state.
#
# The artwork is what makes that worth doing. Kodi caches images for whatever
# the GUI shows, and the home screen widgets start pulling them as soon as the
# skin loads, with nobody navigating anywhere. Worth knowing: that is NOT
# something to fix with <videolibrary><artworkLevel>, which controls what gets
# written to the library. The library is shared, so turning it down here would
# starve the streamer of artwork too.
#
# The log does not live here; see the symlink below. Without it, what remains is
# small (userdata and tens of MB of cached images), hence 256M in a container
# with a gigabyte to its name.
#
# size= is a limit, not a reservation, so it costs nothing until written to. If
# it does fill, writes fail with ENOSPC and stop there rather than growing into
# the container's memory, and the scan is unaffected regardless since that
# writes to MySQL over the network.
echo "==> Mounting tmpfs profile at $KODI_HOME/.kodi"
mkdir -p "$KODI_HOME/.kodi"
mountpoint -q "$KODI_HOME/.kodi" || mount -t tmpfs -o size=256M tmpfs "$KODI_HOME/.kodi"

mkdir -p "$KODI_HOME/.kodi/userdata"

# Log to disk, everything else to RAM. The two things filling this profile want
# opposite treatment: cached artwork is worth throwing away every run, while the
# debug log is the only diagnostic this box has and is worth keeping. The log is
# also by far the larger of the two -- hundreds of MB for a full scan -- so
# leaving it in the tmpfs would mean sizing that tmpfs around the thing we
# actually want to persist, in a container with a gigabyte to its name.
#
# A symlink rather than a bind mount: one less mount to depend on working
# inside an unprivileged container, and Kodi does not care.
mkdir -p "$LOG_DIR/temp"
chown -R "$KODI_USER:$KODI_USER" "$LOG_DIR"
ln -sfn "$LOG_DIR/temp" "$KODI_HOME/.kodi/temp"

cp "$CONFIG_DIR/advancedsettings.xml" "$KODI_HOME/.kodi/userdata/"
cp "$CONFIG_DIR/sources.xml"          "$KODI_HOME/.kodi/userdata/"
cp "$CONFIG_DIR/guisettings.xml"      "$KODI_HOME/.kodi/userdata/"

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
# guisettings.xml has videolibrary.updateonstartup, so Kodi begins scanning by
# itself; nothing needs to tell it to start. What is left is noticing when it
# has finished, and Kodi says so on one line:
#
#   VideoInfoScanner: Finished scan. Scanning for video info took N ms
#
# That is LOGINFO, so it appears even at loglevel 0, and it is logged *after*
# the cleanup pass that <cleanonupdate> adds (see VideoInfoScanner::Process,
# where CleanDatabase runs before this line). One signal covers both.
echo "==> Starting kodi"
su -s /bin/sh "$KODI_USER" -c "DISPLAY=$DISPLAY_NUM HOME=$KODI_HOME kodi --standalone" &
KODI_JOB=$!

# Poll the file rather than following it with tail: a tail started here could
# miss the line if the scan somehow finished first, and re-reading the log every
# half minute is cheap next to the scan itself.
echo "==> Waiting for the scan to finish"
while :; do
  if grep -q "VideoInfoScanner: Finished scan" "$LOG_DIR/temp/kodi.log" 2>/dev/null; then
    echo "==> Scan finished"
    break
  fi
  # If Kodi is gone without ever logging that line, stop waiting: it crashed,
  # or failed to start. Powering off with a preserved log beats hanging here.
  if ! pgrep -u "$KODI_USER" >/dev/null 2>&1; then
    echo "kodi exited before finishing a scan" >&2
    break
  fi
  sleep 30
done

# SIGTERM rather than SIGKILL: Kodi closes its databases and flushes the log on
# a clean shutdown, and by this point the library work is already committed.
# /usr/bin/kodi is a shell wrapper around kodi-x11, so signal the user's whole
# process group instead of the pid of that wrapper.
echo "==> Stopping kodi"
pkill -TERM -u "$KODI_USER" 2>/dev/null || true
# Wait on the kodi job specifically, not a bare `wait`: Xvfb is also a
# background job of this shell and is still running, so waiting on everything
# would block here until it exits.
wait "$KODI_JOB" 2>/dev/null || true

kill "$XVFB_PID" 2>/dev/null || true

# --- Keep the log ------------------------------------------------------------
# Already on disk, so nothing to rescue before poweroff -- a crash keeps its log
# for free. Just move it aside under a timestamp, because Kodi only keeps one
# previous run (kodi.log plus kodi.old.log) and would otherwise overwrite it
# tomorrow night. A rename, so it costs nothing.
if [ -f "$LOG_DIR/temp/kodi.log" ]; then
  mv "$LOG_DIR/temp/kodi.log" "$LOG_DIR/kodi-$(date +%Y%m%d-%H%M%S).log"
  # Keep a fortnight; debug logs of a full library scan are not small.
  find "$LOG_DIR" -maxdepth 1 -name 'kodi-*.log' -mtime +14 -delete 2>/dev/null || true
fi

echo "==> Powering off"
poweroff
