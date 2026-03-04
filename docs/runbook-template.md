# Runbook テンプレート: VM CPU 高騰インシデント

> **注意:** このテンプレートは SRE Agent に生成させる Runbook のサンプルです。
> 実際のデモでは、SRE Agent が対応内容に基づいて自動生成した Runbook を使用してください。

---

## 1. インシデント概要

| 項目 | 内容 |
|------|------|
| **インシデント ID** | INC-YYYY-MMDD-001 |
| **発生日時** | YYYY-MM-DD HH:MM (JST) |
| **検知日時** | YYYY-MM-DD HH:MM (JST) |
| **解決日時** | YYYY-MM-DD HH:MM (JST) |
| **MTTR** | X 分 |
| **影響リソース** | `srelab-vm` (Standard\_B2s, East US 2) |
| **重大度** | Sev 2 |
| **影響範囲** | VM 上の Web サービス (nginx) のレスポンス遅延 |
| **トリガーアラート** | `srelab-high-cpu-alert` |

---

## 2. 検知方法

### トリガーされたアラート

- **アラート名:** `srelab-high-cpu-alert`
- **条件:** Percentage CPU > 80% (5 分間平均)
- **重大度:** Sev 2
- **通知先:** Action Group `srelab-ag` (メール通知)

### 検知フロー

```
Chaos Studio 実験開始
    ↓ (CPU 95% 注入)
Azure Monitor メトリクス収集 (1 分間隔)
    ↓ (5 分間の評価ウィンドウ)
メトリックアラート発報
    ↓
SRE Agent がアラートを受信
    ↓
自動調査開始
```

---

## 3. 調査手順

### Step 3-1: VM のヘルスステータス確認

```bash
az vm get-instance-view \
  --resource-group rg-sreagentlab \
  --name srelab-vm \
  --query instanceView.statuses \
  -o table
```

**期待される結果:** VM は Running 状態だが CPU 使用率が異常に高い

### Step 3-2: CPU メトリクスの確認

```bash
az monitor metrics list \
  --resource /subscriptions/<SUB_ID>/resourceGroups/rg-sreagentlab/providers/Microsoft.Compute/virtualMachines/srelab-vm \
  --metric "Percentage CPU" \
  --interval PT1M \
  --start-time $(date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ') \
  --end-time $(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  -o table
```

**期待される結果:** CPU 使用率が 90% 以上で推移

### Step 3-3: Log Analytics でプロセス情報を確認 (KQL)

```kusto
Perf
| where Computer == "srelab-vm"
| where ObjectName == "Processor" and CounterName == "% Processor Time"
| where TimeGenerated > ago(30m)
| summarize AvgCPU = avg(CounterValue) by bin(TimeGenerated, 1m)
| order by TimeGenerated desc
```

### Step 3-4: SSH でのプロセス確認 (必要に応じて)

```bash
ssh azureuser@<VM_PUBLIC_IP>
top -bn1 | head -20
ps aux --sort=-%cpu | head -10
```

**期待される結果:** `stress-ng` プロセスが CPU を大量消費

---

## 4. 根本原因分析

### 原因

Chaos Studio の CPU Pressure 実験により、`stress-ng` プロセスが VM の CPU リソースの 95% を消費していた。

### 影響

- VM 上で稼働する nginx Web サーバーのレスポンス時間が増大
- SSH 接続のレスポンスが遅延
- 他のプロセスの実行が阻害

### 相関分析

| 時刻 | イベント |
|------|---------|
| HH:MM | Chaos 実験開始 → `stress-ng` プロセス起動 |
| HH:MM+1 | CPU 使用率が 80% を超過 |
| HH:MM+6 | メトリックアラート発報 |
| HH:MM+7 | SRE Agent が調査開始 |
| HH:MM+10 | 根本原因を特定 |

---

## 5. 修復手順

### 方法 A: プロセスの強制停止

```bash
# stress-ng プロセスを特定して停止
ssh azureuser@<VM_PUBLIC_IP>
sudo pkill -f stress-ng
```

### 方法 B: VM の再起動

```bash
az vm restart \
  --resource-group rg-sreagentlab \
  --name srelab-vm
```

### 方法 C: Chaos 実験の停止

```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/<SUB_ID>/resourceGroups/rg-sreagentlab/providers/Microsoft.Chaos/experiments/srelab-cpu-pressure-exp/cancel?api-version=2024-01-01"
```

### 修復後の確認

```bash
# CPU 使用率が正常値に戻ったことを確認
az monitor metrics list \
  --resource /subscriptions/<SUB_ID>/resourceGroups/rg-sreagentlab/providers/Microsoft.Compute/virtualMachines/srelab-vm \
  --metric "Percentage CPU" \
  --interval PT1M \
  -o table

# nginx サービスが正常稼働していることを確認
curl -s -o /dev/null -w "%{http_code}" http://<VM_PUBLIC_IP>
```

---

## 6. 再発防止策

### 短期対応

- [ ] CPU 使用率のアラート閾値を見直し (現在 80% → 必要に応じて調整)
- [ ] アラート通知先に Ops チームの Slack/Teams チャンネルを追加

### 中期対応

- [ ] VM のオートスケール設定を検討
- [ ] 定期的な Chaos Engineering 訓練をスケジュール化
- [ ] SRE Agent の Autonomous モードでの自動修復ルールを策定

### 長期対応

- [ ] アプリケーションのコンテナ化と AKS への移行を検討
- [ ] CPU 予測アラート (動的閾値) の導入
- [ ] インシデント対応の自動化パイプライン構築

---

## 7. SRE Agent への Runbook 生成指示 (プロンプト例)

デモの最終ステップとして、SRE Agent チャットで以下のプロンプトを入力してください:

```text
今回のCPU高騰インシデントへの対応を、運用チーム向けの Runbook として作成してください。

含めるべき内容:
- インシデント概要 (What happened)
- タイムライン (When did it happen)
- 影響範囲 (What was affected)
- 調査で使用したコマンドと KQL クエリ
- 根本原因 (Root cause)
- 実施した修復手順
- 復旧確認方法
- 再発防止のための推奨アクション

フォーマット: Markdown 形式で、コマンドはコードブロックで記述してください。
```

SRE Agent は、実際に行った調査内容と修復アクションに基づいて、カスタマイズされた Runbook を生成します。

---

## 付録: SRE Agent 推奨プロンプト集

### 調査系

```text
srelab-vm の過去1時間の CPU 使用率の推移を表示してください。
```

```text
srelab-vm で最もCPUを消費しているプロセスを上位5件教えてください。
```

```text
Log Analytics から srelab-vm の直近のエラーログを検索してください。
```

### 修復系

```text
stress-ng プロセスを停止して CPU 負荷を解消してください。
```

```text
srelab-vm を再起動してください。
```

```text
nginx サービスを再起動してください。
```

### 予防系

```text
srelab-vm に CPU 使用率 90% 超過時にプロセスを自動停止するアラートルールを作成する方法を教えてください。
```

```text
srelab-vm の今後のキャパシティプランニングについてアドバイスしてください。
```
