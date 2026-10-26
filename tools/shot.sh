#!/usr/bin/env bash
# tools/shot.sh NAME [TAB]: open the panel on a secondary output, screenshot it, close it.
# For testing without taking over the primary display. OUTPUT (default HDMI-A-1), WAIT
# (seconds before the capture, default 0.8), CROP (magick geometry of the panel) and DIR
# (default /tmp) override; KEEP=1 leaves the panel open. Needs grim and ImageMagick.
out=${OUTPUT:-HDMI-A-1}
dir=${DIR:-/tmp}
[ -n "$2" ] && noctalia msg plugin edward/claude-operator:panel all tab "$2" >/dev/null 2>&1
noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1
noctalia msg plugin edward/claude-operator:widget "$out" click >/dev/null
sleep "${WAIT:-0.8}"
grim -o "$out" "$dir/$1-full.png"
[ -z "$KEEP" ] && noctalia msg panel-close edward/claude-operator:panel >/dev/null 2>&1
magick "$dir/$1-full.png" -crop "${CROP:-720x760+1050+0}" +repage "$dir/$1.png"
echo "$dir/$1.png"
