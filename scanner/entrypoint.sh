#!/bin/sh
# One library pass, then exit.
#
# The whole container exists for the duration of this script: something starts
# it (a Kubernetes Job, `docker run`), this runs, it exits. Where the Proxmox
# container that preceded this powered itself off, this exits: 0 once a scan has
# finished, 1 if Kodi went away without finishing one.
#
# Deliberately no timeout and no watchdog, same as before. If Kodi wedges
# mid-scan the container stays up with its log in place, which is the state
# worth inspecting; a watchdog would destroy that evidence, and force-killing
# during a library write is not obviously safer than leaving it hung. Only one
# scanner may run at a time anyway (see README), so a wedged run shows up as
# "the library stopped updating" rather than as silent retries.
set -eu

KODI_HOME="${HOME:-/home/kodi}"
PROFILE="$KODI_HOME/.kodi"
TEMPLATE_DIR="/usr/share/kodi-scanner"
LOG_DIR="/var/log/kodi-scanner"
DISPLAY_NUM=":99"

# --- Config values ----------------------------------------------------------
# Same variables, same values, same meaning as the APK builds: this scanner and
# the streamer have to point at one library, not two. An unset value would give
# you a container quietly building its own separate library instead, which is
# the one failure mode worth refusing to start over.
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
# Nothing in the profile needs to survive: the library lives in the shared MySQL
# database, and the artwork cache (Textures13.db + Thumbnails/) is per-instance
# and never reused, since the container is discarded after each run. Mount RAM
# here (an emptyDir with medium: Memory, or --tmpfs) so it is not written to
# disk only to be binned; it works without one, just less tidily.
#
# The artwork is what makes that worth doing. Kodi caches images for whatever
# the GUI shows, and the home screen widgets start pulling them as soon as the
# skin loads, with nobody navigating anywhere. Worth knowing: that is NOT
# something to fix with <videolibrary><artworkLevel>, which controls what gets
# written to the library. The library is shared, so turning it down here would
# starve the streamer of artwork too.
echo "==> Preparing profile at $PROFILE"
mkdir -p "$PROFILE/userdata" "$LOG_DIR/temp"

# Log to disk, everything else to RAM. The two things filling this profile want
# opposite treatment: cached artwork is worth throwing away every run, while the
# debug log is the only diagnostic this container has and is worth keeping. The
# log is also by far the larger of the two, hundreds of MB for a full scan, so
# leaving it in a RAM-backed profile would mean sizing that around the one thing
# we actually want to persist.
ln -sfn "$LOG_DIR/temp" "$PROFILE/temp"

# --- Render the userdata templates ------------------------------------------
# The templates use CMake's @VAR@ placeholder style because they are the same
# templates the APK build feeds through configure_file(). Substituting them here
# by hand keeps both sides byte-identical, which matters most for sources.xml:
# Kodi stores the source path in the `path` table, so a URL that differs by a
# slash is a different source and you get every title twice in the one library.
# scanner/check-templates.sh guards that.
#
# Rendered at start rather than baked into the image, so the credentials live in
# the container's environment (a Secret) instead of in an image layer.
echo "==> Rendering userdata"

# sed's replacement text treats \ and & specially, and passwords contain
# whatever they contain, so escape before substituting rather than hoping.
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
# kodi.log at loglevel 1 runs to hundreds of MB per full scan, which has no
# business going through a cluster log pipeline, but a run that prints nothing
# at all is not much of a run either. So: the full log to the log volume, and
# the handful of lines that say what it is doing to stdout.
#
# awk rather than grep because busybox grep has no --line-buffered, and output
# that arrives in 4K blocks is not progress. tail -F because kodi.log does not
# exist yet and Kodi creates it. Killing the awk end of the pipe later leaves
# tail to die of SIGPIPE on its next write, which is fine, the container is on
# its way out by then.
tail -n0 -F "$LOG_DIR/temp/kodi.log" 2>/dev/null \
  | awk '/enable_tag_whitelist/ { next }
         /Scanning dir|Rescanning dir|Finished scan|ERROR/ { print; fflush() }' &
TAIL_PID=$!

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
# That is LOGINFO, so it appears even at loglevel 0.
#
# Nothing cleans here. <cleanonupdate> used to be set and was removed: the clean
# deletes any path it cannot reach, and against WebDAV "cannot reach" includes
# "the connection stalled", which cost ~700 titles in one run, silently. See
# userdata/advancedsettings.xml.in.
#
# /usr/bin/kodi is a shell wrapper around kodi-x11 and does not exec it, so the
# pid this shell knows about is the wrapper's. setsid puts the pair in their own
# process group, which is then the thing to signal. Without setsid available,
# fall back to the wrapper's pid; the old approach of signalling every process
# owned by the kodi user is no longer an option, since this script runs as that
# user too and would kill itself.
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

# Poll the file rather than following it with tail: a tail started here could
# miss the line if the scan somehow finished first, and re-reading the log every
# half minute is cheap next to the scan itself.
echo "==> Waiting for the scan to finish"
status=0
while :; do
  if grep -q "VideoInfoScanner: Finished scan" "$LOG_DIR/temp/kodi.log" 2>/dev/null; then
    echo "==> Scan finished"
    break
  fi
  # If Kodi is gone without ever logging that line, stop waiting: it crashed, or
  # failed to start. Exiting with a preserved log beats hanging here.
  if ! kill -0 "$KODI_PID" 2>/dev/null; then
    echo "kodi exited before finishing a scan" >&2
    status=1
    break
  fi
  sleep 30
done

# SIGTERM rather than SIGKILL: Kodi closes its databases and flushes the log on
# a clean shutdown, and by this point the library work is already committed.
if [ "$status" -eq 0 ]; then
  echo "==> Stopping kodi"
  kill -TERM "$KODI_TARGET" 2>/dev/null || true
fi
# Wait on the kodi job specifically, not a bare `wait`: Xvfb and the log tail
# are background jobs of this shell too and are still running, so waiting on
# everything would block here until they exit.
wait "$KODI_PID" 2>/dev/null || true

kill "$XVFB_PID" 2>/dev/null || true
kill "$TAIL_PID" 2>/dev/null || true

# --- Keep the log ------------------------------------------------------------
# Already on the log volume, so nothing to rescue before exiting: a crash keeps
# its log for free. Just move it aside under a timestamp, because Kodi only
# keeps one previous run (kodi.log plus kodi.old.log) and would otherwise
# overwrite it tomorrow night. A rename, so it costs nothing.
if [ -f "$LOG_DIR/temp/kodi.log" ]; then
  mv "$LOG_DIR/temp/kodi.log" "$LOG_DIR/kodi-$(date +%Y%m%d-%H%M%S).log"
  # Keep a fortnight; debug logs of a full library scan are not small.
  find "$LOG_DIR" -maxdepth 1 -name 'kodi-*.log' -mtime +14 -delete 2>/dev/null || true
fi

echo "==> Done (exit $status)"
exit "$status"
