# linux-systems-toolkit 🐧

[![CI](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux%20(Arch%20%7C%20RHEL%20%7C%20Debian)-orange.svg)]()
[![Language: Bash](https://img.shields.io/badge/Language-POSIX%20Bash-green.svg)]()

> **[日本語のドキュメント (Japanese README)](README.ja.md)**

A production-grade Linux systems diagnostic, health monitoring, and security posture toolkit engineered for site reliability and infrastructure administration.

Designed for automated headless environments, container hosts, and cloud virtual machines running Arch Linux, RHEL/AlmaLinux, and Ubuntu/Debian.

---

## 🛠 Features

### `sys-health-audit`
A zero-dependency, high-precision system auditor that performs multi-dimensional triage:
* **CPU & Load Average**: Normalizes 1m, 5m, and 15m load averages against physical/logical core counts from `/proc/loadavg` and `/proc/cpuinfo`.
* **Memory & Swap**: Accurately computes memory usage via `MemAvailable` (accounting for reclaimable kernel buffers/cache) rather than naive free memory.
* **Disk Space & Inode Exhaustion**: Audits physical mount points (ext4, xfs, btrfs, zfs) for storage saturation and inode table starvation (preventing outages where disk space is available but no new files can be written).
* **Systemd Unit Health**: Detects degraded or failing system services via `systemctl`.
* **Process Table Triage**: Flags orphaned defunct and zombie processes (`Z` state in `/proc/*/stat`).
* **Security & Auth Auditing**: Scans `journalctl` for brute-force SSH authentication failures within the trailing 24 hours.
* **Dual Output Modes**:
  * Human-readable colorized terminal interface with `[OK]`, `[WARN]`, and `[CRIT]` status badges.
  * Strict machine-readable JSON output (`--json`) for Datadog, Vector, Fluentbit, or CloudWatch log collection agents.
* **Predictable Exit Codes**: Follows standard Nagios/Zabbix monitoring conventions (`0` = Healthy, `1` = Warning, `2` = Critical).

---

## 🚀 Quick Start

### Direct Execution
```bash
# Clone the repository
git clone https://github.com/leodarshantech/linux-systems-toolkit.git
cd linux-systems-toolkit

# Run the health auditor
./bin/sys-health-audit

# Generate machine-readable JSON
./bin/sys-health-audit --json

# Run quietly in scripts or cron (checks exit code)
./bin/sys-health-audit --quiet && echo "System healthy"
```

### Installation
Install binaries to `/usr/local/bin` and systemd units to `/etc/systemd/system`:
```bash
sudo make install

# Enable the automated hourly audit timer
sudo systemctl enable --now sys-health-audit.timer
```

---

## 🖥 Terminal Output Example

```text
==============================================================================
                    SYSTEM HEALTH & SECURITY POSTURE AUDIT                    
==============================================================================
Host: archlinux | Kernel: 7.2.7-arch1-1 | Uptime: 0d 2h 37m

[  OK  ] CPU Load           1m: 0.89, 5m: 0.51, 15m: 0.58 (8 cores, ~7% load)
[  OK  ] Memory (RAM)       4.21 GiB / 7.64 GiB (55.1% used)
[  OK  ] Swap Space         97.6 MiB / 7.64 GiB (1.2% used)
[  OK  ] Disk Storage       Audited physical filesystems
           ├─ / (btrfs): 28G/232G (12% used)
           ├─ /home (btrfs): 28G/232G (12% used)
[  OK  ] Inode Table        Audited physical inodes
           ├─ /: Dynamic allocation (no fixed limit)
[  OK  ] Systemd Daemons    All units active & running normally
[  OK  ] Process Table      0 defunct/zombie processes
[  OK  ] Security (SSH)     0 failed login attempt(s) in last 24h
------------------------------------------------------------------------------
Audit Result: SYSTEM IS HEALTHY (EXIT 0)
==============================================================================
```

---

## 🔒 Systemd Sandboxing & Security

The included `sys-health-audit.service` follows strict Linux systemd security hardening:
* `NoNewPrivileges=yes`: Prevents child processes from gaining elevated privileges.
* `ProtectSystem=strict`: Mounts the entire OS root directory tree read-only for the process.
* `ProtectHome=read-only`: Restricts write access to user home directories.
* `PrivateTmp=yes`: Isolates the unit from the shared `/tmp` filesystem.
* `CapabilityBoundingSet=CAP_NET_ADMIN CAP_DAC_READ_SEARCH`: Grants minimum necessary Linux kernel capabilities without full root access.

---

## 🧪 Testing & Quality

All shell scripts are verified against **ShellCheck** and the automated regression suite:
```bash
# Run tests
make test

# Run linting (ShellCheck)
make lint
```

---

## 🤝 Contributing
This is an individual learning, homelab, and personal career portfolio repository. As such, external pull requests and code contributions are not accepted. Feel free to fork and adapt the code for your own personal use under the MIT License.

---

## 📄 License
This project is licensed under the [MIT License](LICENSE).
Author: **Leo Darshan** ([@leodarshantech](https://github.com/leodarshantech)).
