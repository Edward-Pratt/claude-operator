#!/usr/bin/env bash
# tools/screen.sh OUT.png [TAB]: screenshot exactly the panel, open on a secondary output.
# Opens it through the widget instance there, switches to TAB, and crops to the panel's
# own bounds (found by diffing against a shot taken before it opened, so keep the rest of
# that screen still), so nothing behind it ends up in the image. OUTPUT (default HDMI-A-1) and WAIT (default 1.5 s) override.
# Needs grim and ImageMagick. Wait for "Reloaded script" toasts to clear first.
set -eu
out=${1:?usage: tools/screen.sh OUT.png [TAB]}
output=${OUTPUT:-HDMI-A-1}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1' EXIT

noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1 || true
sleep 0.4
grim -o "$output" "$tmp/before.png"
noctalia msg plugin edward/claude-operator:widget "$output" click >/dev/null
sleep 0.8
[ -n "${2:-}" ] && noctalia msg plugin edward/claude-operator:panel all tab "$2" >/dev/null
sleep "${WAIT:-1.5}"
grim -o "$output" "$tmp/after.png"

# The panel's box, shadow included: what changed when it opened. Then the panel itself,
# 700x712 (manifest size, less the bar overlap), centred in it.
read -r w h x y <<<"$(magick "$tmp/before.png" "$tmp/after.png" -compose difference -composite \
  -colorspace gray -threshold 2% -trim -format '%w %h %X %Y' info: | tr -d '+')"
magick "$tmp/after.png" -crop "700x712+$((x + (w - 700) / 2))+${y}" +repage "$out"
echo "$out 700x712+$((x + (w - 700) / 2))+${y}"
