#!/bin/bash
# Captures the README media against the anonymised fixtures in tests/fixtures,
# never against real hosts or task titles. Drives the running shell over IPC
# and the keyboard with wtype, shoots with grim, composes with ImageMagick.
#
#   tools/demo/capture.sh all        # everything below
#   tools/demo/capture.sh shots      # panel + bar + toast stills
#   tools/demo/capture.sh gif        # docs/images/demo.gif
#   tools/demo/capture.sh card       # docs/images/announcement.png
#   tools/demo/capture.sh preview    # preview.png at the repo root
#
# Assumes a 1920-wide primary output named in $OUTPUT with the bar on top and
# the sheep near the right; adjust PANEL_X / BAR_RIGHT for another layout.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
plugin="io.github.salemsayed.omaherd"
out="$root/docs/images"
OUTPUT=${OUTPUT:-HDMI-A-1}
PANEL_X=${PANEL_X:-1340}; PANEL_W=${PANEL_W:-560}; PANEL_H=${PANEL_H:-700}
BAR_RIGHT=${BAR_RIGHT:-1658}; BAR_H=${BAR_H:-26}
runtime="${XDG_RUNTIME_DIR:-/tmp}/omaherd"
fixture="$runtime/fixture.json"
tmp=$(mktemp -d)
trap 'rm -f "$fixture"; omarchy-shell "$plugin" poke >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
mkdir -p "$runtime" "$out"

ipc() { omarchy-shell "$plugin" "$@" >/dev/null; }
settle() { sleep 1.8; }
quiet_toasts() { omarchy-shell notifications dismiss " needs input" >/dev/null 2>&1 || true
                 omarchy-shell notifications dismiss " finished" >/dev/null 2>&1 || true; }
use_fixture() { cp "$1" "$fixture"; ipc poke; sleep 2.5; quiet_toasts; }
shot() { grim -o "$OUTPUT" "$1"; }
# The bar crop is anchored at the widget's right edge (BAR_RIGHT) and finds
# the sheep for its left edge, so neighbouring widgets stay out of the shot.
bar_crop() { python3 "$root/tools/demo/barcrop.py" "$1" "$2" "$BAR_RIGHT" "$BAR_H"; }

# Crop a screenshot to one card — the panel or a toast — by the accent-colored
# frame the shell draws around it, so nothing of the desktop behind it (other
# windows, other people's names) ever lands in a published image.
card_crop() { python3 "$root/tools/demo/framecrop.py" "$1" "$2" "$4"; }
panel_crop() { card_crop "$1" "$2" "" "${PANEL_W}x${PANEL_H}+${PANEL_X}+0"; }
toast_crop() { card_crop "$1" "$2" "" "640x240+1280+8"; }

# A fixture with only working agents, derived from the big one.
python3 - "$root/tests/fixtures/many-agents.json" "$tmp/working.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keep = [a for a in d["agents"] if a["status"] == "working"][:4]
d["agents"] = keep
for t in d["targets"]:
    t["agents"] = [a for a in keep if a["host"] == t["host"]]
c = {"total": len(keep), "attention": 0, "blocked": 0, "done": 0, "working": len(keep), "idle": 0, "unknown": 0}
d["counts"] = c; d["statusText"] = f"{len(keep)} working"; d["hasErrors"] = False; d["lastError"] = ""
json.dump(d, open(sys.argv[2], "w"))
PY

shots() {
  use_fixture "$root/tests/fixtures/many-agents.json"
  ipc open; settle; shot "$tmp/folded.png"; panel_crop "$tmp/folded.png" "$out/panel-folded.png"
  for _ in $(seq 1 15); do wtype -k j; done; wtype -k Return; sleep 0.3
  for _ in $(seq 1 10); do wtype -k j; done; wtype -k Return; sleep 0.6
  shot "$tmp/unfolded.png"; panel_crop "$tmp/unfolded.png" "$out/panel-unfolded.png"
  ipc close; sleep 0.6
  shot "$tmp/b1.png"; bar_crop "$tmp/b1.png" "$tmp/bar-attention.png"
  use_fixture "$tmp/working.json"; shot "$tmp/b2.png"; bar_crop "$tmp/b2.png" "$tmp/bar-working.png"
  use_fixture "$root/tests/fixtures/stopped.json"; shot "$tmp/b3.png"; bar_crop "$tmp/b3.png" "$tmp/bar-quiet.png"
  ipc open; settle; shot "$tmp/stopped.png"; panel_crop "$tmp/stopped.png" "$out/panel-stopped.png"; ipc close
  local barbg
  barbg=$(magick "$tmp/bar-quiet.png" -format "%[pixel:p{2,2}]" info:)
  magick -background "$barbg" -gravity west "$tmp/bar-quiet.png" "$tmp/bar-working.png" "$tmp/bar-attention.png" \
    -append "$out/bar-states.png"
  # One toast, raised the way the service raises it, then withdrawn.
  # Revisions are wall-clock milliseconds, like the service's, so the demo
  # toast is newer than any tombstone a reconcile left for this key.
  "$root/omaherd-notify" --key demo --kind blocked --summary "storefront · pi needs input" \
    --body "$(printf 'Assistant identity introduction\nworkbox · tab 2')" --revision "$(date +%s%3N)" >/dev/null 2>&1 || true
  sleep 1.3; shot "$tmp/toast.png"; toast_crop "$tmp/toast.png" "$out/notification.png"
  "$root/omaherd-notify" --key demo --kind close --revision "$(date +%s%3N)" >/dev/null 2>&1 || true
}

gif() {
  use_fixture "$root/tests/fixtures/many-agents.json"
  local i=0
  # Only frames with the panel open: a blank frame at either end reads as a
  # flash, and the bar itself is not the story here.
  frame() { i=$((i+1)); shot "$tmp/g$i.png"; magick "$tmp/g$i.png" -crop "${PANEL_W}x${PANEL_H}+${PANEL_X}+0" +repage "$tmp/f$(printf %02d $i).png"; }
  ipc open; settle; frame; sleep 0.6; frame
  wtype -k j; sleep 0.5; frame; wtype -k j; sleep 0.5; frame; wtype -k j; sleep 0.5; frame
  for _ in $(seq 1 12); do wtype -k j; done; sleep 0.5; frame
  wtype -k Return; sleep 0.7; frame; sleep 0.4; frame
  for _ in $(seq 1 10); do wtype -k j; done; wtype -k Return; sleep 0.7; frame; sleep 0.6; frame
  ipc close
  # Every frame is the panel card on one canvas of the largest card's size,
  # stored whole (no frame optimisation, no disposal tricks) so viewers
  # never show a partial frame.
  local w=0 h=0 f dims
  for f in "$tmp"/f*.png; do
    card_crop "$f" "$f.card.png" "" "${PANEL_W}x${PANEL_H}+0+0"
    dims=$(magick "$f.card.png" -format '%w %h' info:)
    (( ${dims% *} > w )) && w=${dims% *}
    (( ${dims#* } > h )) && h=${dims#* }
  done
  local bg
  bg=$(magick "$tmp/f01.png.card.png" -format "%[pixel:p{6,6}]" info:)
  for f in "$tmp"/f*.card.png; do
    magick -size "${w}x${h}" xc:"$bg" "$f" -gravity north -composite "$f"
  done
  magick -delay 120 -dispose none "$tmp"/f*.card.png -loop 0 -coalesce "$out/demo.gif"
}

card() {
  [[ -f "$out/panel-folded.png" ]] || shots
  local font
  font=$(fc-list | grep -i 'JetBrainsMonoNerdFont-Regular' | head -1 | cut -d: -f1)
  [[ -n $font ]] || font=$(fc-match -f '%{file}' monospace)
  magick "$out/panel-folded.png" -bordercolor "#dce0e8" -border 2 "$tmp/card-panel.png"
  magick -size 1600x900 xc:"#eff1f5" \
    \( "$tmp/card-panel.png" -resize x780 \) -gravity east -geometry +80+0 -composite \
    -gravity northwest -font "$font" -fill "#4c4f69" \
    -pointsize 66 -annotate +90+150 "Omaherd" \
    -pointsize 30 -annotate +90+250 "Your coding agents, in the Omarchy bar." \
    -pointsize 22 -fill "#6c6f85" \
    -annotate +90+340 "Who needs you, what each agent is doing," \
    -annotate +90+378 "and how long it has waited — local and" \
    -annotate +90+416 "remote — with one keypress to the pane." \
    -pointsize 19 -fill "#4c4f69" \
    -annotate +90+540 "omarchy plugin add \\" \
    -annotate +90+572 "  https://github.com/salemsayed/omaherd.git --enable" \
    "$out/announcement.png"
}

preview() {
  use_fixture "$root/tests/fixtures/many-agents.json"
  ipc open; settle; shot "$tmp/p.png"; ipc close
  panel_crop "$tmp/p.png" "$root/preview.png"
}

case "${1:-all}" in
  shots) shots ;;
  gif) gif ;;
  card) card ;;
  preview) preview ;;
  all) shots; gif; card; preview ;;
  *) echo "usage: $0 [all|shots|gif|card|preview]" >&2; exit 2 ;;
esac
echo "done: $out"
