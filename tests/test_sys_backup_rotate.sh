#!/usr/bin/env bash
# Tests for bin/sys-backup-rotate
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$BIN/sys-backup-rotate"
SRC="$WORK/src"
DEST="$WORK/backups"

mkdir -p "$SRC/etc/app" "$SRC/cache"
echo 'listen 8080' > "$SRC/etc/app/app.conf"
echo 'secret' > "$SRC/etc/app/token"
chmod 600 "$SRC/etc/app/token"
echo 'junk' > "$SRC/cache/blob"

# ------------------------------------------------------------------------------
section 'CLI'
run "$TOOL" --help
assert_rc 0 '--help exits 0'
run "$TOOL" "$SRC"
assert_rc 2 'missing --dest is a usage error (2)'
run "$TOOL" --dest "$DEST"
assert_rc 2 'missing SOURCE is a usage error'
run "$TOOL" --dest "$DEST" --name 'bad/name' "$SRC"
assert_rc 2 'unsafe --name is rejected'
run "$TOOL" --dest "$DEST" --keep-daily 0 --keep-weekly 0 --keep-monthly 0 "$SRC"
assert_rc 2 'retention that keeps nothing is rejected'
run "$TOOL" --dest "$DEST" --compress lz4 "$SRC"
assert_rc 2 'unknown compressor is rejected'
run "$TOOL" --dest "$DEST" "$WORK/does-not-exist"
assert_rc 1 'missing source fails'

# ------------------------------------------------------------------------------
section 'Create, checksum, verify (gzip)'
run "$TOOL" --dest "$DEST" --name web --compress gzip --exclude "$SRC/cache" "$SRC"
assert_rc 0 'backup succeeds'
archive="$(cd "$DEST" && ls web_*.tar.gz)"
if [[ "$archive" =~ ^web_[0-9]{8}T[0-9]{6}\.tar\.gz$ ]]; then
    pass 'archive named NAME_YYYYmmddTHHMMSS.tar.gz'
else
    fail 'archive name' "$archive"
fi
assert_eq 600 "$(stat -c %a "$DEST/$archive")" 'archive is private (0600): it may contain secrets'
assert_eq 700 "$(stat -c %a "$DEST")" 'backup directory created 0700'
if (cd "$DEST" && sha256sum --quiet -c "$archive.sha256"); then
    pass 'sidecar works with sha256sum -c'
else
    fail 'sidecar works with sha256sum -c'
fi
listing="$(tar -tzf "$DEST/$archive")"
assert_contains "$listing" 'etc/app/app.conf' 'files are archived'
assert_not_contains "$listing" 'cache/blob' '--exclude with an absolute path works'
assert_not_contains "$listing" "$(basename "$DEST")/" 'backup directory is never archived into itself'
mkdir -p "$WORK/restore"
tar -xzpf "$DEST/$archive" -C "$WORK/restore"
assert_eq 600 "$(stat -c %a "$WORK/restore$SRC/etc/app/token")" 'restores to the original path with modes preserved'

run "$TOOL" --dest "$DEST" --name web --verify
assert_rc 0 '--verify passes on intact archives'
printf 'x' | dd of="$DEST/$archive" bs=1 seek=40 conv=notrunc status=none
run "$TOOL" --dest "$DEST" --name web --verify
assert_rc 1 '--verify fails after corruption'
assert_contains "$ERR" 'checksum mismatch' 'corruption reported'
rm -f "$DEST"/web_*

# ------------------------------------------------------------------------------
if command -v zstd >/dev/null 2>&1; then
    section 'zstd'
    run "$TOOL" --dest "$DEST" --name db --compress zstd "$SRC"
    assert_rc 0 'zstd backup succeeds'
    run "$TOOL" --dest "$DEST" --name db --verify
    assert_rc 0 'zstd archive verifies'
    rm -f "$DEST"/db_*
fi

# ------------------------------------------------------------------------------
section 'Source containing the destination'
run "$TOOL" --dest "$SRC/backups" --name self --compress gzip "$SRC"
assert_rc 0 'backup succeeds'
assert_not_contains "$(tar -tzf "$SRC"/backups/self_*.tar.gz)" 'backups/self_' 'no archive-inside-archive'
rm -rf "$SRC/backups"

# ------------------------------------------------------------------------------
section 'GFS retention (7 daily, 4 weekly, 3 monthly)'
# One archive per day, 2026-01-01 .. 2026-04-30 (a Thursday).
mkdir -p "$WORK/gfs"
d=20260101
while [[ "$d" -le 20260430 ]]; do
    : > "$WORK/gfs/host_${d}T023000.tar.gz"
    : > "$WORK/gfs/host_${d}T023000.tar.gz.sha256"
    d="$(date -d "$d + 1 day" +%Y%m%d)"
done
: > "$WORK/gfs/other_20250101T000000.tar.gz"
: > "$WORK/gfs/notes.txt"

run "$TOOL" --dest "$WORK/gfs" --name host --prune-only --dry-run
assert_eq 120 "$(find "$WORK/gfs" -name 'host_*.tar.gz' | wc -l)" '--dry-run deletes nothing'

run "$TOOL" --dest "$WORK/gfs" --name host --prune-only
assert_rc 0 'prune succeeds'
kept="$(find "$WORK/gfs" -name 'host_*.tar.gz' -printf '%f\n' | sed 's/^host_\(.\{8\}\).*/\1/' | sort | tr '\n' ' ')"
# daily:   Apr 24-30
# weekly:  newest per ISO week not already kept -> Apr 19, 12, 5, Mar 29
# monthly: newest per month not already kept   -> Mar 31, Feb 28, Jan 31
expected='20260131 20260228 20260329 20260331 20260405 20260412 20260419 20260424 20260425 20260426 20260427 20260428 20260429 20260430 '
assert_eq "$expected" "$kept" 'kept exactly the 14 expected archives'
assert_eq 14 "$(find "$WORK/gfs" -name 'host_*.sha256' | wc -l)" 'checksums pruned with their archives'
if [[ -e "$WORK/gfs/other_20250101T000000.tar.gz" && -e "$WORK/gfs/notes.txt" ]]; then
    pass 'files of other names are never touched'
else
    fail 'files of other names are never touched'
fi

finish
