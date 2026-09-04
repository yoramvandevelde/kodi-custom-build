# The nightly library scanner: stock Alpine Kodi, one scan pass, then exit.
#
# The base image tag IS the version pin. alpine:3.24 carries kodi 21.3, the same
# release the streamer's APK is built from, and 21.x is the only line speaking
# library schema MyVideos131. Bumping this tag is a deliberate act, done in step
# with rebuilding the streamer, never a drive-by update. The assertion below
# makes a mistake here fail the build instead of quietly forking the library at
# four in the morning.
FROM alpine:3.24

# xdpyinfo lives in xorg-server-utils on Alpine. The entrypoint uses it to wait
# for Xvfb to accept connections rather than sleeping a guessed interval: Kodi
# exits immediately if it starts before the display is up.
RUN apk add --no-cache kodi xvfb xdpyinfo

# Refuse to build anything but 21.x.
#
# Kodi compiles its library schema into the binary and names the database after
# it. A mismatch does not error: Kodi copies the nearest older database into a
# new one and migrates the copy, silently forking the library in two.
#
#   20.x -> MyVideos121, a separate library
#   21.x -> MyVideos131, correct, what the streamer uses
#   22.x -> MyVideos148, migrates 131 and strands every device still on 21
#
# Read the version out of apk's installed database rather than off the CLI: apk
# 3 changed what `apk info -v` prints (it returns the package description now,
# which happily parses as "not 21.x" and fails the build for the wrong reason).
# The database format has not moved. `apk list -I` is the fallback, and an empty
# answer from both fails: a guard that silently passes is worse than no guard.
RUN set -eu; \
    version="$(sed -n '/^P:kodi$/,/^$/{ /^V:/{ s/^V://p; q; } }' \
               /lib/apk/db/installed 2>/dev/null || true)"; \
    if [ -z "$version" ]; then \
      version="$( { apk list -I kodi 2>/dev/null || true; } \
                  | sed -n 's/^kodi-\([0-9][^ ]*\).*/\1/p' | head -1)"; \
    fi; \
    echo "kodi package version: ${version:-<unknown>}"; \
    case "$version" in \
      21.*) ;; \
      *) \
        echo "REFUSING TO BUILD: the kodi package is not 21.x." >&2; \
        echo "Only Kodi 21 speaks library schema MyVideos131, which is what" >&2; \
        echo "the streamer and the existing library use. A 20.x would build a" >&2; \
        echo "separate library; a 22.x would migrate yours to 148 and strand" >&2; \
        echo "the streamer. Pin FROM to an Alpine release carrying 21.x." >&2; \
        exit 1; \
        ;; \
    esac

# Kodi will not start without an audio sink. Its audio engine retries opening
# one every 500ms, forever, and never finishes starting up, so nothing else
# runs, including the library scan. It presents as a log full of:
#
#   CActiveAESink::OpenSink - no sink was returned
#
# There is no sound hardware here and nothing plays audio, so a device that
# discards everything is exactly right.
RUN printf '%s\n' \
      'pcm.!default { type null }' \
      'ctl.!default { type null }' \
      > /etc/asound.conf

# Kodi refuses to run as root. A fixed uid, rather than whatever adduser picks,
# so the securityContext that mounts this container's volumes has a number to
# match (runAsUser/fsGroup 1000).
RUN adduser -D -u 1000 -h /home/kodi kodi \
    && mkdir -p /var/log/kodi-scanner \
    && chown kodi:kodi /var/log/kodi-scanner

# Templates, not rendered config: the placeholders are resolved at start from
# environment variables, so no database password or WebDAV URL ends up in an
# image layer.
COPY userdata/advancedsettings.xml.in userdata/sources.xml.in \
     userdata/guisettings.xml /usr/share/kodi-scanner/
COPY entrypoint.sh /usr/local/bin/kodi-scan

USER kodi
ENV HOME=/home/kodi
WORKDIR /home/kodi

ENTRYPOINT ["/usr/local/bin/kodi-scan"]
