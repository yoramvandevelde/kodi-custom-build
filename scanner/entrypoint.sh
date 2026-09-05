#!/bin/sh
# One library pass, then exit. 0 once a scan finished, 1 if Kodi went away
# without finishing one.
#
# No timeout and no watchdog, deliberately. A wedged scan should stay up with
# its log in place, which is the state worth inspecting, and force-killing
# during a library write is not obviously safer. Only one scanner runs at a
# time (see README), so a wedge shows as "the library stopped updating".
set -eu

KODI_HOME="${HOME:-/home/kodi}"
PROFILE="$KODI_HOME/.kodi"
TEMPLATE_DIR="/usr/share/kodi-scanner"
LOG_DIR="/var/log/kodi-scanner"
DISPLAY_NUM=":99"

# --- Config values ----------------------------------------------------------
for var in KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS KODI_WEBDAV_SOURCE_URL; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "$var is not set." >&2
    echo "This scanner exists to update the shared MySQL library; without this" >&2
    echo "value it would build its own. Set all five KODI_* variables." >&2
    exit 1
  fi
done

# --- Profile ----------------------------------------------------------------
# Nothing here needs to survive: the library is in MySQL and the artwork cache
# (Textures13.db + Thumbnails/) is per-instance. Mount RAM here (emptyDir with
# medium: Memory, or --tmpfs) so it is not written to disk to be binned; it
# runs without one.
#
# The artwork is what makes that worth doing: the home screen widgets start
# caching images as soon as the skin loads, with nobody navigating. Do not fix
# that with <videolibrary><artworkLevel>, which controls what is written to the
# shared library and would starve the streamer too.
echo "==> Preparing profile at $PROFILE"
mkdir -p "$PROFILE/userdata" "$LOG_DIR/temp"

# Log to disk, everything else to RAM. The log is the only diagnostic available.
ln -sfn "$LOG_DIR/temp" "$PROFILE/temp"

# --- Render the userdata templates ------------------------------------------
# CMake's @VAR@ placeholder style, because these are the same templates the APK
# build feeds through configure_file(). Both sides must stay byte-identical for
# sources.xml: Kodi stores the source path in the `path` table, so a URL that
# differs by a slash is a second source and every title appears twice.
# scanner/check-templates.sh guards that.
#
# Rendered at start, not baked in, so credentials live in the environment
# rather than an image layer.
echo "==> Rendering userdata"

# sed's replacement text treats \ and & specially, and a password contains
# whatever it contains.
escape() {
  printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

render() {
  sed \
    -e "s|@KODI_DB_HOST@|$(escape "$KODI_DB_HOST")|g" \
    -e "s|@KODI_DB_PORT@|$(escape "$KODI_DB_PORT")|g" \
    -e "s|@KODI_DB_USER@|$(escape "$KODI_DB_USER")|g" \
    -e "s|@KODI_DB_PASS@|$(escape "$KODI_DB_PASS")|g" \
    -e "s|@KODI_WEBDAV_SOURCE_URL@|$(escape "$KODI_WEBDAV_SOURCE_URL")|g" \
    "$1" > "$2"
}

render "$TEMPLATE_DIR/advancedsettings.xml.in" "$PROFILE/userdata/advancedsettings.xml"
render "$TEMPLATE_DIR/sources.xml.in"          "$PROFILE/userdata/sources.xml"
# No placeholders in this one, but it belongs to the same throwaway profile.
cp "$TEMPLATE_DIR/guisettings.xml" "$PROFILE/userdata/guisettings.xml"

# --- Scan progress on stdout ------------------------------------------------
# kodi.log at loglevel 1 runs to hundreds of MB per scan, too much for a cluster
# log pipeline, so the full log goes to the volume and only the progress lines
# to stdout.
#
# awk, not grep: busybox grep has no --line-buffered, and output in 4K blocks is
# not progress. tail -F because Kodi creates kodi.log later. Killing the awk end
# leaves tail to die of SIGPIPE, which is fine by then.
tail -n0 -F "$LOG_DIR/temp/kodi.log" 2>/dev/null \
  | awk '/enable_tag_whitelist/ { next }
         /Scanning dir|Rescanning dir|Finished scan|ERROR/ { print; fflush() }' &
TAIL_PID=$!

# --- Virtual display --------------------------------------------------------
# Kodi has no headless windowing platform, so it needs a display nobody looks at.
echo "==> Starting Xvfb on $DISPLAY_NUM"
Xvfb "$DISPLAY_NUM" -screen 0 1024x768x16 -nolisten tcp &
XVFB_PID=$!

# Wait for the display rather than sleeping: Kodi exits immediately if it starts
# before Xvfb accepts connections.
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
# guisettings.xml has videolibrary.updateonstartup, so Kodi starts scanning by
# itself. All that is left is noticing when it is done, which it logs at
# LOGINFO, so it appears even at loglevel 0:
#
#   VideoInfoScanner: Finished scan. Scanning for video info took N ms
#
# Nothing cleans here. <cleanonupdate> was removed and must stay removed.
# 
# /usr/bin/kodi is a shell wrapper around kodi-x11 and does not exec it, so the
# pid this shell has is the wrapper's. setsid puts the pair in their own process
# group, which is what gets signalled. Signalling every process owned by the
# kodi user is not an option: this script runs as that user and will suicide.
echo "==> Starting kodi"
export DISPLAY="$DISPLAY_NUM"
if command -v setsid >/dev/null 2>&1; then
  setsid kodi --standalone &
  KODI_PID=$!
  KODI_TARGET="-$KODI_PID"
else
  kodi --standalone &
  KODI_PID=$!
  KODI_TARGET="$KODI_PID"
fi

# Poll rather than tail: a tail started here could miss the line if the scan
# finished first, and re-reading every 30s is cheap next to the scan.
echo "==> Waiting for the scan to finish"
status=0
while :; do
  if grep -q "VideoInfoScanner: Finished scan" "$LOG_DIR/temp/kodi.log" 2>/dev/null; then
    echo "==> Scan finished"
    break
  fi
  # Gone without logging that line: it crashed or never started. Exiting with a
  # preserved log beats hanging here.
  if ! kill -0 "$KODI_PID" 2>/dev/null; then
    echo "kodi exited before finishing a scan" >&2
    status=1
    break
  fi
  sleep 30
done

# SIGTERM, not SIGKILL: Kodi closes its databases and flushes the log on a clean
# shutdown.
if [ "$status" -eq 0 ]; then
  echo "==> Stopping kodi"
  kill -TERM "$KODI_TARGET" 2>/dev/null || true
fi
# Wait on the kodi job specifically: Xvfb and the log tail are background jobs of
# this shell too, so a bare `wait` would block until those exit.
wait "$KODI_PID" 2>/dev/null || true

kill "$XVFB_PID" 2>/dev/null || true
kill "$TAIL_PID" 2>/dev/null || true

# --- Keep the log ------------------------------------------------------------
# Already on the log volume, so nothing to rescue. Moved aside under a timestamp
# because Kodi keeps only one previous run (kodi.log plus kodi.old.log) and
# would overwrite it tomorrow night.
if [ -f "$LOG_DIR/temp/kodi.log" ]; then
  mv "$LOG_DIR/temp/kodi.log" "$LOG_DIR/kodi-$(date +%Y%m%d-%H%M%S).log"
  # Keep a fortnight; debug logs of a full library scan are not small.
  find "$LOG_DIR" -maxdepth 1 -name 'kodi-*.log' -mtime +14 -delete 2>/dev/null || true
fi

echo "==> Done (exit $status)"
exit "$status"
