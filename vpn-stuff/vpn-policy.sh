#!/usr/bin/env bash
#
# vpn-policy — add/remove policy routing rules for a (WireGuard) interface
#
#   ./vpn-policy up     ... install the rules
#   ./vpn-policy down   ... remove every rule belonging to the interface
#   ./vpn-policy status ... show the current rules of the interface
#
# Idea: traffic entering through the interface goes to the VPN table by
# default. Exceptions (local networks) are sent to the "main" table by rules
# with a lower priority, so they are evaluated first.
#
# All exception rules share priority PRIO; the VPN rules sit at PRIO + 1.
# The exceptions are mutually exclusive and all carry the same action, so
# their relative order is irrelevant and one shared priority is enough.
#
# There are deliberately NO default values: a missing argument aborts the run.

set -euo pipefail

IFACE=""
TABLE=""
PRIO=""
DRY=0
SUBNETS=()

# ----------------------------------------------------------------- Helpers ---
usage() {
    cat <<EOF
Usage: ${0##*/} {up|down|status} [options]

Options:
  -i, --interface DEV   Incoming interface
  -t, --table NAME|NUM  Routing table used for the VPN exit
  -n, --net CIDR        Exception subnet, may be given multiple times.
                        IPv4/IPv6 is detected from the prefix.
  -p, --prio N          Priority of the exception rules. The VPN rules are
                        installed at N + 1.
  -d, --dry-run         Only print what would be done
  -h, --help            Show this help

Required arguments:
  up      -i, -t, -p and at least one -n
  down    -i
  status  -i

Example:
  ${0##*/} up -i wg-normal -t vpnout -p 90 \\
      -n 192.168.178.0/24 -n 10.12.12.0/24 -n 10.10.10.0/24
  ${0##*/} down -i wg-normal

Note: "down" deletes *every* rule matching "iif <DEV>", whether or not this
script created it.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Run a command, or just print it in dry-run mode.
run() {
    if (( DRY )); then
        printf '  %s\n' "$*"
    else
        "$@"
    fi
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Pick the address family flag for a prefix: fd00::/8 -> -6, otherwise -4
fam_of() {
    case "$1" in
        *:*) printf -- '-6' ;;
        *)   printf -- '-4' ;;
    esac
}

# Rough sanity check of a prefix. The kernel has the final say.
validate_net() {
    local net="$1" addr="${1%%/*}" len="" o
    [[ "$net" == */* ]] && len="${net##*/}"

    if [[ "$addr" == *:* ]]; then
        [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]] || die "invalid IPv6 prefix: '$net'"
        [[ -n "$len" ]] || die "prefix length missing: '$net' (e.g. ${addr}/64)"
        is_uint "$len" && (( len <= 128 )) || die "invalid prefix length: '$net'"
    else
        [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid IPv4 prefix: '$net'"
        IFS='.' read -r -a o <<< "$addr"
        for octet in "${o[@]}"; do
            (( octet <= 255 )) || die "invalid IPv4 address: '$net'"
        done
        [[ -n "$len" ]] || die "prefix length missing: '$net' (e.g. ${addr}/24)"
        is_uint "$len" && (( len <= 32 )) || die "invalid prefix length: '$net'"
    fi
}

# Print every rule of the given family that matches "iif $IFACE", one per line.
rules_for_iface() {
    local fam="$1"
    # In dry-run mode "ip" may not even be installed; report nothing then.
    command -v ip >/dev/null 2>&1 || return 0
    ip "$fam" rule show | awk -v dev="$IFACE" '
        {
            for (i = 1; i <= NF; i++)
                if ($i == "iif" && $(i+1) == dev) { print; break }
        }'
}

need_root() {
    (( DRY )) && return 0
    (( EUID == 0 )) || die "must be run as root (or via sudo)."
}

# ---------------------------------------------------------------- Commands ---
cmd_up() {
    need_root
    echo "Installing rules for '$IFACE' (table '$TABLE'):"

    # Clean up first so that "up" stays idempotent.
    cmd_down quiet

    local net fam
    for net in "${SUBNETS[@]}"; do
        fam="$(fam_of "$net")"
        run ip "$fam" rule add iif "$IFACE" to "$net" lookup main priority "$PRIO"
    done

    run ip -4 rule add iif "$IFACE" lookup "$TABLE" priority "$(( PRIO + 1 ))"
    run ip -6 rule add iif "$IFACE" lookup "$TABLE" priority "$(( PRIO + 1 ))"
}

cmd_down() {
    local quiet="${1:-}"
    need_root
    [[ -n "$quiet" ]] || echo "Removing all rules for '$IFACE':"

    # One delete per matching rule — several rules may share a priority, and
    # "ip rule del pref N iif DEV" removes one of them per call.
    local fam line prio found=0
    for fam in -4 -6; do
        while read -r line; do
            [[ -n "$line" ]] || continue
            prio="${line%%:*}"
            found=1
            run ip "$fam" rule del pref "$prio" iif "$IFACE"
        done < <(rules_for_iface "$fam")
    done

    if [[ -z "$quiet" ]] && (( ! found )); then
        echo "  (no rules found)"
    fi
}

cmd_status() {
    local fam out
    for fam in -4 -6; do
        echo "IPv${fam#-} rules for '$IFACE':"
        out="$(rules_for_iface "$fam")"
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            echo "  (no rules found)"
        fi
    done
}

# -------------------------------------------------------- Argument parsing ---
CMD=""
while (( $# )); do
    case "$1" in
        up|down|status)
            [[ -z "$CMD" ]] || die "more than one command given ('$CMD' and '$1')."
            CMD="$1" ;;
        -i|--interface)
            [[ $# -ge 2 ]] || die "option '$1' requires a value."
            [[ -z "$IFACE" ]] || die "option '$1' given more than once."
            IFACE="$2"; shift ;;
        -t|--table)
            [[ $# -ge 2 ]] || die "option '$1' requires a value."
            [[ -z "$TABLE" ]] || die "option '$1' given more than once."
            TABLE="$2"; shift ;;
        -n|--net)
            [[ $# -ge 2 ]] || die "option '$1' requires a value."
            SUBNETS+=("$2"); shift ;;
        -p|--prio)
            [[ $# -ge 2 ]] || die "option '$1' requires a value."
            [[ -z "$PRIO" ]] || die "option '$1' given more than once."
            PRIO="$2"; shift ;;
        -d|--dry-run) DRY=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "unknown argument '$1'." ;;
    esac
    shift
done

# -------------------------------------------------------------- Validation ---
[[ -n "$CMD" ]] || { usage >&2; exit 1; }
(( DRY )) || command -v ip >/dev/null 2>&1 || die "iproute2 not found: no 'ip' in PATH."
[[ -n "$IFACE" ]] || die "interface missing (-i/--interface)."
[[ "$IFACE" =~ ^[A-Za-z0-9._@-]+$ ]] || die "invalid interface name: '$IFACE'"
(( ${#IFACE} <= 15 )) || die "interface name too long (max. 15 characters): '$IFACE'"

case "$CMD" in
    up)
        [[ -n "$TABLE" ]] || die "routing table missing (-t/--table)."
        [[ -n "$PRIO" ]]  || die "priority missing (-p/--prio)."
        (( ${#SUBNETS[@]} )) || die "at least one subnet required (-n/--net)."

        # PRIO + 1 must stay below the main/default rules at 32766/32767.
        is_uint "$PRIO" && (( PRIO >= 1 && PRIO <= 32764 )) \
            || die "priority must be a number between 1 and 32764: '$PRIO'"

        for net in "${SUBNETS[@]}"; do
            validate_net "$net"
        done
        ;;
    down|status)
        # Reject options that would have no effect instead of ignoring them.
        [[ -z "$TABLE" ]] || die "option -t/--table is not allowed with '$CMD'."
        [[ -z "$PRIO" ]]  || die "option -p/--prio is not allowed with '$CMD'."
        (( ! ${#SUBNETS[@]} )) || die "option -n/--net is not allowed with '$CMD'."
        ;;
esac

case "$CMD" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
esac
