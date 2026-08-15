#!/usr/bin/env bash
set -euo pipefail

RAMDIR="/mnt/buildram"
BACKUPDIR="/home/yoram/build-cache-backup"

if ! mountpoint -q "$RAMDIR"; then
  echo "FOUT: $RAMDIR is geen actief mountpoint (tmpfs niet gemount?). Niks te saven, stoppen." >&2
  exit 1
fi

# Sanity check: waak tegen het (weer) wegschrijven van een kapotte/lege
# native-tools prefix (zoals eerder gebeurde — 41k 0-byte bestanden in de backup).
SANITY_BINS=(
  "$RAMDIR/xbmc-depends/x86_64-linux-gnu-native/bin/cmake"
  "$RAMDIR/xbmc-depends/x86_64-linux-gnu-native/bin/ninja"
  "$RAMDIR/xbmc-depends/x86_64-linux-gnu-native/bin/python3.14"
)
for bin in "${SANITY_BINS[@]}"; do
  if [ -e "$bin" ] && [ ! -s "$bin" ]; then
    echo "FOUT: $bin is 0 bytes — native-tools prefix lijkt kapot/leeg. Niet saven om corruptie niet te bestendigen. Los eerst op, of verwijder deze check bewust als je zeker weet dat het klopt." >&2
    exit 1
  fi
done

mkdir -p "$BACKUPDIR"

echo "Sync $RAMDIR -> $BACKUPDIR ..."
rsync -a --delete --info=progress2 "$RAMDIR"/ "$BACKUPDIR"/

echo "Chown $BACKUPDIR -> yoram:yoram ..."
chown -R yoram:yoram "$BACKUPDIR"

echo "Klaar. Backup-grootte:"
du -sh "$BACKUPDIR"
