# linux-systems-toolkit 🐧 (日本語ドキュメント)

[![CI](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/leodarshantech/linux-systems-toolkit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux%20(Arch%20%7C%20RHEL%20%7C%20Debian)-orange.svg)]()

> **[English Documentation](README.md)**

`linux-systems-toolkit` は、LinuxインフラエンジニアおよびSRE向けに設計された、本番環境対応のシステム診断・健全性監視・セキュリティポスチャ監査ツールキットです。

Arch Linux、RHEL / AlmaLinux、Ubuntu / Debian などのクラウドVMやコンテナホスト環境で、外部依存関係なし（ゼロ依存）で高速かつ安全に動作します。

---

## 🛠 主な機能

### `sys-health-audit`
本番サーバーの異常やリソース枯渇を事前に検知する高精度な診断スクリプトです。
* **CPU負荷 & ロードアベレージ**: `/proc/loadavg` とコア数を照合し、1分・5分・15分の正規化負荷率を算出。
* **メモリ & スワップ実効使用率**: 単純な空きメモリではなく、カーネルの再利用可能バッファ/キャッシュを考慮した `MemAvailable` をもとに高精度に計算。
* **ディスク容量 & iノード枯渇監視**: ext4、xfs、btrfs、zfs のマウントポイントを対象に、空き容量だけでなく「iノード枯渇」による書き込み不能障害を検知。
* **systemd サービス監視**: `systemctl` と連携し、異常停止（failed / degraded）したユニットを即座に特定。
* **ゾンビプロセスの検出**: 親プロセスが回収していないゾンビプロセス（`Z` 状態）を検知。
* **セキュリティ監査**: 過去24時間のSSH不正ログイン試行（ブルートフォース攻撃）を `journalctl` から抽出・集計。
* **2つの出力モード**:
  * 端末用カラーバッジ表示（`[OK]`、`[WARN]`、`[CRIT]`）
  * ログ集約基盤（Datadog、Fluentbit、Vector、CloudWatch）向けの完全な JSON 出力（`--json`）
* **標準終了ステータスコード**: Nagios / Zabbix 監視標準に準拠（`0`: 正常、`1`: 警告、`2`: 致命的）。

---

## 🚀 クイックスタート

### 実行方法
```bash
# リポジトリのクローン
git clone https://github.com/leodarshantech/linux-systems-toolkit.git
cd linux-systems-toolkit

# 診断の実行
./bin/sys-health-audit

# JSON形式での出力
./bin/sys-health-audit --json

# スクリプトやcronでのサイレント実行（終了ステータスコードの確認）
./bin/sys-health-audit --quiet
```

### システムへのインストール
バイナリを `/usr/local/bin`、systemd ユニットを `/etc/systemd/system` に配置します：
```bash
sudo make install

# 1時間ごとの定期実行タイマーを有効化
sudo systemctl enable --now sys-health-audit.timer
```

---

## 🔒 セキュリティ & systemd サンドボックス設計

提供される `sys-health-audit.service` は、最小権限の原則（Least Privilege）に基づいて堅牢化されています：
* `NoNewPrivileges=yes`: 子プロセスによる特権昇格を禁止。
* `ProtectSystem=strict`: OSのルートファイルシステム全体を読み取り専用（Read-Only）としてマウント。
* `ProtectHome=read-only`: ユーザーのホームディレクトリへの書き込みを制限。
* `PrivateTmp=yes`: システム共有の `/tmp` からプロセスを完全分離。
* `CapabilityBoundingSet=CAP_NET_ADMIN CAP_DAC_READ_SEARCH`: 低レイヤー監査に必要な最小限のケーパビリティのみを許可し、フルルート権限を回避。

---

## 🧪 テストと品質管理

すべてのシェルスクリプトは **ShellCheck** による静的解析および自動テストスイートで検証されています：
```bash
# テストスイートの実行
make test

# 静的コード解析（ShellCheck）
make lint
```

---

## 🤝 コントリビューションについて
本リポジトリは個人の学習、ホームラボ検証、およびポートフォリオ作成を目的としています。そのため、外部からのプルリクエストやコード貢献は受け付けておりません。コードの参照や、MITライセンスに基づいた個人利用のためのフォークはご自由に行っていただけます。

---

## 📄 ライセンス
本プロジェクトは [MIT License](LICENSE) の下で公開されています。
作成者: **Leo Darshan** ([@leodarshantech](https://github.com/leodarshantech))
