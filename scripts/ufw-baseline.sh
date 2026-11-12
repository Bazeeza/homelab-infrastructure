#!/usr/bin/env bash
# Print (default) or apply the host firewall baseline of a node.
#
#   bash scripts/ufw-baseline.sh --role node-a            # show the plan, change nothing
#   sudo bash scripts/ufw-baseline.sh --role node-b --apply
#
# Baseline: deny every inbound connection, allow SSH only on the mesh VPN
# interface, remove the public SSH rules, and open only the public services
# of the role. Explained in docs/network/host-firewall.md.
#
# Lockout guards in --apply mode:
#   - the mesh interface must exist and have an address;
#   - when run over SSH, the session must itself come through the mesh
#     (otherwise the next step would cut it). Override with --force only from
#     the provider web console.
#
# Exit codes: 0 done (or plan printed), 1 refused by a guard, 2 usage error.

set -euo pipefail

role=""
apply=0
force=0
mesh_if="tailscale0"

usage() {
    cat <<'EOF'
Usage: ufw-baseline.sh --role node-a|node-b [--apply] [--force] [--mesh-interface NAME]

  --role             node-a: also allows public HTTP and HTTPS
                     node-b: nothing public
  --apply            run the commands (needs root); without it, only print them
  --force            skip the "SSH session must come through the mesh" guard
  --mesh-interface   mesh VPN interface name (default: tailscale0)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --role|--mesh-interface)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 2
            fi
            if [ "$1" = "--role" ]; then role="$2"; else mesh_if="$2"; fi
            shift 2
            ;;
        --apply) apply=1; shift ;;
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$role" in
    node-a|node-b) ;;
    *)
        echo "--role must be node-a or node-b" >&2
        usage >&2
        exit 2
        ;;
esac

# Print the command, and run it in --apply mode.
step() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
    if [ "$apply" -eq 1 ]; then
        "$@"
    fi
}

# Same, but a failure is expected when the rule does not exist.
step_optional() {
    printf '  '
    printf '%q ' "$@"
    printf '  # ignored if absent\n'
    if [ "$apply" -eq 1 ]; then
        "$@" >/dev/null 2>&1 || true
    fi
}

guards() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Refused: --apply needs root (run with sudo)." >&2
        exit 1
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        echo "Refused: ufw is not installed." >&2
        exit 1
    fi
    local mesh_addrs
    mesh_addrs="$(ip -o addr show dev "$mesh_if" 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }')"
    if [ -z "$mesh_addrs" ]; then
        echo "Refused: interface $mesh_if is missing or has no address. Start the mesh VPN client first." >&2
        exit 1
    fi
    # SSH_CONNECTION = "client_ip client_port server_ip server_port"
    if [ -n "${SSH_CONNECTION:-}" ] && [ "$force" -eq 0 ]; then
        local server_ip
        server_ip="$(printf '%s' "$SSH_CONNECTION" | awk '{ print $3 }')"
        if ! printf '%s\n' "$mesh_addrs" | grep -qxF "$server_ip"; then
            echo "Refused: this SSH session does not come through $mesh_if; applying would cut it." >&2
            echo "Reconnect through the mesh VPN, or use the provider web console with --force." >&2
            exit 1
        fi
    fi
}

if [ "$apply" -eq 1 ]; then
    guards
    echo "Applying the baseline for $role:"
else
    echo "Plan for $role (nothing is changed; add --apply to run it):"
fi

echo "# 1. Default policy"
step ufw default deny incoming
step ufw default allow outgoing

echo "# 2. SSH through the mesh VPN only (added BEFORE the public rule is removed)"
step ufw allow in on "$mesh_if" to any port 22 proto tcp comment 'SSH over mesh VPN only'

echo "# 3. Remove public SSH rules left by the installation"
step_optional ufw delete allow OpenSSH
step_optional ufw delete allow 22/tcp
step_optional ufw delete allow 22

if [ "$role" = "node-a" ]; then
    echo "# 4. Public services of node-a"
    step ufw allow 80/tcp comment 'HTTP: redirect to HTTPS and certificate validation'
    step ufw allow 443/tcp comment 'HTTPS: remote management front-end and agents'
else
    echo "# 4. No public service on node-b (outbound connections only)"
fi

echo "# 5. Enable and show the result"
step ufw --force enable
step ufw status verbose
