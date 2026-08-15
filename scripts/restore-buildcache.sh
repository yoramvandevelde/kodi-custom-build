#!/usr/bin/env bash
set -euo pipefail

RAMDIR="/mnt/buildram"
BACKUPDIR="/home/yoram/build-cache-backup"
RAMSIZE="35G"

mkdir -p "$RAMDIR"

if ! mountpoint -q "$RAMDIR"; then
  echo "Mount tmpfs op $RAMDIR (size=$RAMSIZE) ..."
  mount -t tmpfs -o size="$RAMSIZE" tmpfs "$RAMDIR"
else
  echo "$RAMDIR is al gemount, hergebruik bestaande tmpfs."
fi

mkdir -p "$RAMDIR"/xbmc-depends "$RAMDIR"/kodi-build

if [ -d "$BACKUPDIR" ] && [ -n "$(ls -A "$BACKUPDIR" 2>/dev/null)" ]; then
  echo "Sync $BACKUPDIR -> $RAMDIR ..."
  rsync -a --delete --info=progress2 "$BACKUPDIR"/ "$RAMDIR"/
else
  echo "Geen backup gevonden in $BACKUPDIR — lege tmpfs klaar voor een verse build."
fi

echo "Chown $RAMDIR -> yoram:yoram ..."
chown -R yoram:yoram "$RAMDIR"

echo "Klaar. RAM-gebruik:"
df -h "$RAMDIR"
