# SRE Agent Lab

Azure SRE Agent + Chaos Studio を使ったインシデント対応デモ環境です。

## フォルダ構成

```
sreagentlab/
├── main.bicep                    # Bicep メインテンプレート
├── main.parameters.json          # パラメータファイル (テンプレート)
├── modules/
│   ├── network.bicep             # VNet / Subnet / NSG / Public IP
│   ├── vm.bicep                  # Linux VM + nginx + Managed Identity
│   ├── monitoring.bicep          # Log Analytics + AMA + Metric Alerts
│   └── chaos.bicep               # Chaos Studio Targets / Experiments
├── scripts/
│   ├── deploy.sh                 # ワンクリックデプロイ
│   ├── run-chaos.sh              # Chaos 実験の実行 (cpu|memory|nginx)
│   └── cleanup.sh               # リソース全削除
└── docs/
    ├── demo-scenario.md          # デモシナリオ全体の手順書
    ├── sre-agent-setup.md        # SRE Agent のセットアップガイド
    └── runbook-template.md       # Runbook のテンプレート + プロンプト例
```

## クイックスタート

```bash
# 1. パラメータを設定
cp main.parameters.json main.parameters.local.json
# → SSH 公開鍵、メールアドレス、許可 IP を編集

# 2. デプロイ
export RESOURCE_GROUP="rg-sreagentlab"
export LOCATION="eastus2"
./scripts/deploy.sh

# 3. SRE Agent をセットアップ (Azure Portal)
#    → docs/sre-agent-setup.md を参照

# 4. Chaos 実験を実行
./scripts/run-chaos.sh cpu

# 5. SRE Agent で調査 → 修復 → Runbook 生成

# 6. クリーンアップ
./scripts/cleanup.sh
```

## デモで使うシナリオ

| # | シナリオ | Chaos Fault | 期待するSRE Agent動作 |
|---|---------|-------------|---------------------|
| 1 | CPU 異常高騰 | CPU Pressure 95% (10分) | CPU分析 → プロセス特定 → 修復提案 |
| 2 | メモリ圧迫 | Memory Pressure 90% (10分) | メモリ分析 → OOMリスク評価 → 修復提案 |
| 3 | サービス停止 | nginx Stop (5分) | サービス状態確認 → 再起動 → 復旧確認 |

## ドキュメント

- [デモシナリオ全手順](docs/demo-scenario.md)
- [SRE Agent セットアップ](docs/sre-agent-setup.md)
- [Runbook テンプレート](docs/runbook-template.md)
- [Azure ポータルで手動構築手順](docs/azure-portal-setup.md)
