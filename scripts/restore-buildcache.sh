#!/usr/bin/env bash
# Mount de tmpfs build-cache en zet er de checkpoint van EEN target in.
#
# Usage: ./scripts/restore-buildcache.sh {omega|master}
#
# De ramdisk houdt bewust maar een target tegelijk: twee complete
# depends+source+build trees passen niet comfortabel in 35G, en je bouwt er
# toch nooit twee tegelijk. Wisselen gaat dus via:
#   ./scripts/save-buildcache.sh master     # huidige staat wegschrijven
#   ./scripts/restore-buildcache.sh omega   # andere target terugzetten
set -euo pipefail

TARGET="${1:-}"
case "$TARGET" in
  omega|master) ;;
  ""|-h|--help)
    echo "Usage: $0 {omega|master}" >&2
    exit 1
    ;;
  *)
    echo "Onbekend target '$TARGET' (verwacht 'omega' of 'master')." >&2
    exit 1
    ;;
esac

RAMDIR="/mnt/buildram"
BACKUPDIR="/home/yoram/build-cache-backup-$TARGET"
RAMSIZE="35G"

mkdir -p "$RAMDIR"

if ! mountpoint -q "$RAMDIR"; then
  echo "Mount tmpfs op $RAMDIR (size=$RAMSIZE) ..."
  mount -t tmpfs -o size="$RAMSIZE" tmpfs "$RAMDIR"
else
  echo "$RAMDIR is al gemount, hergebruik bestaande tmpfs."
fi

# Waarschuw als er nog een ANDER target in de ramdisk staat dat niet gesaved
# is. Zonder deze check overschrijft de rsync hieronder die staat zonder iets
# te zeggen, en ben je stilzwijgend een halve depends-build kwijt.
STAMP="$RAMDIR/.buildcache-target"
if [ -f "$STAMP" ]; then
  CURRENT="$(cat "$STAMP")"
  if [ "$CURRENT" != "$TARGET" ]; then
    echo "LET OP: in $RAMDIR staat nu target '$CURRENT', je restoret '$TARGET'." >&2
    echo "        De rsync hieronder gooit '$CURRENT' weg. Als je die staat nog" >&2
    echo "        wilt houden, breek af (Ctrl-C) en draai eerst:" >&2
    echo "          ./scripts/save-buildcache.sh $CURRENT" >&2
    echo >&2
    read -r -p "Doorgaan en '$CURRENT' overschrijven? [y/N] " answer
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Afgebroken."; exit 1 ;;
    esac
  fi
fi

if [ -d "$BACKUPDIR" ] && [ -n "$(ls -A "$BACKUPDIR" 2>/dev/null)" ]; then
  echo "Sync $BACKUPDIR -> $RAMDIR ..."
  rsync -a --delete --info=progress2 "$BACKUPDIR"/ "$RAMDIR"/
else
  echo "Geen backup gevonden in $BACKUPDIR -- lege tmpfs klaar voor een verse $TARGET build."
  # Alleen bij een verse start leegmaken: anders zou een restore van target A
  # de resten van target B laten staan en die stilletjes mee de build in nemen.
  find "$RAMDIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

echo "$TARGET" > "$STAMP"

echo "Chown $RAMDIR -> yoram:yoram ..."
chown -R yoram:yoram "$RAMDIR"

echo "Klaar ($TARGET). RAM-gebruik:"
df -h "$RAMDIR"
