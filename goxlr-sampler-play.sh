#!/bin/bash
# ~/bin/goxlr-sampler-play
SINK="alsa_output.usb-TC-Helicon_GoXLR-00.HiFi__Line3__sink"

cleanup() {
    [ -n "${pids:-}" ] && kill -TERM $pids 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

ffmpeg -nostdin -i "$1" -af loudnorm=I=-23 -f wav -loglevel quiet - 2>/dev/null \
  | pw-play --target="$SINK" - &
pids="$(jobs -p)"
wait
