#!/usr/bin/env bash
# Schrijf de huidige tmpfs build-cache weg naar de backup van EEN target.
#
# Usage: ./scripts/save-buildcache.sh [omega|master]
#
# Zonder argument wordt het target gelezen uit het stempelbestand dat
# restore-buildcache.sh achterlaat, zodat je niet per ongeluk de ene target
# over de backup van de andere heen schrijft.
set -euo pipefail

RAMDIR="/mnt/buildram"
STAMP="$RAMDIR/.buildcache-target"

if ! mountpoint -q "$RAMDIR"; then
  echo "FOUT: $RAMDIR is geen actief mountpoint (tmpfs niet gemount?). Niks te saven, stoppen." >&2
  exit 1
fi

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  if [ ! -f "$STAMP" ]; then
    echo "FOUT: geen target opgegeven en $STAMP ontbreekt, dus onbekend wat" >&2
    echo "hier in staat. Geef expliciet op: $0 {omega|master}" >&2
    exit 1
  fi
  TARGET="$(cat "$STAMP")"
  echo "Target uit $STAMP: $TARGET"
elif [ -f "$STAMP" ]; then
  # Expliciet opgegeven target dat niet matcht met wat er staat is bijna altijd
  # een vergissing, en wel een dure: je overschrijft de backup van het ene
  # target met de tree van het andere.
  CURRENT="$(cat "$STAMP")"
  if [ "$CURRENT" != "$TARGET" ]; then
    echo "FOUT: je saved naar '$TARGET', maar in $RAMDIR staat '$CURRENT'." >&2
    echo "Dat zou de backup van '$TARGET' overschrijven met de tree van" >&2
    echo "'$CURRENT'. Bedoelde je: $0 $CURRENT ?" >&2
    exit 1
  fi
fi

case "$TARGET" in
  omega|master) ;;
  *) echo "Onbekend target '$TARGET' (verwacht 'omega' of 'master')." >&2; exit 1 ;;
esac

BACKUPDIR="/home/yoram/build-cache-backup-$TARGET"

# Sanity check: waak tegen het (weer) wegschrijven van een kapotte/lege
# native-tools prefix (zoals eerder gebeurde -- 41k 0-byte bestanden in de
# backup). Bewust NIET op vaste versienummers getest: master en omega bouwen
# elk hun eigen python-versie in de native tools, dus een hardcoded
# python3.14 zou bij de ene target vals alarm slaan en bij de andere er juist
# langs glijden. In plaats daarvan: cmake/ninja moeten bestaan en niet leeg
# zijn, en nergens in de native bin-dir mag een 0-byte binary staan.
NATIVE_BIN="$RAMDIR/xbmc-depends/x86_64-linux-gnu-native/bin"
if [ -d "$NATIVE_BIN" ]; then
  for required in cmake ninja; do
    if [ ! -s "$NATIVE_BIN/$required" ]; then
      echo "FOUT: $NATIVE_BIN/$required ontbreekt of is 0 bytes -- native-tools" >&2
      echo "prefix lijkt kapot/leeg. Niet saven om corruptie niet te bestendigen." >&2
      exit 1
    fi
  done
  empty=$(find "$NATIVE_BIN" -maxdepth 1 -type f -empty | head -5)
  if [ -n "$empty" ]; then
    echo "FOUT: 0-byte bestanden in $NATIVE_BIN:" >&2
    echo "$empty" | sed 's/^/  /' >&2
    echo "Native-tools prefix lijkt kapot. Niet saven. Los eerst op, of" >&2
    echo "verwijder deze check bewust als je zeker weet dat het klopt." >&2
    exit 1
  fi
else
  echo "WAARSCHUWING: $NATIVE_BIN bestaat niet -- nog geen native tools gebouwd?" >&2
  echo "             Saven gaat door, maar dit is een erg vroege checkpoint." >&2
fi

mkdir -p "$BACKUPDIR"

echo "Sync $RAMDIR -> $BACKUPDIR ($TARGET) ..."
rsync -a --delete --info=progress2 "$RAMDIR"/ "$BACKUPDIR"/

echo "Chown $BACKUPDIR -> yoram:yoram ..."
chown -R yoram:yoram "$BACKUPDIR"

echo "Klaar ($TARGET). Backup-grootte:"
du -sh "$BACKUPDIR"
