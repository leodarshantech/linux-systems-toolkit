#!/usr/bin/env bash
# Tests for bin/sys-cis-audit
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$BIN/sys-cis-audit"

# systemctl is-active: a unit is active if listed in $LST_ROOT/active-units.txt.
stub systemctl '
[[ "$1" == is-active ]] || exit 0
for unit in "${@:2}"; do
    [[ "$unit" == --* ]] && continue
    grep -qx "$unit" "$LST_ROOT/active-units.txt" 2>/dev/null && exit 0
done
exit 3'

# sysctl <key> <value>: write a fake /proc/sys entry.
sysctl() {
    mkdir -p "$(dirname "$ROOT/proc/sys/${1//.//}")"
    echo "$2" > "$ROOT/proc/sys/${1//.//}"
}

# new_host <name>: a fully compliant host.
new_host() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT"/etc/ssh/sshd_config.d "$ROOT"/proc/sys/kernel "$ROOT"/run/systemd/system
    echo testhost > "$ROOT/proc/sys/kernel/hostname"
    cat > "$ROOT/etc/ssh/sshd_config" <<'EOF'
# Hardened baseline
Include /etc/ssh/sshd_config.d/*.conf
PermitRootLogin no
MaxAuthTries 4
LoginGraceTime 1m
ClientAliveInterval 300
LogLevel VERBOSE

Match User backup
    PermitRootLogin yes
EOF
    printf 'PermitEmptyPasswords no\n' > "$ROOT/etc/ssh/sshd_config.d/10-local.conf"
    chmod 600 "$ROOT/etc/ssh/sshd_config"
    printf 'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\n' > "$ROOT/etc/passwd"
    printf 'root:$6$salt$hash:19000::::::\nalice:$6$salt$hash:19000::::::\n' > "$ROOT/etc/shadow"
    printf 'root:x:0:\n' > "$ROOT/etc/group"
    printf 'root:::\n' > "$ROOT/etc/gshadow"
    chmod 644 "$ROOT/etc/passwd" "$ROOT/etc/group"
    chmod 600 "$ROOT/etc/shadow" "$ROOT/etc/gshadow"
    cat > "$ROOT/proc/mounts" <<'EOF'
/dev/sda2 / ext4 rw,relatime 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev,noexec 0 0
tmpfs /dev/shm tmpfs rw,nosuid,nodev,noexec 0 0
EOF
    sysctl kernel.randomize_va_space 2
    sysctl fs.suid_dumpable 0
    sysctl net.ipv4.ip_forward 0
    local scope
    for scope in all default; do
        sysctl "net.ipv4.conf.$scope.send_redirects" 0
        sysctl "net.ipv4.conf.$scope.accept_redirects" 0
        sysctl "net.ipv4.conf.$scope.accept_source_route" 0
        sysctl "net.ipv4.conf.$scope.log_martians" 1
        sysctl "net.ipv4.conf.$scope.rp_filter" 1
        sysctl "net.ipv6.conf.$scope.accept_ra" 0
    done
    sysctl net.ipv4.icmp_echo_ignore_broadcasts 1
    sysctl net.ipv4.tcp_syncookies 1
    printf 'firewalld\nchronyd\n' > "$ROOT/active-units.txt"
}

audit() {
    LST_ROOT="$ROOT" run with_stubs "$TOOL" "$@"
}

# status_of <id>: status of one check in the last JSON output.
status_of() {
    json_get "$OUT" "[c['status'] for c in d['checks'] if c['id'] == '$1'][0]"
}

# ------------------------------------------------------------------------------
section 'CLI'
run "$TOOL" --help
assert_rc 0 '--help exits 0'
run "$TOOL" --skip
assert_rc 3 '--skip without IDs exits 3'

# ------------------------------------------------------------------------------
section 'Compliant host'
new_host good
audit --json
assert_json "$OUT" 'valid JSON'
assert_rc 0 'exit 0 when nothing fails'
assert_eq 0 "$(json_get "$OUT" 'd["summary"]["failed"]')" 'no failures'
assert_eq 100 "$(json_get "$OUT" 'd["summary"]["score_pct"]')" 'score 100%'
assert_eq 'sshd_config (parsed)' "$(json_get "$OUT" 'd["sshd_source"]')" 'config parsed from file when not root'
assert_eq PASS "$(status_of SSH-02)" 'Include directive is followed'
assert_eq PASS "$(status_of SSH-01)" 'Match block does not override global settings'
assert_eq PASS "$(status_of SSH-06)" 'LoginGraceTime 1m parsed as 60s'
audit
assert_contains "$OUT" 'Score: 100%' 'text score'

# ------------------------------------------------------------------------------
section 'Non-compliant host'
new_host bad
cat > "$ROOT/etc/ssh/sshd_config" <<'EOF'
PermitRootLogin=yes
EOF
chmod 644 "$ROOT/etc/ssh/sshd_config"
sysctl net.ipv4.ip_forward 1
sysctl net.ipv4.conf.default.rp_filter 2
sed -i 's|^tmpfs /tmp tmpfs .*|tmpfs /tmp tmpfs rw,nosuid 0 0|' "$ROOT/proc/mounts"
printf 'toor:x:0:0::/root:/bin/sh\n' >> "$ROOT/etc/passwd"
printf 'guest::19000::::::\n' >> "$ROOT/etc/shadow"
chmod 666 "$ROOT/etc/passwd"
: > "$ROOT/active-units.txt"
audit --json
assert_rc 1 'exit 1 when any check fails'
assert_eq FAIL "$(status_of SSH-01)" 'Keyword=value syntax parsed (PermitRootLogin=yes)'
assert_eq FAIL "$(status_of SSH-03)" 'unset MaxAuthTries falls back to the OpenSSH default of 6'
assert_eq FAIL "$(status_of NET-01)" 'IP forwarding enabled'
assert_eq FAIL "$(status_of NET-08)" 'one of all/default rp_filter wrong is enough to fail'
assert_eq FAIL "$(status_of FS-02)" '/tmp missing nodev,noexec'
assert_contains "$(json_get "$OUT" "[c['detail'] for c in d['checks'] if c['id'] == 'FS-02'][0]")" 'nodev,noexec' 'missing mount options listed'
assert_eq FAIL "$(status_of FILE-01)" 'world-writable /etc/passwd'
assert_eq FAIL "$(status_of FILE-05)" 'sshd_config readable by others'
assert_eq FAIL "$(status_of ACC-01)" 'second UID 0 account'
assert_eq FAIL "$(status_of ACC-02)" 'empty password'
assert_eq FAIL "$(status_of SVC-01)" 'no firewall'
assert_eq FAIL "$(status_of SVC-02)" 'no time sync'

audit --json --skip net-01,SVC-01
assert_eq SKIP "$(status_of NET-01)" '--skip waives a check (case-insensitive)'
assert_eq SKIP "$(status_of SVC-01)" '--skip accepts a list'

# ------------------------------------------------------------------------------
section 'Missing inputs are skipped, not failed'
new_host minimal
rm -r "$ROOT/etc/ssh" "$ROOT/run/systemd" "$ROOT/proc/sys/net/ipv6"
sed -i '/ \/tmp /d' "$ROOT/proc/mounts"
chmod 000 "$ROOT/etc/shadow"
audit --json
assert_eq SKIP "$(status_of SSH-01)" 'no sshd_config -> SSH checks skipped'
assert_eq SKIP "$(status_of NET-09)" 'IPv6 disabled -> NET-09 skipped'
assert_eq SKIP "$(status_of SVC-01)" 'no systemd -> service checks skipped'
assert_eq FAIL "$(status_of FS-01)" '/tmp on the root filesystem fails FS-01'
assert_eq SKIP "$(status_of FS-02)" '... and FS-02 is skipped rather than double counted'
if [[ -r "$ROOT/etc/shadow" ]]; then
    pass 'running as root: unreadable-shadow case not testable'
else
    assert_eq SKIP "$(status_of ACC-02)" 'unreadable /etc/shadow -> skipped'
fi
chmod 600 "$ROOT/etc/shadow"

finish
