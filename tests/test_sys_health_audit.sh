#!/usr/bin/env bash
# Tests for bin/sys-health-audit
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$BIN/sys-health-audit"

# Stubs read their canned output from the fixture tree ($LST_ROOT).
stub df '
if [[ " $* " == *" -i "* ]]; then cat "$LST_ROOT/df-inodes.txt"; else cat "$LST_ROOT/df.txt"; fi'
stub systemctl '
[[ "$1" == list-units ]] && cat "$LST_ROOT/failed-units.txt" 2>/dev/null
exit 0'
stub journalctl '
if [[ " $* " == *" --lines=1 "* ]]; then
    [[ -e "$LST_ROOT/journal-unreadable" ]] || echo "-- probe --"
else
    cat "$LST_ROOT/sshd.log" 2>/dev/null
fi
exit 0'

DF_HEADER='Filesystem     Type  1024-blocks     Used Available Capacity Mounted on'
DFI_HEADER='Filesystem      Inodes  IUsed   IFree IUse% Mounted on'

# new_host <name>: healthy 4-CPU host; tests then overwrite individual files.
new_host() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT"/proc/sys/kernel "$ROOT"/proc/1 "$ROOT"/sys/devices/system/cpu "$ROOT"/run/systemd/system
    echo testhost > "$ROOT/proc/sys/kernel/hostname"
    echo 6.9.0-test > "$ROOT/proc/sys/kernel/osrelease"
    echo '93784.12 300000.00' > "$ROOT/proc/uptime"
    echo 0-3 > "$ROOT/sys/devices/system/cpu/online"
    echo '0.50 0.45 0.40 1/200 4242' > "$ROOT/proc/loadavg"
    cat > "$ROOT/proc/meminfo" <<'EOF'
MemTotal:        8000000 kB
MemFree:         1000000 kB
MemAvailable:    4000000 kB
Buffers:          100000 kB
Cached:          2000000 kB
SwapTotal:       2000000 kB
SwapFree:        2000000 kB
EOF
    echo '1 (systemd) S 0 1 1 0 -1 4194560 0 0 0 0' > "$ROOT/proc/1/stat"
    echo systemd > "$ROOT/proc/1/comm"
    printf '%s\n%s\n' "$DF_HEADER" \
        '/dev/sda1      ext4    41022688 10255672  28653528      27% /' > "$ROOT/df.txt"
    printf '%s\n%s\n' "$DFI_HEADER" \
        '/dev/sda1      2621440 262144 2359296   10% /' > "$ROOT/df-inodes.txt"
    : > "$ROOT/failed-units.txt"
    : > "$ROOT/sshd.log"
}

audit() {
    LST_ROOT="$ROOT" run with_stubs "$TOOL" "$@"
}

# ------------------------------------------------------------------------------
section 'CLI'
run "$TOOL" --help
assert_rc 0 '--help exits 0'
assert_contains "$OUT" 'Usage:' '--help prints usage'
run "$TOOL" --version
assert_contains "$OUT" "$(sed -n 's/^LST_VERSION="\(.*\)"/\1/p' "$REPO/lib/common.sh")" '--version matches lib version'
run "$TOOL" --bogus
assert_rc 3 'unknown option exits 3 (UNKNOWN), not 2 (CRITICAL)'
run "$TOOL" --disk
assert_rc 3 'missing option argument exits 3'
run "$TOOL" --disk abc
assert_rc 3 'non-numeric threshold exits 3'
run "$TOOL" --disk 90:80
assert_rc 3 'warning above critical exits 3'
run "$TOOL" --mem 101
assert_rc 3 'threshold above 100 exits 3'

# ------------------------------------------------------------------------------
section 'Healthy host'
new_host healthy
audit
assert_rc 0 'exit 0'
assert_contains "$OUT" 'SYSTEM IS HEALTHY (EXIT 0)' 'text verdict'
assert_contains "$OUT" 'Uptime: 1d 2h 3m' 'uptime formatted from /proc/uptime'
assert_contains "$OUT" '4 CPUs, 10% of capacity' 'load normalized by online CPUs'
audit --json
assert_json "$OUT" '--json is valid JSON'
assert_eq OK "$(json_get "$OUT" 'd["status"]')" 'JSON status OK'
assert_eq 50.0 "$(json_get "$OUT" 'd["metrics"]["memory"]["used_pct"]')" 'memory uses MemAvailable'
assert_eq 1 "$(grep -c . <<< "$OUT")" 'JSON is a single line (journal/NDJSON friendly)'
audit --quiet
assert_eq '' "$OUT" '--quiet prints nothing'

# ------------------------------------------------------------------------------
section 'CPU and memory thresholds'
new_host cpu
echo '4.00 3.90 3.80 9/200 4242' > "$ROOT/proc/loadavg"
audit --json
assert_rc 2 '95% load is CRITICAL'
assert_eq CRIT "$(json_get "$OUT" 'd["metrics"]["cpu"]["status"]')" 'cpu status CRIT'
audit --json --cpu 96:99
assert_rc 0 'custom --cpu thresholds are honored'

new_host mem
sed -i 's/^MemAvailable:.*/MemAvailable:     800000 kB/' "$ROOT/proc/meminfo"
audit --json
assert_rc 1 '90% memory is WARNING'

new_host oldkernel
sed -i '/^MemAvailable:/d' "$ROOT/proc/meminfo"
audit --json
assert_eq 3100000 "$(json_get "$OUT" 'd["metrics"]["memory"]["available_kib"]')" 'falls back to MemFree+Buffers+Cached without MemAvailable'

# ------------------------------------------------------------------------------
section 'Disks and inodes'
new_host disk
printf '%s\n%s\n%s\n%s\n' "$DF_HEADER" \
    '/dev/sda2      btrfs  243147776 233421865   9725911      96% /' \
    '/dev/sda2      btrfs  243147776 233421865   9725911      96% /home' \
    '/dev/sdb1      ext4    41022688 10255672  28653528      27% /mnt/my disk' > "$ROOT/df.txt"
printf '%s\n%s\n%s\n%s\n' "$DFI_HEADER" \
    '/dev/sda2            0      0       0     - /' \
    '/dev/sda2            0      0       0     - /home' \
    '/dev/sdb1      2621440 2359296 262144   90% /mnt/my disk' > "$ROOT/df-inodes.txt"
audit --json
assert_rc 2 '96% disk is CRITICAL'
assert_eq 2 "$(json_get "$OUT" 'len(d["metrics"]["disks"])')" 'btrfs subvolume mounts folded into one filesystem'
assert_eq '["/", "/home"]' "$(json_get "$OUT" 'd["metrics"]["disks"][0]["mounts"]')" 'all mount points kept'
assert_eq '/mnt/my disk' "$(json_get "$OUT" 'd["metrics"]["disks"][1]["mounts"][0]')" 'mount point with a space survives'
assert_eq null "$(json_get "$OUT" 'd["metrics"]["disks"][0]["inodes_used_pct"]')" 'btrfs dynamic inodes reported as null'
assert_eq WARN "$(json_get "$OUT" 'd["metrics"]["inode_status"]')" '90% inodes is WARNING'
assert_eq 243147776 "$(json_get "$OUT" 'd["metrics"]["disks"][0]["size_kib"]')" 'sizes are numbers in KiB'
audit
assert_contains "$OUT" '(+1 more mounts)' 'text output notes extra mounts'
audit --json --disk 97:99
assert_eq OK "$(json_get "$OUT" 'd["metrics"]["disk_status"]')" 'custom --disk thresholds are honored'

# ------------------------------------------------------------------------------
section 'systemd units'
new_host units
printf '%s\n' 'systemd-cryptsetup@luks\x2droot.service loaded failed failed Cryptography Setup' \
    'nginx.service loaded failed failed A high performance web server' > "$ROOT/failed-units.txt"
audit --json
assert_rc 2 'failed units are CRITICAL'
assert_json "$OUT" 'unit names with backslash escapes still give valid JSON'
assert_eq 'systemd-cryptsetup@luks\x2droot.service' \
    "$(json_get "$OUT" 'd["metrics"]["systemd"]["failed_units"][0]')" 'unit name round-trips exactly'

new_host nosystemd
rm -r "$ROOT/run/systemd"
audit --json
assert_eq SKIP "$(json_get "$OUT" 'd["metrics"]["systemd"]["status"]')" 'skipped when systemd is not PID 1'
assert_rc 0 'a skipped check does not change the exit status'

# ------------------------------------------------------------------------------
section 'Zombie processes'
new_host zombies
mkdir -p "$ROOT/proc/200" "$ROOT/proc/300"
echo '200 (Web Content) Z 1 200 200 0 -1 4194560 0 0' > "$ROOT/proc/200/stat"
echo '300 (evil) Z) S 1 300 300 0 -1 4194560 0 0' > "$ROOT/proc/300/stat"
audit --json
assert_rc 1 'zombies are WARNING'
assert_eq 1 "$(json_get "$OUT" 'd["metrics"]["zombies"]["count"]')" 'state parsed after the last ")" in comm'
assert_eq 'Web Content' "$(json_get "$OUT" 'd["metrics"]["zombies"]["processes"][0]["comm"]')" 'comm with spaces'
assert_eq systemd "$(json_get "$OUT" 'd["metrics"]["zombies"]["processes"][0]["parent_comm"]')" 'parent identified'

# ------------------------------------------------------------------------------
section 'SSH authentication failures'
new_host ssh
cat > "$ROOT/sshd.log" <<'EOF'
Failed password for root from 203.0.113.5 port 50022 ssh2
pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=203.0.113.5
Failed password for invalid user admin from 203.0.113.5 port 50023 ssh2
Failed publickey for deploy from 198.51.100.7 port 44100 ssh2
Accepted publickey for deploy from 198.51.100.7 port 44101 ssh2
EOF
audit --json
assert_eq 3 "$(json_get "$OUT" 'd["metrics"]["ssh"]["failed_logins_24h"]')" 'one count per failed attempt (PAM lines not double counted)'
assert_eq 203.0.113.5 "$(json_get "$OUT" 'd["metrics"]["ssh"]["top_sources"][0]["ip"]')" 'top offending source first'
assert_rc 0 'below --ssh threshold is OK'
audit --json --ssh 3
assert_rc 1 'at --ssh threshold is WARNING'

new_host nojournal
touch "$ROOT/journal-unreadable"
audit --json
assert_eq SKIP "$(json_get "$OUT" 'd["metrics"]["ssh"]["status"]')" 'unreadable journal is SKIP, not a false 0'

# ------------------------------------------------------------------------------
section 'JSON escaping'
new_host escaping
printf '%s\n' 'we"ird\host' > "$ROOT/proc/sys/kernel/hostname"
audit --json
assert_json "$OUT" 'hostname with quote and backslash gives valid JSON'
assert_eq 'we"ird\host' "$(json_get "$OUT" 'd["hostname"]')" 'hostname round-trips exactly'

# ------------------------------------------------------------------------------
section 'Live host smoke test'
run "$TOOL" --json
assert_json "$OUT" 'real /proc produces valid JSON'
if (( RC <= 2 )); then pass "exit status $RC is OK/WARN/CRIT"; else fail 'exit status' "got $RC"; fi

finish
