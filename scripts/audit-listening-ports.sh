#!/usr/bin/env bash
# List every listening socket of a node and flag the ones open on ALL
# interfaces that are not on the allow-list of public ports.
#
#   sudo bash scripts/audit-listening-ports.sh                        # runs ss itself
#   sudo bash scripts/audit-listening-ports.sh --docker               # also checks docker ps
#   bash scripts/audit-listening-ports.sh --allow "tcp/80 tcp/443 udp/41641"
#   ss -H -tuln | bash scripts/audit-listening-ports.sh               # read from stdin
#   bash scripts/audit-listening-ports.sh --file saved-ss-output.txt  # offline review
#
# Classification of each socket:
#   LOOPBACK  bound to 127.0.0.0/8 or ::1        reachable from the node only    OK
#   SPECIFIC  bound to one address                check it is the mesh address    INFO
#   FILTERED  all interfaces, port on --firewalled  closed by ufw: verify outside  OK
#   ALLOWED   all interfaces, port on --allow      a public service on purpose    OK
#   FINDING   all interfaces, on neither list      reachable from the Internet    FAIL
#
# Docker published ports are never FILTERED: Docker bypasses ufw.
#
# Explained in docs/network/access-verification.md.
# Exit codes: 0 no finding, 1 at least one finding, 2 usage error or empty input.

set -euo pipefail

# The mesh VPN client listens on UDP 41641 on all interfaces by default.
allow="udp/41641"
# sshd listens on all interfaces on purpose; ufw lets it in on the mesh only.
firewalled="tcp/22"
input_file=""
check_docker=0
findings=0

usage() {
    cat <<'EOF'
Usage: audit-listening-ports.sh [--allow "PROTO/PORT ..."] [--firewalled "PROTO/PORT ..."]
                                [--file FILE] [--docker]

  --allow       public ports on purpose, e.g. "tcp/80 tcp/443 udp/41641"
                (default: "udp/41641", the mesh VPN client)
  --firewalled  ports open on all interfaces but closed by the host firewall
                (default: "tcp/22", SSH allowed on the mesh interface only)
  --file        read the output of `ss -H -tuln` from FILE instead of running ss
  --docker      also check the ports published by running containers
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow|--firewalled|--file)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 2
            fi
            case "$1" in
                --allow) allow="$2" ;;
                --firewalled) firewalled="$2" ;;
                *) input_file="$2" ;;
            esac
            shift 2
            ;;
        --docker) check_docker=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# classify SOURCE PROTO ADDRESS PORT
classify() {
    local source="$1" proto="$2" addr="$3" port="$4" status
    addr="${addr%%\%*}"   # 127.0.0.53%lo -> 127.0.0.53
    addr="${addr#\[}"     # [::1] -> ::1
    addr="${addr%\]}"
    case "$addr" in
        127.*|::1)
            status="LOOPBACK" ;;
        0.0.0.0|::|'*'|'')
            if [ "$source" = "socket" ] && [[ " $firewalled " == *" $proto/$port "* ]]; then
                status="FILTERED"
            elif [[ " $allow " == *" $proto/$port "* ]]; then
                status="ALLOWED"
            else
                status="FINDING"
                findings=$((findings + 1))
            fi
            ;;
        *)
            status="SPECIFIC" ;;
    esac
    printf '%-9s %-12s %-4s %s port %s\n' "$status" "$source" "$proto" "${addr:-*}" "$port"
}

# Where the socket list comes from. Checked here, in the main shell: an exit
# inside the process substitution below would not stop the script.
source_mode="ss"
if [ -n "$input_file" ]; then
    if [ ! -r "$input_file" ]; then
        echo "Cannot read $input_file" >&2
        exit 2
    fi
    source_mode="file"
elif [ ! -t 0 ]; then
    source_mode="stdin"
elif ! command -v ss >/dev/null 2>&1; then
    echo "ss not found: use --file with saved output" >&2
    exit 2
fi

read_sockets() {
    case "$source_mode" in
        file) cat -- "$input_file" ;;
        stdin) cat ;;
        *) ss -H -tuln ;;
    esac
}

echo "Allowed public ports: $allow"
echo "Closed by the firewall: $firewalled (confirm from outside with nmap)"
echo

# ss columns: Netid State Recv-Q Send-Q Local:Port Peer:Port [Process]
sockets=0
while read -r netid _ _ _ laddr _; do
    case "$netid" in
        tcp|udp) ;;
        *) continue ;;   # header line or another socket type
    esac
    sockets=$((sockets + 1))
    classify "socket" "$netid" "${laddr%:*}" "${laddr##*:}"
done < <(read_sockets)

# Every server listens on something (at least SSH). An empty list means the
# input was empty, for example stdin redirected from /dev/null by cron.
if [ "$sockets" -eq 0 ]; then
    echo "No socket read: the input was empty. Run on the node, or pass --file." >&2
    exit 2
fi

if [ "$check_docker" -eq 1 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "docker not found" >&2
        exit 2
    fi
    # Ports column example: 0.0.0.0:3001->3001/tcp, [::]:3001->3001/tcp
    while IFS=$'\t' read -r name ports; do
        IFS=',' read -ra mappings <<< "$ports"
        for mapping in "${mappings[@]}"; do
            mapping="${mapping# }"
            case "$mapping" in
                *"->"*) ;;
                *) continue ;;   # exposed in the image but not published
            esac
            host="${mapping%%->*}"
            classify "docker:$name" "${mapping##*/}" "${host%:*}" "${host##*:}"
        done
    done < <(docker ps --format '{{.Names}}\t{{.Ports}}')
fi

echo
if [ "$findings" -gt 0 ]; then
    echo "$findings socket(s) open on all interfaces and not on the allow-list."
    echo "Bind them to 127.0.0.1 or to the mesh address, or add them to --allow if they are public on purpose."
    exit 1
fi
echo "No unexpected socket open on all interfaces."
