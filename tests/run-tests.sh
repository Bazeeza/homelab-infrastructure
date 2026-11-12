#!/usr/bin/env bash
# Tests of the network scripts. No root, no network, no real node needed:
# the audit script reads saved `ss` output from tests/fixtures, and the
# firewall script is only run in its default "print the plan" mode.
#
#   bash tests/run-tests.sh
#
# Exit code: 0 all tests pass, 1 at least one failure.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
audit="$here/../scripts/audit-listening-ports.sh"
ufw_plan="$here/../scripts/ufw-baseline.sh"
fixtures="$here/fixtures"
passed=0
failed=0

ok()   { passed=$((passed + 1)); printf 'PASS  %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; }

# expect_code NAME EXPECTED_CODE COMMAND...   (stdin is always /dev/null)
expect_code() {
    local name="$1" expected="$2" code=0
    shift 2
    "$@" >/dev/null 2>&1 </dev/null || code=$?
    if [ "$code" -eq "$expected" ]; then ok "$name"; else fail "$name (exit $code, expected $expected)"; fi
}

# expect_count NAME EXPECTED_COUNT REGEX COMMAND...   counts matching output lines
expect_count() {
    local name="$1" expected="$2" regex="$3" count
    shift 3
    count="$("$@" 2>/dev/null </dev/null | grep -cE "$regex")"
    if [ "$count" -eq "$expected" ]; then ok "$name"; else fail "$name ($count lines, expected $expected)"; fi
}

echo "== audit-listening-ports.sh"
expect_code  "clean node passes"                   0 bash "$audit" --file "$fixtures/ss-clean.txt"
expect_count "loopback sockets recognised"         4 '^LOOPBACK '  bash "$audit" --file "$fixtures/ss-clean.txt"
expect_count "SSH on all interfaces is FILTERED"   2 '^FILTERED .* port 22$' bash "$audit" --file "$fixtures/ss-clean.txt"
expect_count "mesh client port is ALLOWED"         2 '^ALLOWED .* port 41641$' bash "$audit" --file "$fixtures/ss-clean.txt"
expect_count "specific address is reported"        1 '^SPECIFIC .*192\.0\.2\.20 port 45876$' bash "$audit" --file "$fixtures/ss-clean.txt"
expect_code  "exposed node fails"                  1 bash "$audit" --file "$fixtures/ss-exposed.txt"
expect_count "each exposed socket is a finding"    3 '^FINDING ' bash "$audit" --file "$fixtures/ss-exposed.txt"
expect_code  "public ports on the allow-list pass" 0 bash "$audit" --file "$fixtures/ss-exposed.txt" --allow "udp/41641 tcp/443 tcp/5678"
expect_code  "SSH not firewalled is a finding"     1 bash "$audit" --file "$fixtures/ss-clean.txt" --firewalled ""
expect_code  "empty input is refused"              2 bash "$audit"
expect_code  "missing file is refused"             2 bash "$audit" --file "$fixtures/does-not-exist.txt"
expect_code  "unknown option is refused"           2 bash "$audit" --bogus
expect_code  "option without value is refused"     2 bash "$audit" --allow

echo "== ufw-baseline.sh (plan mode only)"
expect_code  "node-a plan prints"                  0 bash "$ufw_plan" --role node-a
expect_count "node-a opens 80 and 443"             2 '^  ufw allow (80|443)/tcp ' bash "$ufw_plan" --role node-a
expect_count "node-b opens nothing public"         0 '^  ufw allow (80|443)/tcp ' bash "$ufw_plan" --role node-b
expect_count "SSH allowed on the mesh interface"   1 '^  ufw allow in on tailscale0 to any port 22 proto tcp ' bash "$ufw_plan" --role node-b
expect_count "public SSH rules are removed"        3 '^  ufw delete allow ' bash "$ufw_plan" --role node-b
expect_count "custom mesh interface is used"       1 '^  ufw allow in on wg-test to any port 22 ' bash "$ufw_plan" --role node-b --mesh-interface wg-test
expect_code  "missing role is refused"             2 bash "$ufw_plan"
expect_code  "unknown role is refused"             2 bash "$ufw_plan" --role node-c
expect_code  "unknown option is refused"           2 bash "$ufw_plan" --role node-a --bogus

# The mesh rule must come before the removal of the public SSH rules.
order="$(bash "$ufw_plan" --role node-b | grep -nE '^  ufw (allow in on|delete allow)' | cut -d: -f1 | tr '\n' ' ')"
first="${order%% *}"
second="$(printf '%s' "$order" | awk '{ print $2 }')"
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
    ok "mesh SSH rule is added before public rules are removed"
else
    fail "mesh SSH rule is added before public rules are removed"
fi

if [ "$(id -u)" -ne 0 ]; then
    expect_code "--apply without root is refused"  1 bash "$ufw_plan" --role node-b --apply
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
