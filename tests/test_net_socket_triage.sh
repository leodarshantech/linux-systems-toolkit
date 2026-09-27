#!/usr/bin/env bash
# Tests for bin/net-socket-triage
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$BIN/net-socket-triage"

# ss: "-t -a" lists all TCP sockets, "-l" lists listeners.
stub ss '
if [[ " $* " == *" -l "* ]]; then cat "$LST_ROOT/ss-listen.txt"; else cat "$LST_ROOT/ss-tcp.txt"; fi'
# dig: answers from 1.1.1.1 slowly, times out for 192.0.2.1, fast otherwise.
stub dig '
case " $* " in
  *" @192.0.2.1 "*) echo ";; communications error to 192.0.2.1#53: timed out"; exit 9 ;;
  *" @1.1.1.1 "*)   ms=400 server=1.1.1.1 ;;
  *)                ms=12  server=127.0.0.53 ;;
esac
echo ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 4242"
echo ";; Query time: $ms msec"
echo ";; SERVER: $server#53($server) (UDP)"'

new_host() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT/proc/sys/net/ipv4" "$ROOT/proc/sys/kernel"
    echo testhost > "$ROOT/proc/sys/kernel/hostname"
    printf '32768\t60999\n' > "$ROOT/proc/sys/net/ipv4/ip_local_port_range"
    echo 1 > "$ROOT/proc/sys/net/ipv4/tcp_syncookies"
    cat > "$ROOT/ss-tcp.txt" <<'EOF'
LISTEN     0      128          0.0.0.0:22          0.0.0.0:*
ESTAB      0      0         10.0.0.5:22       203.0.113.9:51234
ESTAB      0      0         10.0.0.5:44120    93.184.216.34:443
TIME-WAIT  0      0         10.0.0.5:44118    93.184.216.34:443
EOF
    cat > "$ROOT/ss-listen.txt" <<'EOF'
tcp   LISTEN 0      128        0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0      128           [::]:22           [::]:*    users:(("sshd",pid=812,fd=4))
tcp   LISTEN 0      4096     127.0.0.1:5432      0.0.0.0:*    users:(("postgres",pid=900,fd=5))
udp   UNCONN 0      0       127.0.0.53%lo:53     0.0.0.0:*    users:(("systemd-resolve",pid=500,fd=12))
EOF
}

triage() {
    LST_ROOT="$ROOT" run with_stubs "$TOOL" "$@"
}

# ------------------------------------------------------------------------------
section 'CLI'
run "$TOOL" --help
assert_rc 0 '--help exits 0'
run "$TOOL" --close-wait x
assert_rc 3 'bad number exits 3'
run "$TOOL" --allow /nonexistent
assert_rc 3 'unreadable allowlist exits 3'

# ------------------------------------------------------------------------------
section 'Quiet host'
new_host quiet
triage --json --resolvers system
assert_json "$OUT" 'valid JSON'
assert_rc 0 'exit 0'
assert_eq 2 "$(json_get "$OUT" 'd["tcp"]["states"]["established"]')" 'ESTAB counted'
assert_eq 1 "$(json_get "$OUT" 'd["tcp"]["states"]["time_wait"]')" 'TIME-WAIT counted'
assert_eq 28232 "$(json_get "$OUT" 'd["tcp"]["time_wait"]["ephemeral_ports"]')" 'ephemeral range read from /proc'
assert_eq 2 "$(json_get "$OUT" 'd["listeners"]["non_loopback"]')" 'loopback listeners (incl. 127.0.0.53%lo) excluded'
assert_eq sshd "$(json_get "$OUT" 'd["listeners"]["sockets"][0]["process"]')" 'process parsed from ss -p'
assert_eq any "$(json_get "$OUT" 'd["listeners"]["sockets"][0]["scope"]')" '0.0.0.0 is scope "any"'
assert_eq 12 "$(json_get "$OUT" 'd["dns"]["resolvers"][0]["latency_ms"]')" 'dig query time parsed'
assert_eq 127.0.0.53 "$(json_get "$OUT" 'd["dns"]["resolvers"][0]["server"]')" 'system resolver address reported'
triage --resolvers system
assert_contains "$OUT" 'Triage Result: OK (EXIT 0)' 'text verdict'

# ------------------------------------------------------------------------------
section 'Socket pile-ups'
new_host leak
for i in $(seq 1 120); do
    echo "CLOSE-WAIT 1 0 10.0.0.5:8080 10.0.0.9:$(( 40000 + i ))" >> "$ROOT/ss-tcp.txt"
done
for i in $(seq 1 5); do
    echo "CLOSE-WAIT 1 0 10.0.0.5:9090 10.0.0.9:$(( 50000 + i ))" >> "$ROOT/ss-tcp.txt"
done
triage --json --no-dns
assert_rc 1 'CLOSE-WAIT above threshold is WARNING'
assert_eq 125 "$(json_get "$OUT" 'd["tcp"]["close_wait"]["count"]')" 'CLOSE-WAIT counted'
assert_eq 8080 "$(json_get "$OUT" 'd["tcp"]["close_wait"]["top_ports"][0]["port"]')" 'leaking service port identified'
triage --json --no-dns --close-wait 200
assert_rc 0 '--close-wait threshold honored'

new_host synflood
for i in $(seq 1 150); do
    echo "SYN-RECV 0 0 10.0.0.5:443 198.51.100.$(( i % 250 )):$(( 30000 + i ))" >> "$ROOT/ss-tcp.txt"
done
triage --json --no-dns
assert_eq WARN "$(json_get "$OUT" 'd["tcp"]["syn_recv"]["status"]')" 'SYN-RECV backlog is WARNING'

new_host timewait
printf '60000\t60099\n' > "$ROOT/proc/sys/net/ipv4/ip_local_port_range"
for i in $(seq 1 60); do
    echo "TIME-WAIT 0 0 10.0.0.5:$(( 60000 + i )) 93.184.216.34:443" >> "$ROOT/ss-tcp.txt"
done
triage --json --no-dns
assert_eq 61 "$(json_get "$OUT" 'd["tcp"]["time_wait"]["pct"]')" 'TIME-WAIT as % of ephemeral range'
assert_rc 1 'ephemeral port pressure is WARNING'

# ------------------------------------------------------------------------------
section 'Listener allowlist'
new_host allow
printf '# comment\n\ntcp 22 sshd\n' > "$WORK/allow.txt"
triage --json --no-dns --allow "$WORK/allow.txt"
assert_rc 0 'all public listeners allowed'
echo 'tcp   LISTEN 0 128 0.0.0.0:6379 0.0.0.0:* users:(("redis-server",pid=1000,fd=6))' >> "$ROOT/ss-listen.txt"
triage --json --no-dns --allow "$WORK/allow.txt"
assert_rc 1 'unexpected public listener is WARNING'
assert_eq 1 "$(json_get "$OUT" 'd["listeners"]["unexpected"]')" 'one unexpected listener'
printf 'tcp 22 dropbear\n' > "$WORK/allow-wrong.txt"
triage --json --no-dns --allow "$WORK/allow-wrong.txt"
assert_eq 3 "$(json_get "$OUT" 'd["listeners"]["unexpected"]')" 'right port but wrong process is flagged'

# ------------------------------------------------------------------------------
section 'DNS'
new_host dns
triage --json --resolvers system,1.1.1.1
assert_rc 1 'slow resolver is WARNING'
assert_eq WARN "$(json_get "$OUT" 'd["dns"]["resolvers"][1]["status"]')" '400 ms over the 250 ms default'
triage --json --resolvers system,192.0.2.1
assert_eq TIMEOUT "$(json_get "$OUT" 'd["dns"]["resolvers"][1]["result"]')" 'timeout detected'
assert_rc 1 'unreachable public resolver is WARNING only'
triage --json --no-dns
assert_eq SKIP "$(json_get "$OUT" 'd["dns"]["status"]')" '--no-dns skips the benchmark'

finish
