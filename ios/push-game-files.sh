#!/usr/bin/env bash
# Copy your extracted game files (exefs/ and romfs/) into the app's Documents/game on a USB-connected iPhone / iPad.
# The same as copying them with the Files app (On My iPhone → Persona 4 Golden → game), without the phone in hand.
#   push-game-files.sh <folder with exefs/ and romfs/>
#   DEVICE  device id (default: the first connected one)
#   BUNDLE  the installed app's bundle id (default: com.devz.persona4golden; a signer may have changed it)
#   ONLY    copy only these items (e.g. "romfs/data.cpk"), space separated
# devicectl stops at 4 GB a file: bigger ones (data.cpk, 7.2 GB) go over as <name>.part1, .part2, ... of 3.5 GiB, made one
# at a time in $SPLIT_DIR (default: the temp folder; needs 3.5 GiB free), and the app joins them on its next start
# (ios/src/launcher.m join_split_files).
set -uo pipefail
SRC="${1:?usage: push-game-files.sh <folder with exefs/ and romfs/>}"
BUNDLE="${BUNDLE:-com.devz.persona4golden}"
[ -f "$SRC/exefs/main" ] && [ -d "$SRC/romfs" ] || { echo "$SRC has no exefs/main or romfs/" >&2; exit 1; }
if [ -z "${DEVICE:-}" ]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk 'NR>2 && /connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{25,}$/) {print $i; exit}}')"
fi
[ -n "$DEVICE" ] || { echo "No connected device" >&2; exit 1; }
err="$(mktemp)"
SPLIT_DIR="${SPLIT_DIR:-${TMPDIR:-/tmp}}"
PART=$((3584 * 1024 * 1024))
fail=0
send() {  # <local file> <path under Documents/game>
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source "$1" --destination "Documents/game/$2" >/dev/null 2>"$err" || { echo "  FAILED: $(grep -m1 -i error "$err")"; fail=1; }
}
items=()
if [ -n "${ONLY:-}" ]; then for o in $ONLY; do items+=("$SRC/$o"); done; else items=("$SRC"/exefs/* "$SRC"/romfs/*); fi
for item in "${items[@]}"; do
  rel="${item#"$SRC"/}"
  size=$(stat -f %z "$item")
  if [ -f "$item" ] && [ "$size" -gt "$PART" ]; then
    n=$(( (size + PART - 1) / PART ))
    for i in $(seq 1 $n); do
      part="$SPLIT_DIR/$(basename "$item").part$i"
      echo "$(date +%H:%M:%S) $rel.part$i of $n (making it)"
      dd if="$item" of="$part" bs=1m skip=$(( (i - 1) * PART / 1048576 )) count=$(( PART / 1048576 )) 2>/dev/null \
        || { echo "  FAILED: couldn't make $part (space in $SPLIT_DIR?)"; fail=1; rm -f "$part"; break; }
      echo "$(date +%H:%M:%S) $rel.part$i of $n ($(du -h "$part" | cut -f1))"
      send "$part" "$rel.part$i"
      rm -f "$part"
    done
  else
    echo "$(date +%H:%M:%S) $rel ($(du -h "$item" | cut -f1 | tail -1))"
    send "$item" "$rel"
  fi
done
rm -f "$err"
echo "$(date +%H:%M:%S) done (failures: $fail)"
exit $fail
