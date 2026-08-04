# Random Scripts
Random scripts that don't belong to a specific project.

## Stop screencasts
Stops XDG Desktop Portal screencasts on KDE Plasma. Might also stop some other portal sessions.

Usage:
```sh
./stop-screencasts.sh
```

Used for: Bitfocus Companion emergency button for stopping all screencasts.

## GoXLR Sampler Play
Plays a specified sound on the GoXLR's sampler channel.

```sh
./goxlr-sampler-play.sh <audio file>
./goxlr-sampler-play.sh ~/Sounds/my-audio-file.flac
```

Requirements: `pw-play`  
It might be necessary to change the sink name (`SINK="..."`).
