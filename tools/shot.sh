#!/usr/bin/env bash
# tools/shot.sh NAME [TAB]: open the panel on a secondary output, screenshot it, close it.
# For testing without taking over the primary display. OUTPUT (default HDMI-A-1), WAIT
# (seconds before the capture, default 1.5), CROP (magick geometry of the panel; found
# automatically by diffing the header strip before and after opening) and DIR (default
# /tmp) override; KEEP=1 leaves the panel open. Needs grim and ImageMagick.
out=${OUTPUT:-HDMI-A-1}
dir=${DIR:-/tmp}
[ -n "$2" ] && noctalia msg plugin edward/claude-operator:panel all tab "$2" >/dev/null 2>&1
noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1
sleep 0.4
grim -o "$out" "$dir/$1-before.png"
noctalia msg plugin edward/claude-operator:widget "$out" click >/dev/null
sleep "${WAIT:-1.5}"
grim -o "$out" "$dir/$1-full.png"
if [ -z "${CROP:-}" ]; then
  # The panel's x extent: where the strip under the bar changed when it opened.
  x=$(magick "$dir/$1-before.png" "$dir/$1-full.png" -crop 1920x60+0+50 +repage -compose difference -composite \
      -colorspace gray -threshold 8% -trim -format '%X' info: 2>/dev/null | tr -d '+')
  CROP="740x790+$(( ${x:-1050} > 10 ? ${x:-1050} - 10 : 0 ))+0"
fi
[ -z "$KEEP" ] && noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1
magick "$dir/$1-full.png" -crop "$CROP" +repage "$dir/$1.png"
echo "$dir/$1.png"
