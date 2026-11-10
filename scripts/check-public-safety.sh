#!/usr/bin/env bash
# check-public-safety.sh - fail if a tracked file could leak a real value.
#
# Scans every file tracked by Git for IPv4 addresses outside the documentation
# ranges, mesh VPN addresses, private keys, known token formats and sensitive
# file names. Extra private patterns (real hostnames, real domains) can be
# given in a file that is NOT in the repository:
#   EXTRA_PATTERNS_FILE=/path/to/patterns.txt   one extended regex per line
#   EXTRA_PATTERNS="regex1
#   regex2"                                     same, from an environment variable
# Exit code: 0 = nothing found, 1 = at least one finding, 2 = usage error.
# See docs/anonymization.md.

set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: run this script inside the Git repository" >&2
    exit 2
}
cd "$root"

findings=0

report() {
    # $1 = rule name, $2 = grep output (file:line:match)
    local rule="$1" hits="$2"
    if [ -n "$hits" ]; then
        # Show where the problem is, but never print the matched value itself:
        # the CI log is public too.
        while IFS= read -r hit; do
            printf 'FAIL [%s] %s\n' "$rule" "$(printf '%s' "$hit" | cut -d: -f1,2)"
            findings=$((findings + 1))
        done <<< "$hits"
    fi
}

# Tracked text files only (binary files such as PNG are skipped by grep -I)
mapfile -d '' files < <(git ls-files -z)
if [ "${#files[@]}" -eq 0 ]; then
    echo "No tracked files."
    exit 0
fi

scan() {
    # $1 = extended regex; prints file:line:match for every match
    grep -nHoIE -- "$1" "${files[@]}" 2>/dev/null || true
}

# 1. IPv4 addresses outside loopback, 0.0.0.0 and the RFC 5737 documentation ranges
ipv4='\b(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}\b'
allowed='^(127\.|0\.0\.0\.0$|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)'
ip_hits="$(scan "$ipv4" | while IFS= read -r line; do
    ip="${line##*:}"
    if ! printf '%s' "$ip" | grep -qE "$allowed"; then
        printf '%s\n' "$line"
    fi
done)"
report "IPv4 address outside documentation ranges" "$ip_hits"

# 2. Mesh VPN addresses: shared address space 100.64/10 (RFC 6598).
#    Already caught by rule 1, reported separately because it is the most likely leak.
report "mesh VPN address (100.64/10)" \
    "$(scan '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b')"

# 3. Private keys
report "private key" "$(scan '-----BEGIN [A-Z ]*PRIVATE KEY-----')"

# 4. Token formats
report "GitHub token"       "$(scan 'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}')"
report "AWS access key"     "$(scan 'AKIA[0-9A-Z]{16}')"
report "Slack token"        "$(scan 'xox[baprs]-[A-Za-z0-9-]{10,}')"
report "Telegram bot token" "$(scan '\b[0-9]{8,10}:[A-Za-z0-9_-]{35}\b')"

# 5. Sensitive file names that must never be tracked
sensitive="$(printf '%s\n' "${files[@]}" \
    | grep -E '(^|/)(\.env(\..+)?|id_(rsa|ecdsa|ed25519)|.+\.(pem|key|pfx|p12|tfstate|tfvars))$' \
    | grep -vE '(\.env\.example|\.tfvars\.example)$' || true)"
if [ -n "$sensitive" ]; then
    while IFS= read -r f; do
        printf 'FAIL [sensitive file] %s\n' "$f"
        findings=$((findings + 1))
    done <<< "$sensitive"
fi

# 6. Extra private patterns, kept outside the repository
extra="${EXTRA_PATTERNS:-}"
if [ -n "${EXTRA_PATTERNS_FILE:-}" ]; then
    if [ ! -r "$EXTRA_PATTERNS_FILE" ]; then
        echo "error: cannot read EXTRA_PATTERNS_FILE" >&2
        exit 2
    fi
    extra="$extra"$'\n'"$(cat "$EXTRA_PATTERNS_FILE")"
fi
count_extra=0
while IFS= read -r pattern; do
    pattern="${pattern%$'\r'}"
    [ -z "$pattern" ] && continue
    case "$pattern" in \#*) continue ;; esac
    count_extra=$((count_extra + 1))
    # grep -i: hostnames and domains are case-insensitive
    hits="$(grep -nHoIiE -- "$pattern" "${files[@]}" 2>/dev/null || true)"
    report "private pattern #$count_extra" "$hits"
done <<< "$extra"

echo "Scanned ${#files[@]} tracked files, $count_extra extra private pattern(s)."
if [ "$findings" -gt 0 ]; then
    echo "$findings finding(s): replace the values with placeholders (docs/anonymization.md)."
    exit 1
fi
echo "No real value found."
