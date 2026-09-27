# linux-systems-toolkit

[![CI](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Bash 4.4+](https://img.shields.io/badge/Bash-4.4%2B-green.svg)
![Tested on Ubuntu | AlmaLinux | Arch](https://img.shields.io/badge/Tested%20on-Ubuntu%20%7C%20AlmaLinux%20%7C%20Arch-orange.svg)

> **[日本語のドキュメントはこちら (Japanese README)](README.ja.md)**

Five Bash tools for everyday Linux operations: health monitoring, backups, network triage, log-disk emergencies and CIS-aligned hardening checks. Each one ships with a hardened systemd unit, and all are covered by fixture-based tests in CI on three distributions.

They need nothing beyond what a stock server already has: bash, coreutils, awk, `iproute2` and systemd. `zstd` and `dig` are used when present.

| Tool | Answers the question | Kind | systemd |
| :--- | :--- | :--- | :--- |
| [`sys-health-audit`](#sys-health-audit) | Is this host healthy right now? | check | hourly timer |
| [`sys-backup-rotate`](#sys-backup-rotate) | Do I have verified backups with sane retention? | action | nightly timer |
| [`net-socket-triage`](#net-socket-triage) | Are sockets piling up, is something exposed, is DNS slow? | check | — |
| [`sys-log-pruner`](#sys-log-pruner) | `/var/log` is filling up. Free space safely. | action | every 15 min |
| [`sys-cis-audit`](#sys-cis-audit) | How far is this server from a CIS Level 1 baseline? | check | — |

---

## Quick start

```bash
git clone https://github.com/leodarshantech/linux-systems-toolkit.git
cd linux-systems-toolkit

./bin/sys-health-audit              # human-readable report
./bin/sys-health-audit --json | jq  # one JSON document for log shippers
sudo ./bin/sys-cis-audit            # hardening score (root gives complete results)
```

Install system-wide (tools in `/usr/local/bin`, units in `/etc/systemd/system`):

```bash
sudo make install
sudo systemctl daemon-reload
sudo systemctl enable --now sys-health-audit.timer sys-log-pruner.timer sys-backup-rotate.timer
```

`make install PREFIX=/usr` or `DESTDIR=/staging` work as usual. The `ExecStart=` paths in the units are rewritten to match.

---

## Exit codes

The **checks** follow the Nagios / Zabbix plugin convention, so they can be wired into monitoring as they are:

| Code | Checks (`sys-health-audit`, `net-socket-triage`) | `sys-cis-audit` | Actions (`sys-backup-rotate`, `sys-log-pruner`) |
| :--: | :--- | :--- | :--- |
| 0 | OK | all checks pass | success |
| 1 | WARNING | at least one check fails | failure |
| 2 | CRITICAL | — | usage error |
| 3 | UNKNOWN (bad usage) | UNKNOWN (bad usage) | — |

A typo in a flag exits **3**, never 2, so a broken cron line is not mistaken for a critical outage.

---

## `sys-health-audit`

A single-pass audit of the things that usually cause 3 a.m. pages.

```text
==============================================================================
                    SYSTEM HEALTH & SECURITY POSTURE AUDIT
==============================================================================
Host: web01 | Kernel: 5.14.0-503.el9.x86_64 | Uptime: 20d 1h 8m

[  OK  ] CPU Load           1m: 0.42, 5m: 0.55, 15m: 0.61 (4 CPUs, 15% of capacity)
[  OK  ] Memory (RAM)       3.9 GiB / 7.6 GiB (50.7% used)
[  OK  ] Swap Space         84.1 MiB / 2.0 GiB (4.1% used)
[ WARN ] Disk Storage       3 filesystem(s) audited
         ├─ / [xfs]: 29.8 GiB / 70.0 GiB (43% used)
         ├─ /boot [xfs]: 393.0 MiB / 960.0 MiB (41% used)
         └─ /var/lib/mysql [ext4]: 173.1 GiB / 196.7 GiB (93% used)  WARN
[  OK  ] Inode Table        Inode usage per filesystem
         ├─ / [xfs]: 612033 / 36700160 (2% used)
         ├─ /boot [xfs]: 359 / 524288 (1% used)
         └─ /var/lib/mysql [ext4]: 402117 / 13107200 (4% used)
[  OK  ] Systemd Units      No failed units
[ WARN ] Process Table      1 zombie process(es); fix or restart the parent to reap
         └─ PID 2211 (php-fpm) ← parent PID 1893 (php-fpm)
[  OK  ] Security (SSH)     47 failed login attempt(s) in last 24h
         ├─ 203.0.113.50: 41 attempt(s)
         └─ 198.51.100.23: 6 attempt(s)
------------------------------------------------------------------------------
Audit Result: WARNINGS DETECTED (EXIT 1)
==============================================================================
```

| Check | How it is measured | Default WARN:CRIT |
| :--- | :--- | :--- |
| CPU load | 15-min load average ÷ online CPUs (`/sys/devices/system/cpu/online`) | `--cpu 80:90` |
| Memory | `MemTotal − MemAvailable`, so reclaimable page cache is not counted as used | `--mem 85:95` |
| Swap | `SwapTotal − SwapFree` | `--swap 75:95` |
| Disk space | `df` on ext2/3/4, xfs, btrfs, f2fs, zfs and vfat (`/boot/efi`) | `--disk 85:95` |
| Inodes | `df -i`; btrfs/zfs/vfat allocate inodes dynamically and are shown as such | `--inode 85:95` |
| systemd | `systemctl list-units --state=failed` | any failed unit is CRIT |
| Zombies | `/proc/*/stat`, reports each zombie's parent (the process to fix) | any zombie is WARN |
| SSH | journal entries from `sshd` and `sshd-session`, with the top source IPs | `--ssh 100` (WARN) |

A few decisions that matter in production:

- **Load average is not CPU usage.** Linux counts tasks in uninterruptible I/O sleep (`D` state), so a high load with idle CPUs points at storage, not compute. It is normalized against *all* online CPUs, not the process's CPU affinity.
- **One entry per filesystem.** btrfs subvolumes and bind mounts share a device. They are folded into one entry (`"mounts": ["/", "/home", …]`), so a full disk is reported once.
- **Zombie parsing is robust.** The process name in `/proc/PID/stat` can contain spaces or `)` (Firefox's `Web Content`). The state is read from after the *last* `)`.
- **SSH failures are counted once.** One line per failed attempt (`Failed password|publickey …`); PAM's duplicate `authentication failure` lines are ignored. If the system journal is not readable, the check reports `SKIP` instead of a false "0 failures".
- **JSON is one line** with every string escaped (unit names such as `luks\x2droot` stay valid). The systemd unit writes one document per run to the journal, ready for Fluent Bit or Vector.

---

## `sys-backup-rotate`

`tar` + `zstd` (or `gzip`) backups with a `sha256sum`-compatible checksum per archive and grandfather-father-son retention.

```bash
sudo sys-backup-rotate --dest /var/backups/sys-backup-rotate /etc /root \
     --exclude '/root/.cache'
sudo sys-backup-rotate --dest /var/backups/sys-backup-rotate --verify     # checksum + stream test
sudo sys-backup-rotate --dest /var/backups/sys-backup-rotate --prune-only --dry-run
```

```text
INFO  creating web01_20270112T023512.tar.zst from: /etc /root
INFO  created web01_20270112T023512.tar.zst (4.1 MiB in 2s, sha256 9f2c61d0a8e4b7c3…)
INFO  retention (7d/4w/3m): kept 14, deleted 1
```

- **Safe writes.** The archive is written to a hidden `.partial` file and self-tested (`zstd -t` / `gzip -t`), then renamed into place. A crash never leaves a half-written archive that looks valid.
- **Private by default.** `umask 077` applies, because a backup of `/etc` contains `/etc/shadow`.
- **Retention works like borg/restic.** `--keep-daily 7 --keep-weekly 4 --keep-monthly 3` keeps the newest archive of each period, and an archive already kept by an earlier rule does not count again. With daily backups that means about 3 months of history in 14 archives.
- **Metadata is preserved.** ACLs and xattrs are always kept, SELinux labels when SELinux is active. The backup directory is always excluded from its own sources, and an `flock` stops the timer and a manual run from colliding.
- **Configuration.** The systemd unit reads `/etc/sys-backup-rotate.conf` (`BACKUP_SOURCES`, `BACKUP_DEST`, `BACKUP_OPTS`).

Restore:

```bash
cd /var/backups/sys-backup-rotate && sha256sum -c web01_20270112T023512.tar.zst.sha256
sudo tar --zstd -xpf web01_20270112T023512.tar.zst -C /srv/restore
```

---

## `net-socket-triage`

The first five minutes of a network incident, in one command.

```text
[ INFO ] TCP States         ESTAB 212, TIME-WAIT 1450, CLOSE-WAIT 190, LISTEN 4
[ WARN ] CLOSE-WAIT         190 socket(s) (warn at 100; app not closing sockets)
         ├─ local port 8080: 187 socket(s)
         └─ local port 9000: 3 socket(s)
[  OK  ] SYN-RECV           0 half-open (warn at 100; syncookies=1)
[  OK  ] TIME-WAIT          1450 socket(s) = 5% of 28232 ephemeral ports
[ WARN ] Listening Ports    4 non-loopback, 1 not in allowlist
         ├─ tcp 22     0.0.0.0            sshd            allowed
         ├─ tcp 443    0.0.0.0            nginx           allowed
         ├─ tcp 6379   0.0.0.0            redis-server    WARN unexpected
         └─ tcp 8080   0.0.0.0            java            allowed
[  OK  ] DNS Latency        resolve example.com (warn at 250 ms)
         ├─ 127.0.0.53: 2 ms
         ├─ 1.1.1.1: 9 ms
         └─ 8.8.8.8: 31 ms
```

| Signal | What it usually means |
| :--- | :--- |
| **CLOSE-WAIT** piling up | The peer closed, but the local application never called `close()`. That is a socket or file-descriptor leak, and the top local port names the service. |
| **SYN-RECV** backlog | Half-open handshakes, a possible SYN flood. `tcp_syncookies` is shown next to it. |
| **TIME-WAIT** vs. ephemeral range | Each TIME-WAIT socket holds a local port for about 60 s. Near the `ip_local_port_range` size, outbound connections fail with `EADDRNOTAVAIL`. |
| Unexpected listener | Anything bound to a non-loopback address that is not in the `--allow` file (example: [`etc/net-socket-triage.allow`](etc/net-socket-triage.allow)). |
| DNS | Resolver latency through `/etc/resolv.conf`, 1.1.1.1 and 8.8.8.8 (`dig`). A failing *system* resolver is CRIT; an unreachable public one is only WARN, since it may just be an egress firewall. |

Run it as root to see which process owns every socket.

---

## `sys-log-pruner`

Does nothing until the filesystem holding `/var/log` reaches the threshold (default 90%). Above it:

1. `journalctl --vacuum-size=500M` removes *archived* journal files.
2. It deletes *rotated* logs older than 7 days: `*.gz`, `*.xz`, `*.zst`, `*.bz2`, `*.old`, `*.1`, and dateext files like `messages-20260901`.

Active log files are never touched. `--dry-run` lists what would go. If usage is still above the threshold afterwards, it exits 1. The systemd unit then fails, and `sys-health-audit` reports it as a failed unit, so a human finds whichever file is actually growing.

---

## `sys-cis-audit`

A read-only check of 32 settings aligned with **CIS Benchmark Level 1 (server)**. It changes nothing.

```text
SSH Server
[ PASS ] SSH-01   Root login disabled                  permitrootlogin = no
[ PASS ] SSH-02   Empty passwords rejected             permitemptypasswords = no
[ FAIL ] SSH-03   MaxAuthTries is 4 or less            maxauthtries = 6
...
Kernel & Network Parameters
[ PASS ] KRN-01   Full ASLR enabled                    kernel.randomize_va_space=2 (want 2)
[ FAIL ] NET-01   IP forwarding disabled               net.ipv4.ip_forward=1 (want 0)
...
Filesystems
[ PASS ] FS-01    /tmp is a separate filesystem        tmpfs
[ PASS ] FS-02    /tmp nodev,nosuid,noexec             all options set
[ FAIL ] FS-03    /dev/shm nodev,nosuid,noexec         missing: noexec
...
------------------------------------------------------------------------------
Score: 83% (26 passed, 5 failed, 1 skipped)
```

| Section | Checks |
| :--- | :--- |
| SSH (`SSH-01`…`08`) | root login, empty passwords, MaxAuthTries ≤ 4, IgnoreRhosts, host-based auth, LoginGraceTime ≤ 60 s, LogLevel, idle timeout |
| Kernel / network (`KRN-01`, `KRN-02`, `NET-01`…`09`) | ASLR, SUID core dumps, forwarding, redirects, source routing, martians, broadcast ICMP, SYN cookies, rp_filter, IPv6 RA |
| Filesystems (`FS-01`…`03`) | `/tmp` separate; `nodev,nosuid,noexec` on `/tmp` and `/dev/shm` |
| Files (`FILE-01`…`06`) | owner and mode of `passwd`, `group`, `shadow`, `gshadow`, `sshd_config`, `crontab` |
| Accounts (`ACC-01`, `ACC-02`) | only root has UID 0; no empty password hashes |
| Services (`SVC-01`, `SVC-02`) | a host firewall and time synchronization are active |

As root, SSH settings come from `sshd -T` (the effective config). Otherwise `sshd_config` is parsed the way sshd reads it: `Include` expansion, first value wins, `Match` blocks ignored, and OpenSSH defaults for unset keywords. Waive a check that does not apply with `--skip`, for example `--skip NET-01` on a Kubernetes node that must forward packets.

Check IDs belong to this toolkit. CIS numbering differs between the RHEL, Ubuntu and distribution-independent benchmarks.

---

## systemd hardening

Each unit runs with the least privilege its job needs. `systemd-analyze security` exposure scores (0 = fully locked down, 10 = unrestricted) are checked in CI:

| Unit | Runs as | Can write | Capabilities | Exposure |
| :--- | :--- | :--- | :--- | :--: |
| `sys-health-audit.service` | `DynamicUser` + `systemd-journal` group | nothing | none | **1.1** |
| `sys-log-pruner.service` | root | `/var/log` only | `DAC_OVERRIDE`, `DAC_READ_SEARCH`, `FOWNER` | **1.5** |
| `sys-backup-rotate.service` | root | `/var/backups` only | `DAC_READ_SEARCH` | **1.6** |

All three also use `ProtectSystem=strict`, `PrivateNetwork`, `PrivateDevices`, the `ProtectKernel*` options, `RestrictNamespaces`, `MemoryDenyWriteExecute` and `SystemCallFilter=@system-service`. (The original v1 unit scored 6.0.)

`sys-health-audit.service` sets `SuccessExitStatus=1 2`, because WARN/CRIT are audit *results*. If they failed the unit, the next hourly run would report its own failed unit and latch the host at CRIT indefinitely.

---

## Development

```bash
make check          # ShellCheck + all test suites
make verify-units   # systemd-analyze verify + security scores
```

The tests never depend on the machine they run on. Every tool reads `/proc`, `/sys`, `/etc` and `/run` through `$LST_ROOT`, and external commands (`df`, `ss`, `systemctl`, `journalctl`, `dig`) through `$PATH`. Each test builds a fixture tree plus command stubs, then asserts on the JSON output. Cases covered include btrfs subvolumes, process names with spaces, `\x2d` unit names, a CLOSE-WAIT leak, a SYN flood, sshd `Include`/`Match` parsing and exact GFS retention across 120 days.

CI runs ShellCheck, then the suites inside **Ubuntu 24.04, AlmaLinux 10 and Arch Linux** containers, then verifies and test-installs the systemd units.

```text
bin/         the five tools
lib/         common.sh: output, thresholds, JSON escaping, logging
systemd/     service + timer units
etc/         example configuration installed to /etc
tests/       lib.sh harness + one test_*.sh per tool
```

---

## Contributing

This is a personal learning, homelab and career-portfolio repository, so external pull requests are not accepted. You are welcome to fork and adapt it under the MIT License.

## License

[MIT](LICENSE). Author: **Leo Darshan** ([@leodarshantech](https://github.com/leodarshantech)).
