# linux-systems-toolkit

[![CI](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Bash 4.4+](https://img.shields.io/badge/Bash-4.4%2B-green.svg)
![Tested on Ubuntu | AlmaLinux | Arch](https://img.shields.io/badge/Tested%20on-Ubuntu%20%7C%20AlmaLinux%20%7C%20Arch-orange.svg)

> **[English README](README.md)**

Linux サーバー運用の日常業務（ヘルスチェック、バックアップ、ネットワーク障害の一次切り分け、ログによるディスク逼迫への緊急対応、CIS 準拠のセキュリティ監査）を担う 5 つの Bash ツール群です。各ツールには堅牢化した systemd ユニットが付属し、3 つのディストリビューション上で CI によるフィクスチャベースのテストを実施しています。

標準的なサーバーに最初から入っているもの（bash、coreutils、awk、`iproute2`、systemd）だけで動作します。`zstd` と `dig` はインストールされていれば利用します。

| ツール | 答える問い | 種別 | systemd |
| :--- | :--- | :--- | :--- |
| [`sys-health-audit`](#sys-health-audit) | このホストは今、正常か？ | チェック | 1 時間ごとのタイマー |
| [`sys-backup-rotate`](#sys-backup-rotate) | 検証済みのバックアップが適切な世代数で残っているか？ | アクション | 毎晩のタイマー |
| [`net-socket-triage`](#net-socket-triage) | ソケットが滞留していないか、不要なポートが公開されていないか、DNS は遅くないか？ | チェック | — |
| [`sys-log-pruner`](#sys-log-pruner) | `/var/log` が逼迫している。安全に空き容量を確保したい | アクション | 15 分ごと |
| [`sys-cis-audit`](#sys-cis-audit) | CIS Level 1 のベースラインにどこまで準拠しているか？ | チェック | — |

---

## クイックスタート

```bash
git clone https://github.com/leodarshantech/linux-systems-toolkit.git
cd linux-systems-toolkit

./bin/sys-health-audit              # 人が読むためのレポート
./bin/sys-health-audit --json | jq  # ログ収集基盤向けの JSON（1 行）
sudo ./bin/sys-cis-audit            # 堅牢化スコア（root で実行すると全項目を判定）
```

システムへのインストール（ツールは `/usr/local/bin`、ユニットは `/etc/systemd/system` に配置）：

```bash
sudo make install
sudo systemctl daemon-reload
sudo systemctl enable --now sys-health-audit.timer sys-log-pruner.timer sys-backup-rotate.timer
```

`make install PREFIX=/usr` や `DESTDIR=/staging` も通常どおり使えます。ユニット内の `ExecStart=` のパスも自動的に書き換えられます。

---

## 終了ステータス

**チェック系**ツールは Nagios / Zabbix のプラグイン規約に従っているため、そのまま監視システムに組み込めます。

| コード | チェック（`sys-health-audit`、`net-socket-triage`） | `sys-cis-audit` | アクション（`sys-backup-rotate`、`sys-log-pruner`） |
| :--: | :--- | :--- | :--- |
| 0 | OK | 全項目合格 | 成功 |
| 1 | WARNING | 1 つ以上不合格 | 失敗 |
| 2 | CRITICAL | — | 使い方の誤り |
| 3 | UNKNOWN（使い方の誤り） | UNKNOWN（使い方の誤り） | — |

オプションの打ち間違いは 2 ではなく **3** で終了します。そのため、cron の設定ミスが「致命的な障害」と誤認されることはありません。

---

## `sys-health-audit`

深夜の呼び出しにつながりやすい項目を、1 回の実行でまとめて監査します。

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

| 項目 | 計測方法 | 既定の WARN:CRIT |
| :--- | :--- | :--- |
| CPU 負荷 | 15 分ロードアベレージ ÷ オンライン CPU 数（`/sys/devices/system/cpu/online`） | `--cpu 80:90` |
| メモリ | `MemTotal − MemAvailable`（回収可能なページキャッシュは使用中に含めない） | `--mem 85:95` |
| スワップ | `SwapTotal − SwapFree` | `--swap 75:95` |
| ディスク容量 | ext2/3/4、xfs、btrfs、f2fs、zfs、vfat（`/boot/efi`）を `df` で確認 | `--disk 85:95` |
| iノード | `df -i`。btrfs/zfs/vfat は動的割り当てとして表示 | `--inode 85:95` |
| systemd | `systemctl list-units --state=failed` | 失敗ユニットがあれば CRIT |
| ゾンビプロセス | `/proc/*/stat` を解析し、対処すべき親プロセスも表示 | 1 つでもあれば WARN |
| SSH | `sshd` / `sshd-session` のジャーナルから失敗回数と上位の送信元 IP を集計 | `--ssh 100`（WARN） |

本番運用で効いてくる設計判断：

- **ロードアベレージは CPU 使用率ではありません。** Linux は I/O 待ちで割り込み不可能なスリープ状態（`D` 状態）のタスクもロードに数えます。CPU が空いているのにロードが高いなら、原因は計算資源ではなくストレージ側を疑います。正規化には、プロセスの CPU アフィニティではなく、オンラインの全 CPU 数を使います。
- **ファイルシステム単位で 1 エントリ。** btrfs のサブボリュームやバインドマウントは同じデバイスを共有します。これらを 1 件（`"mounts": ["/", "/home", …]`）にまとめるので、満杯のディスクが重複して報告されることはありません。
- **ゾンビプロセスの判定が壊れません。** `/proc/PID/stat` のプロセス名には空白や `)` が含まれることがあります（例：Firefox の `Web Content`）。状態は*最後の* `)` の後ろから読み取ります。
- **SSH の失敗は 1 回ずつ数えます。** 1 回の失敗につき 1 行（`Failed password|publickey …`）を数え、PAM が重複して出す `authentication failure` 行は除外します。システムジャーナルを読めない場合は、誤って「0 件」とは報告せず `SKIP` とします。
- **JSON は 1 行出力です。** 文字列はすべてエスケープ済みで、`luks\x2droot` のようなユニット名でも JSON が壊れません。systemd ユニットは実行ごとに 1 件の JSON をジャーナルへ書き込むので、Fluent Bit や Vector でそのまま収集できます。

---

## `sys-backup-rotate`

`tar` + `zstd`（または `gzip`）でアーカイブを作成し、`sha256sum` 互換のチェックサムを付けて、GFS（祖父・父・子）方式で世代管理します。

```bash
sudo sys-backup-rotate --dest /var/backups/sys-backup-rotate /etc /root \
     --exclude '/root/.cache'
sudo sys-backup-rotate --dest /var/backups/sys-backup-rotate --verify     # チェックサム + 圧縮ストリーム検証
sudo sys-backup-rotate --dest /var/backups/sys-backup-rotate --prune-only --dry-run
```

```text
INFO  creating web01_20270112T023512.tar.zst from: /etc /root
INFO  created web01_20270112T023512.tar.zst (4.1 MiB in 2s, sha256 9f2c61d0a8e4b7c3…)
INFO  retention (7d/4w/3m): kept 14, deleted 1
```

- **安全な書き込み。** 隠しファイル `.partial` に書き出して自己検証（`zstd -t` / `gzip -t`）してから、正式な名前にリネームします。途中でクラッシュしても、正常に見える壊れたアーカイブは残りません。
- **既定で非公開。** `/etc` のバックアップには `/etc/shadow` が含まれるため、`umask 077` で作成します。
- **世代管理は borg / restic と同じ考え方です。** `--keep-daily 7 --keep-weekly 4 --keep-monthly 3` は各期間の最新アーカイブを残し、先のルールですでに残したものは後のルールで重複して数えません。毎日バックアップする場合、14 個のアーカイブで約 3 か月分の履歴を保持できます。
- **メタデータを保持します。** ACL と拡張属性は常に、SELinux ラベルは SELinux が有効な場合に保持します。バックアップ先ディレクトリは常にバックアップ対象から除外され、`flock` によってタイマー実行と手動実行の競合を防ぎます。
- **設定。** systemd ユニットは `/etc/sys-backup-rotate.conf`（`BACKUP_SOURCES`、`BACKUP_DEST`、`BACKUP_OPTS`）を読み込みます。

リストア：

```bash
cd /var/backups/sys-backup-rotate && sha256sum -c web01_20270112T023512.tar.zst.sha256
sudo tar --zstd -xpf web01_20270112T023512.tar.zst -C /srv/restore
```

---

## `net-socket-triage`

ネットワーク障害の「最初の 5 分」でやる確認を、1 コマンドにまとめています。

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

| 兆候 | 多くの場合の意味 |
| :--- | :--- |
| **CLOSE-WAIT** の滞留 | 相手は切断したのに、自ホストのアプリケーションが `close()` を呼んでいない状態です。ソケット（ファイルディスクリプタ）リークであり、上位のローカルポートから原因のサービスを特定できます。 |
| **SYN-RECV** の蓄積 | ハーフオープン接続で、SYN フラッド攻撃の可能性があります。`tcp_syncookies` の設定もあわせて表示します。 |
| **TIME-WAIT** とエフェメラルポート範囲 | TIME-WAIT のソケットはそれぞれ約 60 秒間ローカルポートを占有します。`ip_local_port_range` の上限に近づくと、外向きの接続が `EADDRNOTAVAIL` で失敗します。 |
| 想定外の待ち受け | ループバック以外のアドレスで待ち受けていて、`--allow` ファイル（例：[`etc/net-socket-triage.allow`](etc/net-socket-triage.allow)）にないもの。 |
| DNS | `/etc/resolv.conf` のリゾルバ、1.1.1.1、8.8.8.8 の応答時間（`dig`）。*システム*のリゾルバが失敗したら CRIT です。公開リゾルバに届かないだけなら、送信側ファイアウォールの可能性もあるため WARN にとどめます。 |

root で実行すると、すべてのソケットの所有プロセスを表示できます。

---

## `sys-log-pruner`

`/var/log` を含むファイルシステムの使用率がしきい値（既定 90%）に達するまでは何もしません。しきい値を超えたら次の処理を行います。

1. `journalctl --vacuum-size=500M` で*アーカイブ済み*のジャーナルファイルを削除します。
2. 7 日より古い*ローテート済み*ログを削除します：`*.gz`、`*.xz`、`*.zst`、`*.bz2`、`*.old`、`*.1`、`messages-20260901` のような dateext 形式。

書き込み中のログファイルには一切触れません。`--dry-run` では削除対象の一覧だけを表示します。処理後もしきい値を超えている場合は終了コード 1 を返します。すると systemd ユニットが失敗状態になり、`sys-health-audit` がそれを失敗ユニットとして報告するので、実際に肥大化しているファイルを人が調査できます。

---

## `sys-cis-audit`

**CIS Benchmark Level 1（サーバー）** に沿った 32 項目を確認する、読み取り専用の監査ツールです。システムには一切変更を加えません。

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

| 区分 | 確認内容 |
| :--- | :--- |
| SSH（`SSH-01`〜`08`） | root ログイン、空パスワード、MaxAuthTries ≤ 4、IgnoreRhosts、ホストベース認証、LoginGraceTime ≤ 60 秒、LogLevel、アイドルタイムアウト |
| カーネル / ネットワーク（`KRN-01`、`KRN-02`、`NET-01`〜`09`） | ASLR、SUID プログラムのコアダンプ、IP フォワーディング、ICMP リダイレクト、ソースルーティング、Martian パケット、ブロードキャスト ICMP、SYN クッキー、rp_filter、IPv6 RA |
| ファイルシステム（`FS-01`〜`03`） | `/tmp` の分離、`/tmp` と `/dev/shm` の `nodev,nosuid,noexec` |
| ファイル（`FILE-01`〜`06`） | `passwd`、`group`、`shadow`、`gshadow`、`sshd_config`、`crontab` の所有者とパーミッション |
| アカウント（`ACC-01`、`ACC-02`） | UID 0 は root のみ、空のパスワードハッシュがないこと |
| サービス（`SVC-01`、`SVC-02`） | ホストファイアウォールと時刻同期が稼働していること |

root で実行した場合は、`sshd -T`（実際に有効な設定）から SSH の設定値を取得します。それ以外の場合は、sshd と同じ規則で `sshd_config` を解析します：`Include` を展開し、最初に現れた値を採用し、`Match` ブロックは対象外とし、未設定の項目には OpenSSH の既定値を使います。該当しない項目は `--skip` で除外できます（例：パケット転送が必須の Kubernetes ノードでは `--skip NET-01`）。

チェック ID は本ツール独自のものです。CIS の項目番号は RHEL 版、Ubuntu 版、ディストリビューション非依存版でそれぞれ異なります。

---

## systemd の堅牢化

各ユニットは、その処理に必要な最小限の権限で動作します。`systemd-analyze security` の露出スコア（0 = 完全に制限、10 = 無制限）は CI で確認しています。

| ユニット | 実行ユーザー | 書き込み可能な場所 | ケーパビリティ | 露出スコア |
| :--- | :--- | :--- | :--- | :--: |
| `sys-health-audit.service` | `DynamicUser` + `systemd-journal` グループ | なし | なし | **1.1** |
| `sys-log-pruner.service` | root | `/var/log` のみ | `DAC_OVERRIDE`、`DAC_READ_SEARCH`、`FOWNER` | **1.5** |
| `sys-backup-rotate.service` | root | `/var/backups` のみ | `DAC_READ_SEARCH` | **1.6** |

3 つとも `ProtectSystem=strict`、`PrivateNetwork`、`PrivateDevices`、`ProtectKernel*` 系、`RestrictNamespaces`、`MemoryDenyWriteExecute`、`SystemCallFilter=@system-service` を適用しています（v1 のユニットは 6.0 でした）。

`sys-health-audit.service` は `SuccessExitStatus=1 2` を設定しています。WARN / CRIT は監査の*結果*であって、ユニットの失敗ではないためです。これをユニット失敗として扱うと、次の定時実行で自分自身が失敗ユニットとして検出され、ホストが CRIT のまま固定されてしまいます。

---

## 開発

```bash
make check          # ShellCheck + 全テストスイート
make verify-units   # systemd-analyze verify + セキュリティスコア
```

テスト結果は実行するマシンに依存しません。各ツールは `/proc`、`/sys`、`/etc`、`/run` を `$LST_ROOT` 経由で、外部コマンド（`df`、`ss`、`systemctl`、`journalctl`、`dig`）を `$PATH` 経由で参照します。テストごとにフィクスチャのディレクトリツリーとコマンドのスタブを用意し、JSON 出力に対して検証します。btrfs のサブボリューム、空白を含むプロセス名、`\x2d` を含むユニット名、CLOSE-WAIT のリーク、SYN フラッド、sshd の `Include` / `Match` の解析、120 日分の GFS 世代管理の厳密な結果などをテストしています。

CI では ShellCheck を実行した後、**Ubuntu 24.04、AlmaLinux 10、Arch Linux** のコンテナ内でテストスイートを実行し、最後に systemd ユニットの検証とテストインストールを行います。

```text
bin/         5 つのツール
lib/         common.sh：出力、しきい値、JSON エスケープ、ログ出力
systemd/     サービス + タイマーユニット
etc/         /etc に配置する設定ファイルの例
tests/       lib.sh（テスト基盤）+ ツールごとの test_*.sh
```

---

## コントリビューションについて

本リポジトリは、個人の学習、ホームラボでの検証、キャリアポートフォリオを目的としています。そのため、外部からのプルリクエストは受け付けていません。MIT ライセンスの範囲で、フォークして自由にご利用ください。

## ライセンス

[MIT](LICENSE)。作成者：**Leo Darshan**（[@leodarshantech](https://github.com/leodarshantech)）
