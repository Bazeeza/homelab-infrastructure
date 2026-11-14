#!/usr/bin/env bash
# backup-rotate.sh - write a dated archive of one folder, then keep the newest N.
#
#   sudo /usr/local/sbin/backup-rotate.sh --source /var/lib/<service> --dest /var/backups/<service> --keep 7
#   bash scripts/backup-rotate.sh --source ./data --dest /tmp/bk --keep 3 --dry-run
#
# What it does, in this order:
#   1. archives SOURCE into DEST/NAME-YYYYmmddTHHMMSSZ.tar.gz (time in UTC);
#      the archive is written under a temporary name and renamed at the end,
#      so an interrupted run never leaves a file that looks complete;
#   2. writes NAME-...tar.gz.sha256 next to it (checked by verify-backup.sh);
#   3. only if 1 and 2 succeeded: deletes the oldest archives of NAME so that
#      KEEP remain. Files that do not match the NAME-<timestamp>.tar.gz pattern
#      are never touched.
#
# Rotation keeps a COUNT, not an age: if the job stops running, the last good
# archives stay instead of expiring one by one.
#
# Everything is created with umask 077: a backup is as sensitive as its source.
# Stop or pause a service that writes to SOURCE first if its files must be
# consistent with each other (see docs/backup/).
#
# Exit codes: 0 done, 1 the backup failed (nothing was rotated), 2 usage error.
# Explained in docs/backup/README.md and ADR 0008.

set -euo pipefail
umask 077

source_dir=""
dest_dir=""
name=""
keep=7
dry_run=0

usage() {
    cat <<'EOF'
Usage: backup-rotate.sh --source DIR --dest DIR [--name NAME] [--keep N] [--dry-run]

  --source   folder to back up
  --dest     folder that receives the archives (created with mode 700 if missing)
  --name     archive prefix, letters, digits, dot, dash, underscore
             (default: the last part of --source)
  --keep     number of archives of NAME to keep, at least 1 (default: 7)
  --dry-run  print what would be written and deleted, change nothing
EOF
}

die()  { echo "error: $*" >&2; exit 2; }
fail() { echo "backup failed: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source|--dest|--name|--keep)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; usage >&2; exit 2; }
            case "$1" in
                --source) source_dir="$2" ;;
                --dest)   dest_dir="$2" ;;
                --name)   name="$2" ;;
                --keep)   keep="$2" ;;
            esac
            shift 2
            ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$source_dir" ] && [ -n "$dest_dir" ] || { usage >&2; exit 2; }
[ -d "$source_dir" ] || die "source is not a folder: $source_dir"
[[ "$keep" =~ ^[0-9]+$ ]] && [ "$keep" -ge 1 ] || die "--keep must be a whole number of at least 1"
keep=$((10#$keep))   # "08" would otherwise be read as an octal number below

source_abs="$(cd "$source_dir" && pwd -P)"
[ "$source_abs" != "/" ] || die "refusing to archive the whole file system"
[ -n "$name" ] || name="$(basename "$source_abs")"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe archive name: $name"

# The destination must not be inside the source: the archive would contain
# itself and grow at every run.
if [ -d "$dest_dir" ]; then
    dest_abs="$(cd "$dest_dir" && pwd -P)"
else
    parent="$(dirname "$dest_dir")"
    [ -d "$parent" ] || die "parent of the destination does not exist: $parent"
    dest_abs="$(cd "$parent" && pwd -P)/$(basename "$dest_dir")"
fi
case "$dest_abs/" in
    "$source_abs/"*) die "the destination is inside the source" ;;
esac

# BACKUP_NOW lets the tests create several archives without waiting.
stamp="${BACKUP_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"
[[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "BACKUP_NOW must look like 20260101T040000Z"

archive="$name-$stamp.tar.gz"
pattern="^$(printf '%s' "$name" | sed 's/[.]/\\./g')-[0-9]{8}T[0-9]{6}Z\.tar\.gz$"

# Existing archives of this name, oldest first (the timestamp sorts as text).
existing=()
if [ -d "$dest_abs" ]; then
    shopt -s nullglob
    for f in "$dest_abs/$name"-*.tar.gz; do
        b="$(basename "$f")"
        [[ "$b" =~ $pattern ]] && existing+=("$b")
    done
    shopt -u nullglob
fi
for b in "${existing[@]+"${existing[@]}"}"; do
    [ "$b" != "$archive" ] || fail "$archive already exists; refusing to overwrite it"
done

# How many old archives go once the new one exists.
total=$(( ${#existing[@]} + 1 ))
remove=$(( total > keep ? total - keep : 0 ))

if [ "$dry_run" -eq 1 ]; then
    echo "would write: $dest_abs/$archive"
    echo "would write: $dest_abs/$archive.sha256"
    i=0
    while [ "$i" -lt "$remove" ]; do
        echo "would delete: $dest_abs/${existing[$i]}"
        i=$((i + 1))
    done
    echo "would keep: $keep archive(s) of $name"
    exit 0
fi

mkdir -p "$dest_abs"
chmod 700 "$dest_abs"

partial="$dest_abs/.$archive.partial"
trap 'rm -f "$partial"' EXIT

tar -C "$(dirname "$source_abs")" -czf "$partial" "$(basename "$source_abs")" \
    || fail "tar could not read $source_abs"
mv "$partial" "$dest_abs/$archive"
( cd "$dest_abs" && sha256sum "$archive" > "$archive.sha256" ) \
    || fail "could not write the checksum"
echo "wrote: $dest_abs/$archive"

i=0
while [ "$i" -lt "$remove" ]; do
    old="${existing[$i]}"
    rm -f "$dest_abs/$old" "$dest_abs/$old.sha256"
    echo "deleted: $dest_abs/$old"
    i=$((i + 1))
done
echo "kept: $keep archive(s) of $name"
