#!/usr/bin/env bash
# tools/screen.sh OUT.png [TAB]: screenshot exactly the panel, open on a secondary output.
# Opens it through the widget instance there, switches to TAB, and crops to the panel's
# own bounds (found by locating its header icon), so nothing behind it ends up in the
# image. OUTPUT (default HDMI-A-1) and WAIT (default 1.5 s) override.
# Needs grim and ImageMagick. Wait for "Reloaded script" toasts to clear first.
set -eu
out=${1:?usage: tools/screen.sh OUT.png [TAB]}
output=${OUTPUT:-HDMI-A-1}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1' EXIT

noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1 || true
sleep 0.4
noctalia msg plugin edward/claude-operator:widget "$output" click >/dev/null
sleep 0.8
[ -n "${2:-}" ] && noctalia msg plugin edward/claude-operator:panel all tab "$2" >/dev/null
sleep "${WAIT:-1.5}"
grim -o "$output" "$tmp/after.png"

# The panel: find its header icon (tools/panel-anchor.png, cut 6 px in from the panel's
# corner) in the band under the bar. Diffing against the screen behind it is not enough:
# a terminal scrolling there changes more than the panel does.
here=$(dirname "$0")
read -r ax ay <<<"$(magick compare -metric RMSE -subimage-search -dissimilarity-threshold 1 \
  <(magick "$tmp/after.png" -crop "${SCREEN_W:-1920}x110+0+30" +repage png:-) "$here/panel-anchor.png" null: 2>&1 \
  | sed -n 's/.*@ \([0-9]*\),\([0-9]*\).*/\1 \2/p' | tail -n 1)"
x=$((ax - 6)); y=$((ay + 30 - 6))
magick "$tmp/after.png" -crop "700x712+${x}+${y}" +repage "$out"
echo "$out 700x712+${x}+${y}"
