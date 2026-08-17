#!/bin/sh
# Turn a fresh Alpine container into the library scanner.
#
# Run this INSIDE the container, once, after creating it (see README.md for the
# pct create side). It installs Kodi, renders the userdata templates from the
# same env vars the APK builds use, drops the service addon in place, and wires
# scan-wrapper.sh into boot.
#
# Re-running is safe: everything here overwrites rather than appends.
set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="/etc/kodi-scanner"
KODI_USER="kodi"
KODI_HOME="/home/$KODI_USER"
ADDON_ID="service.kodi.scanner"

# --- Config values ----------------------------------------------------------
# Same variables, same values, same meaning as the APK builds: this scanner and
# the streamer have to point at one library, not two. Source scripts/kodi-env.sh
# before running this, or pass them on the command line.
for var in KODI_DB_HOST KODI_DB_PORT KODI_DB_USER KODI_DB_PASS KODI_WEBDAV_SOURCE_URL; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "$var is not set." >&2
    echo "This scanner exists to update the shared MySQL library, so an unset" >&2
    echo "value would give you a container quietly building its own separate" >&2
    echo "library instead. Source scripts/kodi-env.sh first." >&2
    exit 1
  fi
done

# --- Packages ---------------------------------------------------------------
# xdpyinfo (xdpyinfo is in xorg-server-utils on Alpine) is used by the wrapper
# to wait for Xvfb rather than sleeping a guessed interval.
echo "==> Installing packages"
apk add --no-cache kodi xvfb xdpyinfo

# Pin the release. Kodi's library schema is compiled into the binary and the
# database is named after it (MyVideos131 for the whole 21.x line). When Alpine
# ships Kodi 22, an unpinned upgrade would connect, find no MyVideos148, copy
# 131 into it and migrate the copy, forking the library away from every device
# still on 21.x. Nothing errors; the libraries just stop being the same one.
echo "==> Current kodi version (must be 21.x for schema 131):"
apk info -d kodi | head -2
case "$(apk info -d kodi 2>/dev/null | head -1)" in
  *kodi-21.*) ;;
  *)
    echo >&2
    echo "REFUSING TO CONTINUE: the kodi package is not 21.x." >&2
    echo "Only Kodi 21 speaks library schema MyVideos131, which is what the" >&2
    echo "streamer and the existing library use. A 20.x would build a separate" >&2
    echo "library; a 22.x would migrate yours to 148 and strand the streamer." >&2
    echo "Pin /etc/apk/repositories to an Alpine release carrying 21.x." >&2
    exit 1
    ;;
esac

# --- User -------------------------------------------------------------------
# Kodi refuses to be run as root, and a dedicated user also keeps the tmpfs
# profile ownership simple.
if ! id "$KODI_USER" >/dev/null 2>&1; then
  echo "==> Creating $KODI_USER user"
  adduser -D -h "$KODI_HOME" "$KODI_USER"
fi

# --- Render the userdata templates ------------------------------------------
# The templates use CMake's @VAR@ placeholder style because they are the same
# templates the APK build feeds through configure_file(). Substituting them
# here by hand keeps both sides byte-identical, which matters most for
# sources.xml: Kodi stores the source path in the `path` table, so a URL that
# differs by a slash is a different source and you get duplicate entries in the
# one library. scanner/check-templates.sh guards that.
echo "==> Rendering userdata into $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

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

render "$SELF_DIR/userdata/advancedsettings.xml.in" "$CONFIG_DIR/advancedsettings.xml"
render "$SELF_DIR/userdata/sources.xml.in"          "$CONFIG_DIR/sources.xml"

# Contains the database password and the webdav URL with its credentials.
chmod 600 "$CONFIG_DIR/advancedsettings.xml" "$CONFIG_DIR/sources.xml"

# --- Addon ------------------------------------------------------------------
# Staged here rather than installed into ~/.kodi directly: that profile is a
# tmpfs created fresh on every boot, so the wrapper copies this in each time.
echo "==> Staging $ADDON_ID"
rm -rf "$CONFIG_DIR/addon"
mkdir -p "$CONFIG_DIR/addon"
cp -r "$SELF_DIR/addon/$ADDON_ID" "$CONFIG_DIR/addon/"

# --- Boot hook --------------------------------------------------------------
echo "==> Installing boot hook"
install -m 755 "$SELF_DIR/scan-wrapper.sh" /usr/local/bin/kodi-scan
cat > /etc/local.d/kodi-scanner.start <<'EOF'
#!/bin/sh
exec /usr/local/bin/kodi-scan
EOF
chmod 755 /etc/local.d/kodi-scanner.start
rc-update add local default

echo
echo "==> Done."
echo "    The next boot of this container will scan the library and power off."
echo "    Trigger it from the Proxmox host with: pct start <ID>"
echo "    Logs are kept in /var/log/kodi-scanner/."
