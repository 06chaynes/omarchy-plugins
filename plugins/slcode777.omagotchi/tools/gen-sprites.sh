#!/usr/bin/env bash
# Convert the text grids in tools/sprites/ into white-on-transparent PNGs
# in assets/sprites/. Grid size is read from the file (any rectangle works:
# pets are 16x16, decor can be larger). Requires ImageMagick. Dev-only: the
# generated PNGs are committed, users never run this.
set -euo pipefail
cd "$(dirname "$0")/sprites"
out="../../assets/sprites"

for txt in ./*.txt; do
  name="${txt#./}"; name="${name%.txt}"
  w=$(head -1 "$txt" | tr -d '\n' | wc -c)
  h=$(grep -c . "$txt")
  pbm="$name.pbm"  # next to the grids, gitignored — no shared /tmp
  { echo "P1"; echo "$w $h"; tr 'X.' '10' < "$txt"; } > "$pbm"
  magick "$pbm" -transparent white -fill '#FFFFFF' -opaque black "PNG32:$out/$name.png"
  rm "$pbm"
  echo "$out/$name.png (${w}x${h})"
done
