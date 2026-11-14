#!/usr/bin/env bash
# verify-backup.sh - prove that one archive written by backup-rotate.sh can be
# read and restored, without touching the live data.
#
#   bash scripts/verify-backup.sh /var/backups/<service>/<service>-20260101T040000Z.tar.gz
#   bash scripts/verify-backup.sh --latest /var/backups/<service> --max-age-hours 26
#
# Checks, in this order (the first failure stops the run):
#   1. the archive is not older than --max-age-hours (when given): a backup job
#      that silently stopped is the most common backup failure;
#   2. ARCHIVE.sha256 exists, names this archive, and the checksum matches;
#   3. the archive can be listed, and no entry is an absolute path or contains
#      a ".." component (such an entry could write outside the scratch folder);
#   4. it extracts into a scratch folder (never over the live data), without
#      restoring the original owners, and the number of regular files extracted
#      equals the number listed.
#
# The scratch folder is deleted at the end unless --keep-scratch is given, so
# the restored files can be compared with the live ones by hand.
#
# Exit codes: 0 the archive is good, 1 a check failed, 2 usage error.
# Explained in docs/backup/restore-test.md.

set -euo pipefail

archive=""
latest_dir=""
max_age_hours=""
scratch_parent=""
keep_scratch=0

usage() {
    cat <<'EOF'
Usage: verify-backup.sh ARCHIVE [options]
       verify-backup.sh --latest DIR [options]

  ARCHIVE            a NAME-YYYYmmddTHHMMSSZ.tar.gz file with its .sha256 next to it
  --latest DIR       check the newest *.tar.gz in DIR instead
  --max-age-hours N  fail if the archive is older than N hours
  --scratch DIR      create the scratch folder inside DIR (default: system temp)
  --keep-scratch     do not delete the extracted copy; print its path
EOF
}

die()   { echo "error: $*" >&2; exit 2; }
check_fail() { echo "FAIL  $*"; exit 1; }
pass()  { echo "OK    $*"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --latest|--max-age-hours|--scratch)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; usage >&2; exit 2; }
            case "$1" in
                --latest)        latest_dir="$2" ;;
                --max-age-hours) max_age_hours="$2" ;;
                --scratch)       scratch_parent="$2" ;;
            esac
            shift 2
            ;;
        --keep-scratch) keep_scratch=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            [ -z "$archive" ] || die "only one archive at a time"
            archive="$1"
            shift
            ;;
    esac
done

if [ -n "$latest_dir" ]; then
    [ -z "$archive" ] || die "give an ARCHIVE or --latest, not both"
    [ -d "$latest_dir" ] || die "not a folder: $latest_dir"
    # Pick the newest by the UTC timestamp at the end of the name, not by the
    # file date (a copy or a touch changes the date, not the name).
    newest_stamp=""
    shopt -s nullglob
    for f in "$latest_dir"/*.tar.gz; do
        b="$(basename "$f")"
        [[ "$b" =~ -[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]] || continue
        s="${b%.tar.gz}"
        s="${s##*-}"
        if [[ -z "$newest_stamp" || "$s" > "$newest_stamp" ]]; then
            newest_stamp="$s"
            archive="$f"
        fi
    done
    shopt -u nullglob
    [ -n "$archive" ] || check_fail "no NAME-YYYYmmddTHHMMSSZ.tar.gz archive in $latest_dir"
fi

[ -n "$archive" ] || { usage >&2; exit 2; }
[ -f "$archive" ] || die "not a file: $archive"
if [ -n "$max_age_hours" ]; then
    [[ "$max_age_hours" =~ ^[0-9]+$ ]] && [ "$max_age_hours" -ge 1 ] \
        || die "--max-age-hours must be a whole number of at least 1"
fi
if [ -n "$scratch_parent" ]; then
    [ -d "$scratch_parent" ] || die "scratch parent is not a folder: $scratch_parent"
fi

dir="$(cd "$(dirname "$archive")" && pwd -P)"
base="$(basename "$archive")"
echo "archive: $dir/$base"

# 1. Age
if [ -n "$max_age_hours" ]; then
    now="$(date +%s)"
    written="$(stat -c %Y "$dir/$base")"
    age_h=$(( (now - written) / 3600 ))
    if [ "$age_h" -gt "$max_age_hours" ]; then
        check_fail "archive is $age_h hours old (limit $max_age_hours): is the backup job still running?"
    fi
    pass "age: $age_h hour(s)"
fi

# 2. Checksum
sum_file="$dir/$base.sha256"
[ -f "$sum_file" ] || check_fail "no checksum file $base.sha256"
read -r _ named < "$sum_file" || true
named="${named#\*}"
[ "$named" = "$base" ] || check_fail "the checksum file names '$named', not '$base'"
if ( cd "$dir" && sha256sum --check --status "$base.sha256" ); then
    pass "checksum matches"
else
    check_fail "checksum does not match: the archive changed or is incomplete"
fi

# 3. Listing and unsafe paths
listing="$(tar -tzf "$dir/$base" 2>/dev/null)" || check_fail "tar cannot read the archive"
[ -n "$listing" ] || check_fail "the archive is empty"
while IFS= read -r entry; do
    case "$entry" in
        /*) check_fail "absolute path in the archive: $entry" ;;
    esac
    case "/$entry/" in
        */../*) check_fail "'..' in a path of the archive: $entry" ;;
    esac
done <<< "$listing"
listed_files="$(tar -tvzf "$dir/$base" | grep -c '^-' || true)"
pass "listing: $(printf '%s\n' "$listing" | wc -l) entries, $listed_files regular file(s), no unsafe path"

# 4. Extract into a scratch folder
if [ -n "$scratch_parent" ]; then
    scratch="$(mktemp -d "$scratch_parent/restore-test.XXXXXX")"
else
    scratch="$(mktemp -d)"
fi
if [ "$keep_scratch" -eq 0 ]; then
    trap 'rm -rf "$scratch"' EXIT
fi
tar -xzf "$dir/$base" -C "$scratch" --no-same-owner --no-same-permissions \
    || check_fail "extraction failed"
extracted_files="$(find "$scratch" -type f | wc -l)"
[ "$extracted_files" -eq "$listed_files" ] \
    || check_fail "extracted $extracted_files file(s), the archive lists $listed_files"
pass "extracted $extracted_files file(s) into a scratch folder"
if [ "$keep_scratch" -eq 1 ]; then
    echo "scratch kept: $scratch"
fi
echo "archive is good"
