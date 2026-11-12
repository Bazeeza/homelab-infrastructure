#!/usr/bin/env bash
# Summarize the Prometheus /metrics output of Uptime Kuma: one line per probe,
# problems first. Same logic as the status bot, usable from a terminal.
#
#   bash scripts/kuma-status.sh --file saved-metrics.txt           # offline
#   bash scripts/kuma-status.sh < saved-metrics.txt                # from stdin
#   KUMA_URL=http://node-a:3001 KUMA_KEY_FILE=/etc/kuma-status/api.key \
#       bash scripts/kuma-status.sh                                 # live
#   bash scripts/kuma-status.sh --file m.txt --ignore admin-ws     # expected down
#
# The API key is read from a file and given to curl on stdin (-K -), so it
# never appears in the process list or in the shell history.
#
# Status values of the monitor_status metric:
#   0 DOWN   1 UP   2 PENDING   3 MAINT (maintenance)
#
# Explained in docs/monitoring/uptime-kuma.md.
# Exit codes: 0 every probe up (ignored probes excluded), 1 at least one probe
#             not up, 2 usage error, unreadable input or no probe found.

set -euo pipefail

input_file=""
ignored=()

usage() {
    cat <<'EOF'
Usage: kuma-status.sh [--file FILE] [--ignore NAME]...

  --file    read saved /metrics output from FILE
  --ignore  probe name that may be down without failing (repeatable),
            for example a laptop that sleeps
Without --file: reads stdin if it is not a terminal, otherwise fetches
$KUMA_URL/metrics with the API key stored in $KUMA_KEY_FILE.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --file|--ignore)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 2
            fi
            if [ "$1" = "--file" ]; then input_file="$2"; else ignored+=("$2"); fi
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Where the metrics come from. Checked here, in the main shell, so that an
# error stops the script instead of a subshell.
source_mode="url"
if [ -n "$input_file" ]; then
    if [ ! -r "$input_file" ]; then
        echo "Cannot read $input_file" >&2
        exit 2
    fi
    source_mode="file"
elif [ ! -t 0 ]; then
    source_mode="stdin"
elif [ -z "${KUMA_URL:-}" ] || [ -z "${KUMA_KEY_FILE:-}" ]; then
    echo "No input: use --file, stdin, or set KUMA_URL and KUMA_KEY_FILE" >&2
    exit 2
elif [ ! -r "$KUMA_KEY_FILE" ]; then
    echo "Cannot read the API key file" >&2
    exit 2
fi

read_metrics() {
    case "$source_mode" in
        file) cat -- "$input_file" ;;
        stdin) cat ;;
        *)
            # Basic auth with an empty user name and the API key as password.
            # The curl config is passed on stdin: the key stays out of argv.
            local key
            key="$(tr -d '\r\n' < "$KUMA_KEY_FILE")"
            printf 'user = ":%s"\n' "$key" \
                | curl -fsS --max-time 10 -K - -- "${KUMA_URL%/}/metrics"
            ;;
    esac
}

is_ignored() {
    local name="$1" item
    for item in "${ignored[@]+"${ignored[@]}"}"; do
        [ "$item" = "$name" ] && return 0
    done
    return 1
}

metrics="$(read_metrics)" || {
    echo "Could not read the metrics (network, URL or API key)" >&2
    exit 2
}

# monitor_status{monitor_name="Public site",monitor_type="http",...} 1
re_line='^monitor_status\{(.*)\}[[:space:]]+([^[:space:]]+)'
# Label values may contain escaped quotes and backslashes: \" and \\
re_name='(^|,)monitor_name="(([^"\\]|\\.)*)"'
bs=$'\\'
q='"'

problems=()
healthy=()
total=0
not_up=0

while IFS= read -r line; do
    [[ "$line" =~ $re_line ]] || continue
    labels="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]%%.*}"
    name="(no name)"
    if [[ "$labels" =~ $re_name ]]; then
        name="${BASH_REMATCH[2]}"
        # Undo the escaping; quoted patterns are matched literally
        name=${name//"$bs$q"/"$q"}
        name=${name//"${bs}n"/" "}
        name=${name//"$bs$bs"/"$bs"}
    fi
    case "$value" in
        0) state="DOWN" ;;
        1) state="UP" ;;
        2) state="PENDING" ;;
        3) state="MAINT" ;;
        *) state="UNKNOWN" ;;
    esac
    total=$((total + 1))
    if [ "$state" = "UP" ]; then
        healthy+=("$(printf '%-8s %s' "$state" "$name")")
    elif is_ignored "$name"; then
        problems+=("$(printf '%-8s %s [ignored]' "$state" "$name")")
    else
        problems+=("$(printf '%-8s %s' "$state" "$name")")
        not_up=$((not_up + 1))
    fi
done <<< "$metrics"

if [ "$total" -eq 0 ]; then
    echo "No monitor_status line found: is this the Uptime Kuma /metrics output?" >&2
    exit 2
fi

# Problems first, then the probes that are up; alphabetical inside each group
if [ "${#problems[@]}" -gt 0 ]; then printf '%s\n' "${problems[@]}" | LC_ALL=C sort -b -k2; fi
if [ "${#healthy[@]}" -gt 0 ]; then printf '%s\n' "${healthy[@]}" | LC_ALL=C sort -b -k2; fi

echo
echo "Summary: $total probe(s), $not_up not up."
[ "$not_up" -eq 0 ] || exit 1
