# The nightly library scanner: stock Alpine Kodi, one scan pass, then exit.
#
# The base image tag IS the version pin. alpine:3.24 carries kodi 21.3, the same
# release the streamer's APK is built from, and only 21.x speaks library schema
# MyVideos131. Bump it in step with rebuilding the streamer; the check below
# makes a mistake fail the build.
FROM alpine:3.24

# The entrypoint uses xdpyinfo to wait for Xvfb to accept connections instead of
# sleeping: Kodi exits immediately if it starts before the display is up.
RUN apk add --no-cache kodi xvfb xdpyinfo

# Refuse to build anything but 21.x.
#
# Kodi compiles its library schema into the binary and names the database after
# it. A mismatch does not error: Kodi copies the nearest older database and
# migrates the copy, forking the library.
#
#   20.x -> MyVideos121, a separate library
#   21.x -> MyVideos131, correct, what the streamer uses
#   22.x -> MyVideos148, migrates 131 and strands every device still on 21
#
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

# Kodi will not start without an audio sink: the audio engine retries opening
# but does nothing more, so a device that discards everything is enough.
RUN printf '%s\n' \
      'pcm.!default { type null }' \
      'ctl.!default { type null }' \
      > /etc/asound.conf

RUN adduser -D -u 1000 -h /home/kodi kodi \
    && mkdir -p /var/log/kodi-scanner \
    && chown kodi:kodi /var/log/kodi-scanner

# Templates, not rendered config: resolved at start from env vars, so no
# password or WebDAV URL lands in an image layer.
COPY userdata/advancedsettings.xml.in userdata/sources.xml.in \
     userdata/guisettings.xml /usr/share/kodi-scanner/
COPY entrypoint.sh /usr/local/bin/kodi-scan

USER kodi
ENV HOME=/home/kodi
WORKDIR /home/kodi

ENTRYPOINT ["/usr/local/bin/kodi-scan"]
