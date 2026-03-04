# Azure SRE Agent セットアップガイド

## 概要

Bicep によるインフラデプロイ完了後、Azure Portal から SRE Agent を作成し、デモ用リソースグループと接続します。SRE Agent は Azure Monitor アラートと連携し、インシデントの自動検知・調査・修復を行います。

> **前提:** SRE Agent は現在 Preview です。利用には Preview の有効化が必要です。

---

## Step 1: SRE Agent Preview の有効化

1. [Azure SRE Agent ポータル](https://aka.ms/sreagent/portal) にアクセス
2. Preview 利用規約に同意
3. サブスクリプションが有効化されるまで待機

> **リージョン:** SRE Agent は現在 **East US 2** リージョンで利用可能です。デプロイ先リージョンもこれに合わせてください。

---

## Step 2: SRE Agent の作成

1. [Azure Portal](https://portal.azure.com) を開く
2. 検索バーに「**SRE Agent**」と入力し、サービスを選択
3. 「**Create**」を選択
4. 以下の値を入力:

| 項目 | 値 |
|------|-----|
| **Subscription** | お使いのサブスクリプション |
| **Resource Group** | `rg-sreagent` (エージェント専用。アプリ用RGとは別に作成) |
| **Agent Name** | `srelab-agent` |
| **Region** | `East US 2` |

5. 「**Choose resource groups**」を選択
6. `rg-sreagentlab` (デモ環境のリソースグループ) にチェックを入れる
7. 「**Save**」→「**Create**」を選択

> **重要:** エージェント自体のリソースグループと、監視対象のリソースグループは分けることを推奨します。

作成が完了すると、以下が自動生成されます:

- Azure Application Insights
- Log Analytics Workspace
- Managed Identity

---

## Step 3: インシデント管理の設定

### Azure Monitor Alerts との接続 (デフォルト)

Azure Monitor Alerts はデフォルトで有効です。追加設定は不要です。

SRE Agent が検知するアラート:

| アラート名 | 条件 | 重大度 |
|-----------|------|--------|
| `srelab-high-cpu-alert` | CPU > 80% (5分間平均) | Sev 2 |
| `srelab-high-memory-alert` | Available Memory < 200MB (5分間平均) | Sev 2 |

### インシデントレスポンスプランの設定

1. SRE Agent リソースを開く
2. 「**Incident management**」タブを選択
3. 「**Incident platform**」が「Azure Monitor Alerts」であることを確認
4. インシデントハンドラーの設定:

| 設定項目 | 推奨値 (デモ用) | 説明 |
|---------|----------------|------|
| **Autonomy Level** | Semi-autonomous (Reader mode) | エージェントが調査を行い、修復はユーザー承認後に実行 |
| **Auto-close incidents** | 有効 | 修復後にアラートを自動クローズ |

> **デモでの推奨:** Semi-autonomous モードでは、修復前にユーザー確認が入るため、デモとして対話的に見せやすくなります。Autonomous モードでは完全自動で修復まで実行されます。

---

## Step 4: SRE Agent の動作確認

エージェント作成後、チャット画面で以下を確認:

### 基本確認クエリ

```text
What resources are you monitoring?
```

→ `srelab-vm`、VNet、NSG などのリソース一覧が表示されること

```text
What is the current health status of srelab-vm?
```

→ VM のヘルスステータス、CPU/メモリの現在値が表示されること

```text
What alerts should I set up for srelab-vm?
```

→ 既に設定済みのアラートに加え、追加の推奨アラートが表示されること

---

## Step 5: Chaos 実験実行中の SRE Agent 操作

Chaos 実験を開始した後 (`./scripts/run-chaos.sh cpu`)、以下の流れで SRE Agent と対話します。

### 5-1. アラート発報待ち (約 5 分)

CPU が 80% を超え、5 分間の評価ウィンドウを経てアラートが発報されます。

SRE Agent のインシデント管理ダッシュボードにインシデントが表示されるのを確認してください。

### 5-2. 自動調査の確認

SRE Agent が自動的に以下を実行:

1. **メトリクス取得:** VM の CPU 使用率の時系列データ
2. **プロセス分析:** 高 CPU プロセスの特定 (`stress-ng`)
3. **ログ分析:** Syslog から異常イベントの検索
4. **根本原因の報告:** "stress-ng プロセスが CPU リソースを大量消費している"

### 5-3. 対話的な追加調査

```text
srelab-vm のCPUを大量消費しているプロセスのPIDと開始時刻を教えてください。
```

```text
このCPU高騰はいつから始まりましたか？ Chaos Studio の実験と相関していますか？
```

```text
nginx サービスは正常に稼働していますか？ HTTP レスポンスに影響はありますか？
```

### 5-4. 修復の実行

```text
stress-ng プロセスを停止して、CPU 使用率を正常に戻してください。
```

> **注意:** Chaos Studio の実験は設定された期間が終了すると自動的に停止します。デモでは SRE Agent による修復アクションの提案を示すことが主目的です。

---

## Step 6: Runbook 生成の指示

すべての調査・修復が完了したら、以下のプロンプトで Runbook を生成させます:

```text
今回のインシデント対応を Runbook として文書化してください。以下のセクションを含めてください:

1. インシデント概要
   - 発生日時
   - 影響を受けたリソース
   - 重大度

2. 検知方法
   - トリガーされたアラート
   - 検知までの時間

3. 調査手順
   - 実行した調査ステップ
   - 確認した各メトリクスとログ
   - 使用した Azure CLI コマンドまたは KQL クエリ

4. 根本原因分析
   - 原因の特定
   - 影響範囲の評価

5. 修復手順
   - 実施した修復アクション
   - 復旧確認方法

6. 再発防止策
   - 推奨するモニタリング強化
   - アラート閾値の見直し
   - 自動修復ルールの提案
```

---

## 権限要件まとめ

| 対象 | 必要なロール | 割り当て先 |
|------|------------|----------|
| デプロイ実行者 | Contributor + User Access Administrator | サブスクリプション |
| Chaos Experiment (システム割り当て ID) | Reader | ターゲット VM |
| Chaos Agent (ユーザー割り当て ID) | (自動設定) | ターゲット VM |
| SRE Agent (マネージド ID) | (自動設定) | 監視対象リソースグループ |

---

## ファイアウォール設定

SRE Agent を利用するには、以下のドメインへのアクセスを許可する必要があります:

```
*.azuresre.ai
```

---

## 関連リソース

- [Azure SRE Agent 公式ドキュメント](https://learn.microsoft.com/azure/sre-agent/overview)
- [Azure Chaos Studio 公式ドキュメント](https://learn.microsoft.com/azure/chaos-studio/)
- [Chaos Studio 障害ライブラリ](https://learn.microsoft.com/azure/chaos-studio/chaos-studio-fault-library)
- [Azure Monitor アラートの概要](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview)
