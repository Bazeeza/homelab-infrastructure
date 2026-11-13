#!/usr/bin/env bash
# install-telegram-relay.sh - install the Telegram relay as a hardened systemd service.
#
# Run on node-b, from a clone of this repository:
#     bash scripts/install-telegram-relay.sh --dry-run     # every check, prints the plan, changes nothing
#     sudo bash scripts/install-telegram-relay.sh          # install and start
#
# Prepared by the administrator BEFORE (see docs/relay/README.md):
#     /etc/telegram-relay/relay.conf       settings, no <PLACEHOLDER> left
#     /etc/telegram-relay/telegram.token   bot token, owner root, mode 600
#
# Creates only these two files, and never overwrites an existing unit:
#     /usr/local/lib/telegram-relay/telegram_relay.py
#     /etc/systemd/system/telegram-relay.service
#
# Options:
#     --dry-run            run every check, print the commands, change nothing (no root needed)
#     --expect-host NAME   stop unless the hostname is NAME (guards against the wrong node)
#     --root DIR           prefix for every system path; only with --dry-run (tests)
#
# Exit code: 0 done (or plan printed), 1 a check refused, 2 usage error.
#
# Rollback (undo everything):
#     sudo systemctl disable --now telegram-relay.service
#     sudo rm -f /etc/systemd/system/telegram-relay.service
#     sudo rm -rf /usr/local/lib/telegram-relay /var/lib/private/telegram-relay
#     sudo systemctl daemon-reload

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source_py="$here/../relay/telegram_relay.py"
source_unit="$here/../configs/systemd/telegram-relay.service"

dry_run=false
expect_host=""
root=""

usage() {
    echo "usage: $0 [--dry-run] [--expect-host NAME] [--root DIR]" >&2
    exit 2
}

refuse() {
    echo "STOP: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            dry_run=true
            ;;
        --expect-host|--root)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage; fi
            if [ "$1" = "--root" ]; then root="${2%/}"; else expect_host="$2"; fi
            shift
            ;;
        *)
            usage
            ;;
    esac
    shift
done

if [ -n "$root" ] && [ "$dry_run" = false ]; then
    echo "error: --root is only allowed with --dry-run" >&2
    exit 2
fi

lib_dir="$root/usr/local/lib/telegram-relay"
unit="$root/etc/systemd/system/telegram-relay.service"
conf="$root/etc/telegram-relay/relay.conf"
token="$root/etc/telegram-relay/telegram.token"

# 1. Right node, right user
if [ -n "$expect_host" ] && [ "$(hostname)" != "$expect_host" ]; then
    refuse "this node is not $expect_host (hostname check)"
fi
if [ "$dry_run" = false ] && [ "$(id -u)" -ne 0 ]; then
    refuse "run with sudo, or use --dry-run"
fi

# 2. Files from this repository
if [ ! -r "$source_py" ] || [ ! -r "$source_unit" ]; then
    refuse "run the script from a complete clone of the repository"
fi
if [ -z "$root" ] && [ ! -x /usr/bin/python3 ]; then
    refuse "/usr/bin/python3 not found (sudo apt install python3)"
fi

# 3. Never overwrite a unit that is already there
if [ -e "$unit" ]; then
    refuse "$unit already exists; remove it first (rollback steps at the top of this script)"
fi

# 4. Settings: present, required keys set, no placeholder left
if [ ! -r "$conf" ]; then
    refuse "$conf is missing: copy configs/systemd/telegram-relay.conf.example there and fill it in"
fi
for key in RELAY_ALLOWED_USER_ID RELAY_WEBHOOK_URL; do
    if ! grep -qE "^${key}=[^[:space:]]+" "$conf"; then
        refuse "$key is not set in $conf"
    fi
done
if grep -qE '^[^#]*<[A-Z_]+>' "$conf"; then
    refuse "$conf still contains a <PLACEHOLDER>"
fi

# 5. Token: present, readable by root only
if [ ! -s "$token" ]; then
    refuse "$token is missing or empty"
fi
mode="$(stat -c '%a' "$token")"
case "$mode" in
    600|400) ;;
    *) refuse "$token has mode $mode; expected 600 or 400 (root only)" ;;
esac
if [ -z "$root" ] && [ "$(stat -c '%u' "$token")" -ne 0 ]; then
    refuse "$token must belong to root"
fi

run() {
    if [ "$dry_run" = true ]; then
        printf 'would run: %s\n' "$*"
    else
        "$@"
    fi
}

# Root-owned copy: the service account cannot change the code that receives the token
run install -d -o root -g root -m 755 "$lib_dir"
run install -o root -g root -m 644 "$source_py" "$lib_dir/telegram_relay.py"
run install -o root -g root -m 644 "$source_unit" "$unit"
run systemctl daemon-reload
run systemctl enable --now telegram-relay.service

if [ "$dry_run" = true ]; then
    echo "Dry run: all checks passed, nothing changed."
    exit 0
fi

sleep 3
echo "--- state"
systemctl is-active telegram-relay.service || true
echo "--- last journal lines (expect: relay started, offset=...)"
journalctl -u telegram-relay.service -n 10 --no-pager
