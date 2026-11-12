#!/usr/bin/env bash
# cross-check.sh - watch another node from this one and alert by Telegram.
#
# Runs from cron (every 2 minutes on node-b). Each probe has its own counter of
# consecutive failures, kept in a small state file:
#   - a failure increments the counter; at THRESHOLD failures, ONE alert is sent;
#   - more failures send nothing (no alert storm);
#   - the first success after an alert sends ONE recovery message;
#   - an alert that could not be sent is retried on the next run.
#
#   sudo -u cross-check /usr/local/sbin/cross-check.sh --config /etc/cross-check/cross-check.conf
#   bash scripts/cross-check.sh --config my.conf --state-dir /tmp/cc --dry-run
#
# Configuration: KEY=VALUE lines, read as data (the file is never sourced).
#   PROBE=NAME|TYPE|TARGET     repeatable. TYPE is one of:
#       tcp   TARGET = host:port       a TCP connection opens
#       http  TARGET = URL             any HTTP answer below 500 (401 = alive)
#       ping  TARGET = host            one ICMP echo reply
#   THRESHOLD=3                consecutive failures before the alert
#   TIMEOUT=5                  seconds per probe
#   STATE_DIR=/var/lib/cross-check
#   TELEGRAM_CHAT_ID=<TELEGRAM_USER_ID>
#   TELEGRAM_TOKEN_FILE=/etc/cross-check/telegram.token   (bot token only, mode 400)
#
# The bot token is read from its file and given to curl on stdin (-K -), so it
# never appears in the process list.
#
# Explained in docs/monitoring/cross-check.md and ADR 0006.
# Exit codes: 0 every probe passed, 1 at least one probe failed,
#             2 usage or configuration error, 3 an alert could not be sent.

set -euo pipefail

config=""
state_dir=""
state_dir_option=""
dry_run=0
threshold=3
timeout_s=5
chat_id=""
token_file=""
probes=()

usage() {
    cat <<'EOF'
Usage: cross-check.sh --config FILE [--state-dir DIR] [--dry-run]

  --config     configuration file (see the header of this script)
  --state-dir  where the failure counters are kept (overrides STATE_DIR)
  --dry-run    print alerts instead of sending them; Telegram settings not needed
EOF
}

die() { echo "error: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config|--state-dir)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 2
            fi
            if [ "$1" = "--config" ]; then config="$2"; else state_dir_option="$2"; fi
            shift 2
            ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$config" ] || { usage >&2; exit 2; }
[ -r "$config" ] || die "cannot read the configuration file"

# --- Read the configuration as data -----------------------------------------
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" == *=* ]] || die "line $line_no: expected KEY=VALUE"
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
        PROBE) probes+=("$value") ;;
        THRESHOLD) threshold="$value" ;;
        TIMEOUT) timeout_s="$value" ;;
        STATE_DIR) state_dir="$value" ;;
        TELEGRAM_CHAT_ID) chat_id="$value" ;;
        TELEGRAM_TOKEN_FILE) token_file="$value" ;;
        *) die "line $line_no: unknown key $key" ;;
    esac
done < "$config"

[ -n "$state_dir_option" ] && state_dir="$state_dir_option"
state_dir="${state_dir:-/var/lib/cross-check}"

[[ "$threshold" =~ ^[1-9][0-9]*$ ]] || die "THRESHOLD must be a positive whole number"
[[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || die "TIMEOUT must be a positive whole number of seconds"
[ "${#probes[@]}" -gt 0 ] || die "no PROBE line in the configuration"

if [ "$dry_run" -eq 0 ]; then
    [ -n "$chat_id" ] || die "TELEGRAM_CHAT_ID is not set (or use --dry-run)"
    if [ -z "$token_file" ] || [ ! -r "$token_file" ]; then
        die "cannot read TELEGRAM_TOKEN_FILE (or use --dry-run)"
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required to send alerts"
fi

# Validate every probe before running any, so a typo is not half applied
for spec in "${probes[@]}"; do
    IFS='|' read -r p_name p_type p_target p_extra <<< "$spec"
    [ -z "${p_extra:-}" ] || die "PROBE has more than three fields: $spec"
    [[ "$p_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "PROBE name must use letters, digits, dot, dash or underscore: $spec"
    case "$p_type" in
        tcp) [[ "$p_target" =~ ^[^:]+:[0-9]+$ ]] || die "tcp target must be host:port: $spec" ;;
        http) [[ "$p_target" =~ ^https?:// ]] || die "http target must be a URL: $spec" ;;
        ping) [[ "$p_target" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || die "ping target must be a host name or address: $spec" ;;
        *) die "unknown PROBE type $p_type: $spec" ;;
    esac
done

mkdir -p -- "$state_dir" || die "cannot create the state directory"
[ -w "$state_dir" ] || die "state directory is not writable"

# Two runs at the same time would count one failure twice
if command -v flock >/dev/null 2>&1; then
    exec 9>"$state_dir/.lock"
    if ! flock -n 9; then
        echo "Another run is in progress, skipping."
        exit 0
    fi
fi

# --- Probes ------------------------------------------------------------------
probe() {
    local type="$1" target="$2" code
    case "$type" in
        tcp)
            # bash opens the connection itself through /dev/tcp: no nc needed.
            # $1 and $2 are expanded by the inner bash, hence the single quotes.
            # shellcheck disable=SC2016
            timeout "$timeout_s" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${target%:*}" "${target##*:}" 2>/dev/null
            ;;
        http)
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout_s" -- "$target" 2>/dev/null)" || true
            [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
            ;;
        ping)
            ping -c 1 -W "$timeout_s" "$target" >/dev/null 2>&1
            ;;
    esac
}

send_alert() {
    local text="$1" token
    if [ "$dry_run" -eq 1 ]; then
        printf 'ALERT %s\n' "$text"
        return 0
    fi
    token="$(tr -d '\r\n' < "$token_file")"
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
        | curl -fsS --max-time 10 -o /dev/null -K - \
            --data-urlencode "chat_id=$chat_id" \
            --data-urlencode "text=$text"
}

# --- Main loop ---------------------------------------------------------------
now="$(date -u +%s)"
stamp="$(date -u '+%Y-%m-%d %H:%M UTC')"
failed=0
undelivered=0

for spec in "${probes[@]}"; do
    IFS='|' read -r name type target _ <<< "$spec"
    state_file="$state_dir/$name.state"

    # State: <consecutive failures> <alert sent: 0 or 1> <epoch of first failure>
    count=0 alerted=0 since=0
    if [ -r "$state_file" ]; then
        read -r count alerted since < "$state_file" || true
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$alerted" =~ ^[01]$ ]] || alerted=0
    [[ "$since" =~ ^[0-9]+$ ]] || since=0

    if probe "$type" "$target"; then
        if [ "$alerted" -eq 1 ]; then
            minutes=$(( (now - since) / 60 ))
            if send_alert "RECOVERED $name ($type $target) at $stamp, down for about $minutes min"; then
                alerted=0
            else
                undelivered=$((undelivered + 1))
            fi
        fi
        count=0
        # Keep the start of the outage until the recovery message is delivered
        if [ "$alerted" -eq 0 ]; then since=0; fi
        printf 'OK    %s\n' "$name"
    else
        failed=$((failed + 1))
        if [ "$count" -eq 0 ] && [ "$alerted" -eq 0 ]; then since="$now"; fi
        count=$((count + 1))
        if [ "$count" -ge "$threshold" ] && [ "$alerted" -eq 0 ]; then
            if send_alert "DOWN $name ($type $target): $count consecutive failed checks, last at $stamp"; then
                alerted=1
            else
                undelivered=$((undelivered + 1))
            fi
        fi
        printf 'FAIL  %s (%s/%s)\n' "$name" "$count" "$threshold"
    fi

    # Write to a temporary file, then rename: a crash never leaves half a line
    printf '%s %s %s\n' "$count" "$alerted" "$since" > "$state_file.tmp"
    mv -f -- "$state_file.tmp" "$state_file"
done

if [ "$undelivered" -gt 0 ]; then
    echo "error: $undelivered alert(s) could not be sent; retrying on the next run" >&2
    exit 3
fi
[ "$failed" -eq 0 ] || exit 1
