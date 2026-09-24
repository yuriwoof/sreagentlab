# 承認付き修復の Runbook

このテンプレートには、調査で得た実際の値と実行結果を記録します。
未実行の修復を「実施済み」と書かず、推定原因と確認済み原因を区別してください。
デモ構成は [README](../README.md)を参照します。

## 記録する情報

| 項目 | 記録内容 |
|---|---|
| インシデント | ID、概要、影響範囲、重大度 |
| 対象 | サブスクリプション、RG、VM / NSG / Gateway の完全な ID |
| 時刻 | 発生、検知、承認、修復、復旧確認。UTC と JST を区別 |
| 検知 | アラート ID、評価期間、メトリクス値、HTTP 応答 |
| 証拠 | KQL / API / Run Command の結果と取得時刻 |
| 変更 | 操作者、承認者、変更前後の差分、CorrelationId |
| 復旧 | 実験終了、ゲスト状態、Gateway 正常数、HTTP、アラート |
| 未確認事項 | 欠損、取り込み遅延、権限不足、追加調査 |

## 共通の調査と承認

1. 障害シナリオと実験の状態を確認し、同時実行を避けます。
2. Workbook と Azure Monitor で、対象 VM と正常な VM の同じ期間を比較します。
3. ゲストデータは `Perf` / `Event`、操作履歴は `AzureActivity`、費用は Cost Management に分けて取得します。
4. 対象、変更差分、影響、最小権限、ロールバック、確認条件を提示します。
5. 明示的な承認後に 1 つの変更を行い、結果を検証します。

変数は対象デプロイの outputs と照合して設定します。
次は読み取り例です。

```bash
az vm get-instance-view --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --query instanceView.statuses -o table
az monitor metrics list --resource "$VM_ID" --metrics "Percentage CPU" \
  --interval PT1M --aggregation Average -o json
az network application-gateway show-backend-health \
  --resource-group "$RESOURCE_GROUP" --name "$APPGW_NAME" -o json
```

Log Analytics ではリソース ID と時間で範囲を限定します。

```kusto
let vmIds = dynamic(["<対象 VM の完全なリソース ID>"]);
Perf
| where TimeGenerated > ago(30m)
| where _ResourceId in~ (vmIds)
| where (ObjectName == "Memory" and CounterName == "Available Bytes")
    or (ObjectName == "LogicalDisk" and CounterName in ("Disk Reads/sec", "Disk Writes/sec", "Avg. Disk Queue Length"))
| summarize Average = avg(CounterValue) by Computer, CounterName, InstanceName, bin(TimeGenerated, 1m)
| order by TimeGenerated asc
```

`Perf` の集計だけで原因プロセスの PID は特定できません。
必要な場合に限り、承認を得て対象 VM の Run Command でゲスト状態を調査します。

## NSG 誤設定の復旧例

### 調査と提案

```bash
az network nsg rule list --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --query "[].{name:name,priority:priority,access:access,direction:direction,source:sourceAddressPrefix,destination:destinationAddressPrefix,port:destinationPortRange}" \
  -o table
bash scripts/run-chaos.sh status nsg
```

`ManualDenyAppGatewayHTTP` と `ChaosDenyAppGatewayHTTP` は両方とも優先度 100 です。
両方を共存させません。
既定の正常規則は、App Gateway サブネットから VM サブネットの TCP 80 を許可する優先度 200 の `AllowHTTPFromApplicationGateway` です。

```text
対象 NSG の ManualDenyAppGatewayHTTP が正常規則より先に一致することを確認しました。
Chaos NSG 実験が動作していないことを再確認して、この手動規則だけを削除する案です。
対象 NSG の規則変更権限だけを使い、他の規則は変更しません。
実行承認をお願いします。
```

### 承認後の実行と確認

Chaos 版の場合、先に `bash scripts/run-chaos.sh stop nsg` で停止し、状態と Chaos 所有規則の撤去を確認します。
実験中の NSG 外部編集は、実験失敗の原因になり得ます。
`fix-nsg.sh` は手動規則だけが対象であり、Chaos 所有規則の削除に使用しません。

手動版で承認済みの場合のみ、次を実行します。

```bash
bash scripts/fix-nsg.sh
```

正常な許可規則の維持、両バックエンドの Healthy、Gateway 経由の HTTP 200 を確認します。
SecurityRule 1.0 の既存フローによる遅延と、プローブの判定時間を考慮してください。
復旧操作を取り消す必要がある場合も、手動障害規則の再作成は再障害になるため、別途承認を得ます。

## ディスク IO 圧迫の復旧例

### 調査と提案

OS ディスクは 127 GiB の Standard_LRS、caching=None です。
IOPS 消費率とキュー深度を、ゲストの読み書き回数と比較します。
`VM Cached IOPS Consumed Percentage` の欠損は、この構成では異常や正常の証拠にできません。

```bash
az monitor metrics list --resource "$VM_ID" \
  --metrics "OS Disk IOPS Consumed Percentage" "OS Disk Queue Depth" \
  --interval PT1M --aggregation Average -o json
bash scripts/run-chaos.sh status diskio
```

```text
実験期間と OS ディスクの IOPS 消費率、キュー上昇が重なっています。
まず対象の diskio 実験を停止して値の回復を確認する案です。
ディスク拡張、SKU 変更、VM サイズ変更は自動実行しません。
変更を検討する場合は性能上限、料金差、停止影響、ロールバック制約を別途提示します。
```

### 承認後の実行と確認

```bash
bash scripts/run-chaos.sh stop diskio
bash scripts/run-chaos.sh status diskio
```

実験終了後に IOPS とキューが平常値へ戻り、HTTP 200 が維持されることを確認します。
元イメージより小さい 32 GiB への縮小や、ゲストディスクの破壊的な再作成は復旧策にしません。
負荷ファイルを削除する場合も、実験が終了したことと対象ファイルを確認してから別途承認します。

## プローブ誤設定の復旧例

### 調査と提案

```bash
az network application-gateway probe show --resource-group "$RESOURCE_GROUP" \
  --gateway-name "$APPGW_NAME" --name "$PROBE_NAME" -o json
```

ゲストの `/health.htm` は HTTP 200 なのに、プローブが `/healthz` を参照していないか確認します。
Gateway が生成する 502 は `ResponseStatus` の frontend 5xx であり、`BackendResponseStatus` の backend 5xx とは別です。

```text
プローブだけを /healthz から既知の正常値 /health.htm に戻す案です。
対象 Gateway の変更権限を使用し、バックエンド、ポート、NSG は変更しません。
想定外のカスタムパスであれば上書きせず、所有者への確認で止めます。
```

### 承認後の実行と確認

```bash
bash scripts/fix-appgw-probe.sh
```

スクリプトは既知のパスの間だけを扱います。
更新完了後、両バックエンドの Healthy と、ブラウザで送信したリクエストの HTTP 200 を確認します。
切り戻しが必要な場合は変更前の構成を根拠に、再障害の影響も含めて承認を受けます。

## IIS のゲスト確認と復旧

IIS 実験は先に停止します。
`stop iis` の終了後もサービスが復旧していなければ、`fix-iis.sh` または以下に相当する承認済み PowerShell を使用します。

```bash
bash scripts/run-chaos.sh stop iis
bash scripts/run-chaos.sh status iis
```

状態確認は対象を明示した `RunPowerShellScript` で行います。

```bash
az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts 'Get-Service -Name W3SVC | Select-Object Name,Status,StartType'
```

サービスが停止している場合の起動は別途承認し、実行後に状態とローカル HTTP を確認します。

```bash
az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '$ErrorActionPreference="Stop"; Start-Service -Name W3SVC; if ((Get-Service W3SVC).Status -ne "Running") { throw "W3SVC is not running" }; (Invoke-WebRequest -Uri "http://localhost/health.htm" -UseBasicParsing -TimeoutSec 30).StatusCode'
```

VM 側の成功だけで終了せず、Gateway の Backend health と外部 HTTP 応答まで確認してください。
サービス停止イベントは履歴として残るため、現在の Running 状態と区別します。

## Runbook 生成用プロンプト

```text
今回の対応だけを根拠に Runbook を作成してください。
対象 ID、UTC/JST のタイムライン、アラートと指標、実行した KQL/API/Run Command、
確認済み原因と原因候補、承認者、変更差分、ロールバック、復旧確認、未確認事項を含めてください。
未実行の操作は提案と明記し、秘密情報は含めないでください。
NSG の所有者、Chaos の停止確認、最小権限、ディスクの破壊的変更を避けた理由も記録してください。
```
