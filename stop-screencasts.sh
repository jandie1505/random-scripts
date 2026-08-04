#!/usr/bin/env bash
set -uo pipefail
BACKEND="org.freedesktop.impl.portal.desktop.kde"
SESSION_ROOT="/org/freedesktop/portal/desktop/session"
IFACE="org.freedesktop.impl.portal.Session"
DRY_RUN="${DRY_RUN:-0}"

owner=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s "$BACKEND" 2>/dev/null)
[[ "$owner" == "b true" ]] || { echo "Portal backend not running."; exit 0; }

# PIDs consuming a screencast
mapfile -t cast_pids < <(
  pw-dump 2>/dev/null | jq -r '
    (reduce (.[] | select(.type=="PipeWire:Interface:Client")) as $c
        ({}; .[$c.id|tostring] = ($c.info.props["application.process.id"] // empty))) as $pids
    | .[] | select(.type=="PipeWire:Interface:Node") | .info.props as $p
    | select(($p["media.class"] == "Stream/Input/Video")
             or ($p["media.role"] == "Screen")
             or ($p["media.type"] == "Video" and $p["media.category"] == "Capture"))
    | ($p["application.process.id"] // $pids[($p["client.id"]|tostring)] // empty)
    | tostring' | sort -u
)
(( ${#cast_pids[@]} )) || { echo "No active video stream."; exit 0; }
printf -v joined ' %s ' "${cast_pids[*]}"

mapfile -t paths < <(
  busctl --user tree --list "$BACKEND" 2>/dev/null | grep "^${SESSION_ROOT}/[^/]\+/"
)

count=0
for p in "${paths[@]}"; do
    busctl --user introspect "$BACKEND" "$p" 2>/dev/null | grep -q "$IFACE" || continue

    rest=${p#"$SESSION_ROOT"/}; sender=${rest%%/*}
    pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
              org.freedesktop.DBus GetConnectionUnixProcessID s ":${sender//_/.}" \
              2>/dev/null | awk '{print $2}')
    [[ -n "${pid:-}" && "$joined" == *" $pid "* ]] || continue

    name=$(ps -p "$pid" -o comm= 2>/dev/null)
    if (( DRY_RUN )); then
        echo "[dry-run] would close: $name ($pid) → $p"; count=$((count+1)); continue
    fi
    if busctl --user call "$BACKEND" "$p" "$IFACE" Close >/dev/null 2>&1; then
        echo "Stopped: $name (PID $pid)"; count=$((count+1))
    fi
done

(( count )) || { echo "No matching session found."; exit 0; }
(( DRY_RUN )) || { command -v notify-send >/dev/null && \
    notify-send -a "Screencast" -i process-stop \
        "Screencast stopped" "$count session(s) stopped"; }
