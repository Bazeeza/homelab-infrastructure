#!/usr/bin/env bash
# Tests of the network and monitoring scripts. No root, no real node needed:
# the audit script reads saved `ss` output and the status script reads saved
# Uptime Kuma metrics from tests/fixtures; the firewall script is only run in
# its default "print the plan" mode; the cross-check only probes 127.0.0.1
# and runs with --dry-run, so no alert is ever sent; the relay installer only
# runs with --dry-run against a fake root in a temporary folder; the backup
# scripts only archive, rotate and extract files in a temporary folder.
# The relay itself is tested in Python: tests/test_telegram_relay.py.
#
#   bash tests/run-tests.sh
#
# Exit code: 0 all tests pass, 1 at least one failure.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
audit="$here/../scripts/audit-listening-ports.sh"
ufw_plan="$here/../scripts/ufw-baseline.sh"
kuma="$here/../scripts/kuma-status.sh"
cross="$here/../scripts/cross-check.sh"
installer="$here/../scripts/install-telegram-relay.sh"
fixtures="$here/fixtures"
passed=0
failed=0

work="$(mktemp -d)"
server_pid=""
# shellcheck disable=SC2317  # called by the EXIT trap
cleanup() {
    rm -rf "$work"
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

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

echo "== kuma-status.sh"
metrics="$fixtures/kuma-metrics.txt"
expect_code  "a probe down or pending fails"       1 bash "$kuma" --file "$metrics"
expect_count "one line per probe"                  8 '^(UP|DOWN|PENDING|MAINT|UNKNOWN) ' bash "$kuma" --file "$metrics"
expect_count "other metric series are skipped"     6 '^UP ' bash "$kuma" --file "$metrics"
expect_count "escaped quotes in a name are undone" 1 '^UP +Remote management "agents" port$' bash "$kuma" --file "$metrics"
expect_code  "ignored probes do not fail"          0 bash "$kuma" --file "$metrics" --ignore admin-ws --ignore "Public site"
expect_count "ignored probes are still listed"     2 '\[ignored\]$' bash "$kuma" --file "$metrics" --ignore admin-ws --ignore "Public site"
first_line="$(bash "$kuma" --file "$metrics" 2>/dev/null | head -n 1)"
case "$first_line" in
    UP*|"") fail "problems are listed first" ;;
    *) ok "problems are listed first" ;;
esac
expect_code  "empty input is refused"              2 bash "$kuma"
expect_code  "missing file is refused"             2 bash "$kuma" --file "$fixtures/does-not-exist.txt"
expect_code  "unknown option is refused"           2 bash "$kuma" --bogus

echo "== cross-check.sh (dry run, loopback only)"
state="$work/state"
# Port 1 on loopback: nothing listens, the connection is refused at once
printf '%s\n' '# test' 'PROBE=svc|tcp|127.0.0.1:1' 'THRESHOLD=3' 'TIMEOUT=2' > "$work/down.conf"
# shellcheck disable=SC2317  # called through expect_code and expect_count
run_check() { bash "$cross" --config "$1" --state-dir "$state" --dry-run; }

# Each call below is one run: the order matters, the state carries over.
expect_code  "first failure exits 1"               1 run_check "$work/down.conf"
expect_count "no alert before the threshold"       0 '^ALERT ' run_check "$work/down.conf"
expect_count "one alert at the third failure"      1 '^ALERT DOWN svc ' run_check "$work/down.conf"
expect_count "no repeated alert while still down"  0 '^ALERT ' run_check "$work/down.conf"
read -r s_count s_alerted _ < "$state/svc.state" || true
if [ "${s_count:-}" = "4" ] && [ "${s_alerted:-}" = "1" ]; then
    ok "state keeps the count and the alert flag"
else
    fail "state keeps the count and the alert flag (got '${s_count:-} ${s_alerted:-}')"
fi

if command -v python3 >/dev/null 2>&1; then
    port=18765
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work" >/dev/null 2>&1 &
    server_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then break; fi
        sleep 0.5
    done
    printf '%s\n' "PROBE=svc|tcp|127.0.0.1:$port" 'THRESHOLD=3' > "$work/up.conf"
    expect_count "recovery message after the outage" 1 '^ALERT RECOVERED svc ' run_check "$work/up.conf"
    expect_count "no second recovery message"        0 '^ALERT ' run_check "$work/up.conf"
    expect_code  "all probes up exits 0"             0 run_check "$work/up.conf"
    printf '%s\n' "PROBE=web|http|http://127.0.0.1:$port/" > "$work/http.conf"
    expect_code  "http probe passes on an answer"    0 run_check "$work/http.conf"
else
    echo "SKIP  recovery and http tests: python3 not found"
fi

printf '%s\n' 'PROBE=svc|tcp|127.0.0.1:1' 'COLOUR=blue' > "$work/unknown-key.conf"
printf '%s\n' 'PROBE=svc|udp|127.0.0.1:1' > "$work/bad-type.conf"
printf '%s\n' 'PROBE=svc|tcp|127.0.0.1:1' 'THRESHOLD=0' > "$work/bad-threshold.conf"
printf '%s\n' 'PROBE=bad name|tcp|127.0.0.1:1' > "$work/bad-name.conf"
expect_code  "missing --config is refused"         2 bash "$cross" --dry-run
expect_code  "unknown key is refused"              2 run_check "$work/unknown-key.conf"
expect_code  "unknown probe type is refused"       2 run_check "$work/bad-type.conf"
expect_code  "threshold of 0 is refused"           2 run_check "$work/bad-threshold.conf"
expect_code  "unsafe probe name is refused"        2 run_check "$work/bad-name.conf"
expect_code  "Telegram settings required to send"  2 bash "$cross" --config "$work/down.conf" --state-dir "$state"

echo "== install-telegram-relay.sh (dry run in a fake root)"
fake="$work/root"
conf="$fake/etc/telegram-relay/relay.conf"
token="$fake/etc/telegram-relay/telegram.token"
mkdir -p "$fake/etc/telegram-relay" "$fake/etc/systemd/system"
# shellcheck disable=SC2317  # called through expect_code and expect_count
install_dry() { bash "$installer" --dry-run --root "$fake" "$@"; }
write_conf() { printf '%s\n' "$@" > "$conf"; }
webhook_line='RELAY_WEBHOOK_URL=http://127.0.0.1:5678/webhook/test'

expect_code  "unknown option is refused"           2 bash "$installer" --bogus
expect_code  "--root without --dry-run is refused" 2 bash "$installer" --root "$fake"
expect_code  "missing settings file is refused"    1 install_dry
write_conf 'RELAY_ALLOWED_USER_ID=<TELEGRAM_USER_ID>' "$webhook_line"
expect_code  "placeholder left is refused"         1 install_dry
write_conf "$webhook_line"
expect_code  "missing user ID is refused"          1 install_dry
write_conf 'RELAY_ALLOWED_USER_ID=111111111' "$webhook_line"
expect_code  "missing token is refused"            1 install_dry
printf '%s\n' 'TEST' > "$token"
chmod 644 "$token"
expect_code  "token readable by others is refused" 1 install_dry
chmod 600 "$token"
expect_code  "complete preparation passes"         0 install_dry
expect_count "five planned commands"               5 '^would run: ' install_dry
expect_count "code copy is owned by root"          2 '^would run: install -o root -g root -m 644 ' install_dry
expect_code  "wrong node is refused"               1 install_dry --expect-host "not-$(hostname)"
expect_code  "right node passes"                   0 install_dry --expect-host "$(hostname)"
touch "$fake/etc/systemd/system/telegram-relay.service"
expect_code  "existing unit is never overwritten"  1 install_dry
if [ "$(id -u)" -ne 0 ]; then
    expect_code "real install without root is refused" 1 bash "$installer"
fi

echo "== backup-rotate.sh and verify-backup.sh (temporary folders only)"
backup="$here/../scripts/backup-rotate.sh"
verify="$here/../scripts/verify-backup.sh"
src="$work/svc-data"
bk="$work/backups"
mkdir -p "$src/sub"
printf '%s\n' 'one' > "$src/a.txt"
printf '%s\n' 'two' > "$src/sub/b.txt"
# shellcheck disable=SC2317  # called through expect_code and expect_count
backup_at() { BACKUP_NOW="$1" bash "$backup" --source "$src" --dest "$bk" --name svc --keep 3 "${@:2}"; }
count_archives() { find "$bk" -maxdepth 1 -name 'svc-*.tar.gz' | wc -l; }

expect_code  "missing --dest is refused"           2 bash "$backup" --source "$src"
expect_code  "keep of 0 is refused"                2 bash "$backup" --source "$src" --dest "$bk" --keep 0
expect_code  "unsafe name is refused"              2 bash "$backup" --source "$src" --dest "$bk" --name 'svc/x'
expect_code  "destination inside source refused"   2 bash "$backup" --source "$src" --dest "$src/bk"
expect_code  "malformed BACKUP_NOW is refused"     2 backup_at "yesterday"
expect_count "dry run plans archive and checksum"  2 '^would write: ' backup_at 20260101T040000Z --dry-run
if [ -e "$bk" ]; then fail "dry run creates nothing"; else ok "dry run creates nothing"; fi

for day in 01 02 03 04 05; do
    backup_at "202601${day}T040000Z" >/dev/null 2>&1 </dev/null || true
done
if [ "$(count_archives)" -eq 3 ]; then ok "rotation keeps the newest 3"; else fail "rotation keeps the newest 3 (got $(count_archives))"; fi
if [ -f "$bk/svc-20260105T040000Z.tar.gz.sha256" ] && [ ! -e "$bk/svc-20260102T040000Z.tar.gz" ] \
    && [ ! -e "$bk/svc-20260102T040000Z.tar.gz.sha256" ]; then
    ok "oldest archives and their checksums are deleted"
else
    fail "oldest archives and their checksums are deleted"
fi
printf '%s\n' 'not a backup' > "$bk/notes.txt"
printf '%s\n' 'other job' > "$bk/svc-extra-20250101T000000Z.tar.gz"
expect_count "plan deletes only the oldest"        1 '^would delete: .*svc-20260103T040000Z\.tar\.gz$' backup_at 20260106T040000Z --dry-run
backup_at 20260106T040000Z >/dev/null 2>&1 </dev/null || true
if [ -f "$bk/notes.txt" ] && [ -f "$bk/svc-extra-20250101T000000Z.tar.gz" ]; then
    ok "files outside the name pattern are never touched"
else
    fail "files outside the name pattern are never touched"
fi
expect_code  "an existing archive is not overwritten" 1 backup_at 20260106T040000Z
mode="$(stat -c '%a' "$bk")"
if [ "$mode" = "700" ]; then ok "backup folder is mode 700"; else fail "backup folder is mode 700 (got $mode)"; fi

latest="$bk/svc-20260106T040000Z.tar.gz"
expect_code  "a good archive passes"               0 bash "$verify" "$latest"
expect_count "all files are extracted"             1 '^OK +extracted 2 file' bash "$verify" "$latest"
expect_code  "--latest finds the newest archive"   0 bash "$verify" --latest "$bk" --scratch "$work"
expect_code  "a fresh archive passes the age check" 0 bash "$verify" "$latest" --max-age-hours 26
touch -d '3 days ago' "$bk/svc-20260105T040000Z.tar.gz"
expect_code  "an old archive fails the age check"  1 bash "$verify" "$bk/svc-20260105T040000Z.tar.gz" --max-age-hours 26
# Checksum of the original under the copy's name, then one byte changes
cp "$latest" "$work/tampered.tar.gz"
( cd "$work" && sha256sum tampered.tar.gz > tampered.tar.gz.sha256 )
expect_code  "a copy with its own checksum passes" 0 bash "$verify" "$work/tampered.tar.gz"
printf 'x' >> "$work/tampered.tar.gz"
expect_code  "a changed archive fails the checksum" 1 bash "$verify" "$work/tampered.tar.gz"
rm -f "$work/tampered.tar.gz.sha256"
expect_code  "a missing checksum fails"            1 bash "$verify" "$work/tampered.tar.gz"
( cd "$work" && tar -czPf "$work/absolute.tar.gz" "$src/a.txt" && sha256sum absolute.tar.gz > absolute.tar.gz.sha256 )
expect_code  "an absolute path is refused"         1 bash "$verify" "$work/absolute.tar.gz"
( cd "$src" && tar -czPf "$work/dotdot.tar.gz" ../svc-data/a.txt && cd "$work" && sha256sum dotdot.tar.gz > dotdot.tar.gz.sha256 )
expect_code  "a '..' path is refused"              1 bash "$verify" "$work/dotdot.tar.gz"
expect_code  "no archive is a usage error"         2 bash "$verify"
expect_code  "unknown option is refused"           2 bash "$verify" --bogus

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
