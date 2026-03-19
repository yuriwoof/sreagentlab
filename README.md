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

## パラメータの準備

`main.parameters.json` にはユーザー固有の値を設定する必要があります。以下のコマンドで各値を取得してください。

### sshPublicKey — SSH 公開鍵

```bash
cat ~/.ssh/id_rsa.pub
```

鍵が存在しない場合は新規に作成します。

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
cat ~/.ssh/id_rsa.pub
```

### alertEmail — アラート通知先メールアドレス

Azure Monitor のアラート通知を受け取るメールアドレスを設定します。自分の業務用メールアドレスを使用してください。

### allowedSshSource — SSH 接続元 IP アドレス

自分のパブリック IP を CIDR 表記で指定します。

```bash
curl -s https://ifconfig.me
```

取得した IP に `/32` を付けて設定します（例: `203.0.113.10/32`）。

### deployerPrincipalId — デプロイユーザーの Azure AD オブジェクト ID

SRE Agent へのポータルアクセスに必要です。以下のコマンドで取得します。

```bash
az ad signed-in-user show --query id -o tsv
```

### 設定例

```bash
# 各値を取得して変数に格納
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
MY_IP=$(curl -s https://ifconfig.me)
DEPLOYER_ID=$(az ad signed-in-user show --query id -o tsv)

echo "sshPublicKey:        $SSH_KEY"
echo "allowedSshSource:    ${MY_IP}/32"
echo "deployerPrincipalId: $DEPLOYER_ID"
```

取得した値を `main.parameters.json` の対応するフィールドに設定してください。

## クイックスタート

```bash
# 1. パラメータを設定
cp main.parameters.json main.parameters.local.json
# → 上記「パラメータの準備」で取得した値を設定

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
