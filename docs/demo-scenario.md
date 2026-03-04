# Azure SRE Agent + Chaos Studio デモシナリオ

## 概要

このデモでは、Azure Chaos Studio を使って仮想マシン (VM) に障害を注入し、Azure SRE Agent が自動でインシデントを検知・調査・修復する一連の流れを示します。最終的に SRE Agent へ Runbook (手順書) の生成を指示し、運用ナレッジとして蓄積します。

### アーキテクチャ図

```
┌──────────────────────────────────────────────────────────┐
│                    Resource Group                         │
│  ┌───────────────┐    ┌──────────────────┐               │
│  │  Linux VM      │◄───│  Chaos Studio    │               │
│  │  (nginx +      │    │  Experiments     │               │
│  │   stress-ng)   │    │  - CPU Pressure  │               │
│  └───────┬────────┘    │  - Memory Press. │               │
│          │             │  - Stop nginx    │               │
│          │             └──────────────────┘               │
│          ▼                                                │
│  ┌───────────────┐    ┌──────────────────┐               │
│  │ Azure Monitor  │───►│  Metric Alerts   │               │
│  │ Agent (AMA)    │    │  - High CPU      │               │
│  └───────┬────────┘    │  - Low Memory    │               │
│          │             └────────┬─────────┘               │
│          ▼                      │                         │
│  ┌───────────────┐              ▼                         │
│  │ Log Analytics  │    ┌──────────────────┐               │
│  │ Workspace      │◄───│  Azure SRE Agent │               │
│  └───────────────┘    │  (自動調査/修復)  │               │
│                        └──────────────────┘               │
└──────────────────────────────────────────────────────────┘
```

## 前提条件

| 要件 | 詳細 |
|------|------|
| Azure サブスクリプション | 有効なサブスクリプションが必要 |
| Azure CLI | v2.60 以上 (`az --version` で確認) |
| Bicep CLI | Azure CLI に同梱 (`az bicep version` で確認) |
| SSH キーペア | VM 認証用 (`ssh-keygen -t rsa -b 4096` で生成) |
| ロール | サブスクリプションの Contributor + User Access Administrator |
| SRE Agent Preview | Preview 登録済み ([登録手順](https://learn.microsoft.com/azure/sre-agent/overview)) |

## デモシナリオ一覧

### シナリオ 1: CPU 異常高騰 (推奨 - メインデモ)

**障害内容:** Chaos Studio から VM の CPU 使用率を 95% まで引き上げる (10 分間)

**期待される SRE Agent の動作:**

1. Azure Monitor が CPU 80% 超過のメトリックアラートを発報
2. SRE Agent がアラートを受信し、自動的に調査を開始
3. VM のメトリクス・ログを分析し、根本原因を特定
4. CPU を消費しているプロセス (`stress-ng`) を特定
5. 修復アクション (プロセスの停止またはVM の再起動) を提案/実行
6. アラートの解消を確認

### シナリオ 2: メモリ圧迫

**障害内容:** VM の物理メモリ使用率を 90% まで引き上げる (10 分間)

**期待される SRE Agent の動作:**

1. メモリ低下アラートが発報
2. SRE Agent がメモリ消費の原因プロセスを調査
3. OOM Killer の発動リスクを評価
4. 修復方法を提案

### シナリオ 3: サービス停止 (nginx)

**障害内容:** nginx サービスを強制停止する (5 分間)

**期待される SRE Agent の動作:**

1. HTTP 監視の失敗を検知 (設定済みの場合)
2. サービスのステータスを確認
3. nginx の再起動を実施
4. サービスの復旧を確認

---

## デプロイ手順

### Step 1: パラメータの設定

```bash
cd sreagentlab

# パラメータファイルを編集
cp main.parameters.json main.parameters.local.json
```

`main.parameters.local.json` を編集し、以下の値を設定:

```json
{
  "parameters": {
    "sshPublicKey": {
      "value": "ssh-rsa AAAA... (あなたの公開鍵)"
    },
    "alertEmail": {
      "value": "you@example.com"
    },
    "allowedSshSource": {
      "value": "203.0.113.1/32 (あなたの IP)"
    }
  }
}
```

> **Tips:** 自分のパブリック IP は `curl -s ifconfig.me` で確認できます。

### Step 2: デプロイの実行

```bash
# 環境変数の設定 (任意)
export RESOURCE_GROUP="rg-sreagentlab"
export LOCATION="eastus2"

# デプロイスクリプトの実行
./scripts/deploy.sh
```

デプロイには約 5\~10 分かかります。

### Step 3: SRE Agent のセットアップ

[SRE Agent セットアップガイド](sre-agent-setup.md) を参照してください。

### Step 4: Chaos 実験の実行

```bash
# シナリオ 1: CPU 負荷
./scripts/run-chaos.sh cpu

# シナリオ 2: メモリ負荷
./scripts/run-chaos.sh memory

# シナリオ 3: nginx 停止
./scripts/run-chaos.sh nginx
```

### Step 5: SRE Agent の動作確認

1. Azure Portal で SRE Agent のチャット画面を開く
2. 以下のように問い合わせる:

```
現在、srelab-vm で CPU 使用率が異常に高くなっています。調査してください。
```

SRE Agent が以下を自動的に実行:
- VM のメトリクス確認
- Log Analytics のログ分析
- 根本原因の機定
- 修復アクションの提案

### Step 6: Runbook の生成を指示

SRE Agent チャットで以下を入力:

```
今回のインシデント対応手順を Runbook として作成してください。
以下を含めてください:
- インシデントの概要
- 調査手順 (実行したコマンドとその結果)
- 根本原因
- 修復手順
- 再発防止策
```

### Step 7: クリーンアップ

```bash
./scripts/cleanup.sh
```

---

## デモ実演のタイムライン (推奨)

| 時間 | アクション | 説明 |
|------|-----------|------|
| 0:00 | 環境紹介 | アーキテクチャ図を見せ、各コンポーネントを説明 |
| 2:00 | Azure Portal で VM の正常な状態を確認 | メトリクスが正常であることを示す |
| 4:00 | SRE Agent のチャット画面を表示 | "What resources are you monitoring?" と確認 |
| 5:00 | Chaos 実験を開始 | `./scripts/run-chaos.sh cpu` を実行 |
| 7:00 | アラート発報を確認 | Azure Monitor のアラート画面を表示 |
| 8:00 | SRE Agent の自動対応を確認 | チャット画面でエージェントの分析を確認 |
| 12:00 | SRE Agent と対話 | 追加の調査指示や修復確認 |
| 15:00 | Runbook 生成を指示 | SRE Agent にドキュメント生成を依頼 |
| 18:00 | 生成された Runbook を確認 | 内容の品質をレビュー |
| 20:00 | まとめ | SRE Agent の価値と今後の発展を説明 |

---

## トラブルシューティング

### デプロイが失敗する場合

```bash
# デプロイの詳細ログを確認
az deployment group show \
  --resource-group rg-sreagentlab \
  --name <DEPLOYMENT_NAME> \
  --query properties.error
```

### Chaos 実験が失敗する場合

1. Chaos Agent が正常にインストールされているか確認:

```bash
az vm extension list \
  --resource-group rg-sreagentlab \
  --vm-name srelab-vm \
  --query "[?name=='ChaosAgent']" \
  -o table
```

2. ロールの割り当てを確認:

```bash
az role assignment list \
  --resource-group rg-sreagentlab \
  --query "[?contains(principalName,'chaos')]" \
  -o table
```

### SRE Agent がアラートを検知しない場合

1. SRE Agent のマネージドリソースグループに対象のリソースグループが含まれているか確認
2. Azure Monitor アラートが正常に発報されているか確認
3. SRE Agent のインシデント管理設定で Azure Monitor Alerts が有効であることを確認

---

## コスト見積もり

| リソース | SKU | 概算月額コスト (USD) |
|---------|-----|---------------------|
| VM (Standard\_B2s) | 2 vCPU, 4 GB RAM | ~$35 |
| Log Analytics | PerGB2018 | ~$2.76/GB |
| Public IP (Standard) | Static | ~$3.65 |
| Chaos Studio | 実験あたり | ~$0.05/min |
| **合計 (デモ目的)** | | **~$5\~10 (数時間利用)** |

> **注意:** デモ完了後は必ず `./scripts/cleanup.sh` でリソースを削除してください。
