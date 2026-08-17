#!/usr/bin/env bash
# Verify the scanner's userdata templates still match the streamer's.
#
# The streamer's templates live inside omega/patches/0002-*.patch (they are
# added by that patch, so they only exist in a patched checkout), and the
# scanner keeps its own copies under scanner/userdata/. Two copies of something
# that has to stay identical will drift eventually, hence this check.
#
# It matters most for sources.xml. Kodi records the source path in the `path`
# table of the shared library, so if the two sides render even slightly
# different URLs -- a trailing slash, a different credential form -- Kodi treats
# them as two separate sources and you end up with every title twice in one
# library. advancedsettings.xml is checked for the database block only: the
# scanner deliberately adds settings the streamer has no use for.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
PATCH=$(ls "$REPO_DIR"/omega/patches/0002-*.patch 2>/dev/null | head -1)

if [ -z "$PATCH" ]; then
  echo "No omega/patches/0002-*.patch found; nothing to compare against." >&2
  exit 1
fi

# Pull a file's post-patch content out of the patch. These files are added by
# the patch, so every content line is an addition and this is exact rather than
# a heuristic.
extract() {
  sed -n "\|diff --git a/$1|,/^diff --git/p" "$PATCH" \
    | sed -n '/^+++/,$p' | grep '^+' | grep -v '^+++' | sed 's/^+//'
}

status=0

echo "==> sources.xml.in"
if diff -u <(extract "userdata/sources.xml.in") "$SELF_DIR/userdata/sources.xml.in" \
     --label "omega/patches (streamer)" --label "scanner/userdata"; then
  echo "    OK, identical"
else
  echo "    DRIFT: the scanner would seed a different source than the streamer," >&2
  echo "    which means duplicate paths in the shared library." >&2
  status=1
fi

echo
echo "==> advancedsettings.xml.in (database blocks only)"
db_block() {
  sed -n '/<videodatabase>/,/<\/musicdatabase>/p' | sed 's/^[[:space:]]*//'
}
if diff -u <(extract "userdata/advancedsettings.xml.in" | db_block) \
           <(db_block < "$SELF_DIR/userdata/advancedsettings.xml.in") \
     --label "omega/patches (streamer)" --label "scanner/userdata"; then
  echo "    OK, identical"
else
  echo "    DRIFT: the two would connect to different databases." >&2
  status=1
fi

exit $status
