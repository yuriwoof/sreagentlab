# Workbook とライブレポート

## Workbook の開き方

`deploy.sh` が表示する Workbook リンクを開きます。
リンクを控えていない場合、対象 RG の成功した main デプロイの出力で `workbookUrl` / `workbookId` を確認します。
Azure Portal の **Monitor → Workbooks** から、対象サブスクリプションと RG を絞り、`<prefix>-live-report` を開く方法もあります。
LAW を起点に保存した Workbook と、同名の別 RG の Workbook を取り違えないでください。

1. 読み取りモードで開き、既定の **Last 1 hour**（過去 1 時間）を確認します。
2. **Auto refresh → 1 minute** を選びます。
3. 別タブでデプロイ結果の Gateway URL を開き、HTTP 応答とグラフを照合します。

自動更新間隔は Workbook に保存されません。
開き直すたびに設定が必要です。
編集モードでは自動更新しません。
これは[公式の Workbook 管理仕様](https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-manage#set-up-auto-refresh)による制約であり、Bicep に未対応の永続化プロパティを追加して回避する構成ではありません。

## 表示内容とデータソース

| パネル | データソース | 確認点 |
|---|---|---|
| VM ごとの CPU | Azure Monitor の Percentage CPU | VM 間の差と実験期間 |
| OS ディスク IOPS / キュー | Azure Monitor の OS Disk IOPS Consumed Percentage / OS Disk Queue Depth | VM SKU の対応、負荷前後の変化 |
| Network in / out | Azure Monitor の Network In Total / Network Out Total | 実験とリクエスト時刻との相関 |
| Available memory | LAW の `Perf` | VM 別の MiB、取り込み時刻 |
| Healthy / Unhealthy | Gateway の HealthyHostCount / UnhealthyHostCount | 片系か全系か |
| リクエスト数 | Gateway の TotalRequests | 観測期間にトラフィックがあったか |
| frontend / backend 5xx | ResponseStatus / BackendResponseStatus の HttpStatusGroup=5xx | Gateway 自身のエラーと IIS のエラーを区別 |
| IIS 停止履歴 | LAW の `Event`、SCM 7036 | stopped の履歴であり、現在状態ではない |
| 実験開始履歴 | LAW の `AzureActivity` | 任意の Activity Log エクスポートが必要 |

プラットフォームのグラフは Azure Monitor を直接参照します。
App Gateway の `AllMetrics` 診断設定を LAW に送っていますが、グラフは `AzureMetrics` テーブルの到着を前提にしません。
アクセスログ、パフォーマンスログ、ファイアウォールログは不要です。

`VM Cached IOPS Consumed Percentage` は別途参考アラートとして構成しています。
OS ディスクが caching=None のため、値が出ない場合があります。
キャッシュを使わないディスクの律速判定には、OS ディスクの指標とゲスト IO を確認します。

Gateway が生成する 502 は frontend 5xx です。
backend 5xx はバックエンドが返した 5xx のみであり、同時に発報する保証はありません。
ブラウザの更新などでリクエストを送らない場合、frontend 5xx の件数も増えません。

## 実験開始履歴を追加する場合

通常の RG デプロイにはサブスクリプション診断設定を含めません。
権限を持つ管理者が任意の手順として実行します。

```bash
export RESOURCE_GROUP="rg-sreagentlab"
bash scripts/enable-activity-log.sh
```

`modules/activity-log.bicep` はサブスクリプション全体の Activity Log を対象 LAW へ送ります。
Workbook はそのうちラボ RG の Chaos 実験だけに表示を限定します。
表示フィルターがエクスポート範囲を RG に制限するわけではないため、費用と取り込み可能な操作情報を事前に確認してください。
既存の共有診断設定を上書きせず、作成した設定名と送信先を記録します。
スクリプトの設定名は `sreagentlab-activity-${RESOURCE_GROUP}` です。
同名設定の送信先が異なる場合や、別設定ですでに同じ LAW に転送している場合は、変更せず停止します。

診断設定の作成権限を、SRE Agent に暗黙に付与しません。
詳細な権限と KQL は[定期タスク](scheduled-tasks.md)を参照します。
エクスポート有効化前の履歴が自動で遡って入るとは限りません。
テーブル未作成や取り込み遅延のため、最初は空欄やクエリエラーになる場合があります。

## SRE Agent へのライブ報告プロンプト

```text
対象 RG は <対象 RG> です。
この RG の全 Windows VM と Application Gateway の直近 30 分を、読み取り専用で報告してください。

1. VM ごとの CPU、Available Bytes、OS Disk IOPS Consumed Percentage、OS Disk Queue Depth、
   Network In/Out と、正常時または他 VM との比較。
2. Gateway の Healthy/UnhealthyHostCount、TotalRequests、frontend/backend 5xx。
3. 発報中と解消済みのアラート、IIS 停止イベント、取得できれば実験開始と構成変更の履歴。
4. 原因候補を、根拠となる指標、ログ、対象 ID、時刻と対応付けて提示。
5. 調査対象期間、取得時刻、欠損、権限不足、取り込み遅延、未確認事項。

欠損をゼロと解釈せず、実測事実と推測を分けてください。
W3SVC の過去の停止履歴だけで現在も停止中と判断しないでください。
修復、再起動、リソース変更、定期タスクの作成はしないでください。
```

Workbook の自動更新はグラフの再取得であり、SRE Agent の推論を毎分自動実行する機能ではありません。
このプロンプトは必要なときにチャットへ入力します。
定期実行を希望する場合だけ、別の[定期タスク手順](scheduled-tasks.md)で明示的に作成します。

## 結果の確認と終了

AMA の `Perf` / `Event` と Activity Log の転送には遅延があります。
1 分更新にしても、データが 1 分以内に到着する保証にはなりません。
空のパネルは、障害なしの証拠ではありません。
対象 ID、時間範囲、エージェント状態、DCR 関連付け、診断設定、読み取り権限を順に確認します。

ライブレポートは読み取り専用なので、終了時は画面を閉じるだけです。
リソースの停止や削除は行いません。
デモ全体が終了したら、スケジュールの停止と専用 RG のクリーンアップを別途実施してください。
