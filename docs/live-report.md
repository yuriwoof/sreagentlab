# SRE Agent のライブレポート

## ライブレポートとは

[ライブレポート (プレビュー)](https://learn.microsoft.com/azure/sre-agent/live-reports) は、Azure SRE Agent の機能です。
チャットで必要なビューを説明すると、エージェントがレポートを作成し、エージェントの **ライブ レポート** ページに保存します。
保存後はチャート、表、ステータス表示のレイアウトを維持したまま、データだけを再取得できます。

このラボでは、VM と Application Gateway の状態を一画面で確認する「運用ダッシュボード」としてライブレポートを使用します。
ライブレポートは SRE Agent ポータルでチャットから作成するものであり、Bicep や ARM テンプレートのリソースではありません。
そのため `main.bicep` はレポートを作成しません。
デプロイ後に、この手順でレポートを作成します。
## 前提条件

| 項目 | このラボでの準備 |
|---|---|
| レポートを作成する利用者の権限 | エージェントに対する読み書き権限が必要です。`main.bicep` はデプロイ実行者に **SRE Agent Administrator** を割り当てます。 |
| レポートを閲覧する利用者の権限 | 共有先にも **SRE Agent Standard User** または **SRE Agent Administrator** が必要です。リンクを共有しても権限は付与されません。 |
| エージェントのデータアクセス | エージェントのマネージド ID には、ラボ RG の Reader と Log Analytics Reader を割り当てています（[sre-agent.bicep](../modules/sre-agent.bicep)）。 |
| データソース | 組み込みの Azure Monitor メトリクス、Log Analytics、Resource Graph を使用します（[コネクタ](https://learn.microsoft.com/azure/sre-agent/connectors)）。 |
| ゲストのログ | AMA と DCR が `Perf`（CPU、メモリ、ディスク、ネットワーク）と `Event`（Service Control Manager 7036）を LAW に送ります。 |
| Chaos 実験の履歴（任意） | `AzureActivity` を使う場合は、[定期タスク](scheduled-tasks.md)に記載した `enable-activity-log.sh` でサブスクリプションの Activity Log を LAW に転送します。 |

レポートは、エージェントに設定済みのツールとコネクタ、およびそれらに付与された権限の範囲でのみデータを取得できます。
レポートを作成しても、コネクタの追加や他システムへのアクセス権の付与は行われません。
公式ドキュメントでは、接続データとして Kusto を含むサポート対象の MCP コネクタが例示されています。
作成時にエージェントが提示するツールに Azure Monitor メトリクスと Log Analytics のクエリが含まれることを確認してください。
含まれない場合は、レポートの作成を続けず、エージェントのコネクタとツール設定を確認します。

## レポートの内容

| セクション | データソース | 表示内容 |
|---|---|---|
| VM ごとの CPU | Azure Monitor メトリクス `Percentage CPU` | 直近 1 時間の時系列 |
| VM ごとの空きメモリ | LAW `Perf` の `Memory` / `Available Bytes` | VM 別の MiB（時系列） |
| OS ディスク | `OS Disk IOPS Consumed Percentage`、`OS Disk Queue Depth` | IOPS 上限への到達とキューの増加 |
| ネットワーク | `Network In Total`、`Network Out Total`（補助: `Perf` の Network Interface） | VM 別の送受信量 |
| App Gateway バックエンド | `HealthyHostCount`、`UnhealthyHostCount` | 正常と異常の台数、ステータス表示 |
| App Gateway リクエスト | `TotalRequests`、`ResponseStatus` と `BackendResponseStatus`（`HttpStatusGroup = 5xx`） | リクエスト数、Gateway の 5xx と IIS の 5xx の区別 |
| IIS 停止イベント | LAW `Event`（System、Service Control Manager、Event ID 7036、W3SVC、stopped） | VM、時刻、メッセージの一覧 |
| Chaos 実験の開始履歴 | LAW `AzureActivity`（`Microsoft.Chaos/experiments/start/action`） | 実験名、開始時刻、状態、実行者 |
| アラート | 発報中と解消済みの Azure Monitor アラート | ラボ RG のアラート一覧 |

App Gateway の診断設定は `AllMetrics` を LAW に送ります。
ただし `AzureMetrics` テーブルにはディメンションが含まれないため、5xx の内訳は Azure Monitor メトリクスから取得します。
`VM Cached IOPS Consumed Percentage` は、OS ディスクが caching=None のためデータが出ない場合があります。

## ライブレポートを作成する

1. `deploy.sh` が表示する **SRE Agent** のリンク（デプロイ出力 `sreAgentPortalUrl`）からエージェントを開きます。
2. ナビゲーションで **ライブ レポート** を選びます。
3. **+ 新しいレポート** を選びます。エージェントが利用可能なツールを確認します。
4. 下記のプロンプトを入力し、エージェントからの追加の質問に答えます。
5. レポートで使用するツールを確認します。**読み取り専用のツールだけを承認**します。
6. レポートが保存され、ギャラリーに表示されるまで待ちます。

> スクリーンショット挿入位置: ライブ レポートのギャラリーと **+ 新しいレポート**。
>
> スクリーンショット挿入位置: 使用ツールの確認と承認の画面。

### プロンプト例 1: ラボの状態ダッシュボード

`<RG>`、`<prefix>`、`<LAW 名>` は、デプロイ出力の `resourceGroupName`、パラメータの `prefix`、出力の `lawName` に置き換えます。

```text
「SRE Lab Live Status」という名前のライブレポートを作成してください。
対象はリソースグループ <RG> の Windows VM（<prefix>-vm-01、<prefix>-vm-02 …）と
Application Gateway <prefix>-appgw です。既定の期間は直近 1 時間とし、期間セレクターを付けてください。

1. VM ごとの時系列チャート（Azure Monitor メトリクス）:
   Percentage CPU、OS Disk IOPS Consumed Percentage、OS Disk Queue Depth、
   Network In Total、Network Out Total
2. VM ごとの空きメモリの時系列チャート:
   Log Analytics ワークスペース <LAW 名> の Perf テーブル、ObjectName "Memory"、CounterName "Available Bytes"（MiB 表示）
3. Application Gateway のステータス表示と時系列チャート:
   HealthyHostCount、UnhealthyHostCount、TotalRequests、
   ResponseStatus と BackendResponseStatus の HttpStatusGroup = 5xx を別々のシリーズで表示
   UnhealthyHostCount が 1 以上なら異常のステータスにしてください
4. IIS 停止イベントの表（新しい順）:
   Event テーブル、System ログ、Source "Service Control Manager"、EventID 7036、
   W3SVC（World Wide Web Publishing Service）が stopped になったイベント
5. Chaos 実験の開始履歴の表:
   AzureActivity テーブルの OperationNameValue "Microsoft.Chaos/experiments/start/action"、
   ResourceGroup が <RG> のもの。テーブルがない、または空の場合はその旨を表示してください
6. ラボ RG の Azure Monitor アラートの表（発報中と解消済み、重大度、対象、時刻）

データはコネクタとツールの結果だけで表示し、モデルによる要約セクションは作成しないでください。
リソースを変更するボタンやアクションは追加せず、読み取り専用のツールだけを使用してください。
欠損値は 0 として描画せず、データなしと表示してください。
```

モデルによる要約や分析のセクションは、更新のたびに AAU を消費します。
このため、状態ダッシュボードは表示のみで作成し、原因分析はチャットで個別に依頼します。

### プロンプト例 2: 障害デモ用タイムライン

障害注入の前後を 1 画面で比較する場合に作成します。

```text
「SRE Lab Incident Timeline」という名前のライブレポートを作成してください。
対象はリソースグループ <RG> です。既定の期間は直近 3 時間とし、期間セレクターを付けてください。

- Chaos 実験の開始と終了（Chaos Studio の実験の実行履歴、または AzureActivity）
- Application Gateway の UnhealthyHostCount と ResponseStatus 5xx の時系列
- <prefix>-vm-01 と <prefix>-vm-02 の Percentage CPU、OS Disk IOPS Consumed Percentage の時系列
- W3SVC 停止イベント（Event、Service Control Manager、7036）
- NSG <prefix>-nsg と Application Gateway の構成変更（AzureActivity の書き込み操作と削除操作）

これらを同じ時間軸に並べてください。
表示のみとし、モデルによる要約、リソース変更のボタンやアクションは追加しないでください。
```

## レポートを開き、再読み込みして更新する

1. **ライブ レポート** に戻り、レポートのタイルを選びます。
2. 現在のチャート、表、ステータス表示を確認します。
3. レポートは最大 5 分間キャッシュされたツールの結果を使う場合があります。障害デモ中は **再読み込み** を選び、最新のデータを取得します。
4. レイアウト、フィルター、データソースを変更する場合は、**作成スレッドを開く** を選び、チャットで変更点を伝えて新しいバージョンを保存させます。
5. バージョン ピッカーで以前のバージョンを確認できます。以前のバージョンに保存されるのはレイアウトと構成であり、過去のデータではありません。

公式ドキュメントに一定間隔の自動更新機能の記載はありません。
デモでは、障害注入後や復旧後に **再読み込み** を選びます。
AMA の `Perf` / `Event` と Activity Log は、取り込みに数分かかることがあります。
再読み込みしても、データの到着が遅れている場合は反映されません。

## 共有、エクスポート、削除

- **共有**: **レポートへのリンクをコピー** を選びます。共有先には、エージェントに対する SRE Agent Standard User または SRE Agent Administrator のロールが必要です。
- **エクスポート**: オーバーフロー メニューの **HTML のダウンロード** で、静的なスナップショットを保存します。ファイルにはリソース名や IP アドレスが含まれるため、取り扱いに注意します。
- **削除**: オーバーフロー メニューの **削除** で完全に削除します。SRE Agent Administrator のロールが必要です。

レポートはエージェントに保存されます。
`cleanup.sh` でラボ RG を削除するとエージェントも削除されるため、残したいレポートは事前に HTML で保存します。
ダウンロードした HTML はローカルファイルのため、`cleanup.sh` では削除されません。

## 使用量とコスト

- ライブレポートの作成と、既存レポートの更新（レイアウトの変更など）は、アクティブ フローの AAU を消費します。
- コネクタとツールでデータを取得するだけの再読み込みは、アクティブ フローの AAU を消費しません。
- モデルによる要約や分析を含むレポートは、再読み込みのたびに AAU を消費します。
- プレビューでは、レポートごとやユーザーごとの AAU 予算を設定できません。モデルの呼び出しを繰り返すレポートは作成しないでください。

消費量はエージェントの **設定** > **エージェントの消費** で確認します。
料金は[価格と課金](https://learn.microsoft.com/azure/sre-agent/pricing-billing)を参照してください。

## プレビューの制限事項

- 別のテナントからエージェントにアクセスした場合、レポートのツール呼び出しを承認できません。テナント間で共有するレポートには、承認が必要なツールを含めないでください。
- 生成されるレポートの HTML は 10 MB 以下である必要があります。
- モデルがレート制限された場合、そのセクションは HTTP 429 を返します。時間をおいて再試行します。

## チャットでその場のレポートを依頼する

保存するほどではない確認は、ライブレポートではなくエージェントとのチャットで依頼します。
チャットでの依頼はその都度 AAU を消費し、結果は保存されたダッシュボードとしては残りません。

```text
rg-sreagentlab の全 VM と App Gateway について、直近 30 分のメトリックとアラート状況を表にまとめ、
異常があれば原因候補を挙げてください。
各値の期間と取得時刻、根拠としたメトリックやログ、欠損や未確認事項も示してください。
読み取り専用で調査し、修復やリソースの変更はしないでください。
```

RG 名は実際の値に置き換えてください。

## 参考: Log Analytics のクエリ

レポートの作成時にエージェントが生成したクエリを確認する場合や、作成スレッドでクエリを指定する場合に使用します。
`<VM 名の接頭辞>` は `<prefix>-vm-` に置き換えます。

```kusto
// VM ごとの空きメモリ (MiB)
Perf
| where TimeGenerated > ago(1h)
| where Computer startswith "<VM 名の接頭辞>"
| where ObjectName == "Memory" and CounterName == "Available Bytes"
| summarize AvailableMiB = avg(CounterValue) / 1048576.0 by Computer, bin(TimeGenerated, 1m)
| order by TimeGenerated asc
```

```kusto
// W3SVC の停止イベント (Service Control Manager 7036)
Event
| where TimeGenerated > ago(24h)
| where Computer startswith "<VM 名の接頭辞>"
| where EventLog == "System" and Source == "Service Control Manager" and EventID == 7036
| where RenderedDescription has_any ("World Wide Web Publishing Service", "W3SVC")
    and RenderedDescription has "stopped"
| project TimeGenerated, Computer, RenderedDescription
| order by TimeGenerated desc
```

```kusto
// Chaos 実験の開始履歴 (任意の Activity Log 転送が必要)
AzureActivity
| where TimeGenerated > ago(24h)
| where ResourceGroup =~ "<RG>"
| where OperationNameValue =~ "Microsoft.Chaos/experiments/start/action"
| project TimeGenerated, Resource = tostring(split(ResourceId, "/")[-1]), ActivityStatusValue, Caller, CorrelationId
| order by TimeGenerated desc
```

## トラブルシューティング

| 症状 | 確認すること |
|---|---|
| エージェントがレポートを作成できない | 利用者にエージェントの読み書き権限があるか、必要なツールとコネクタが正常か |
| データが古く見える | **再読み込み** でキャッシュを回避したか、データソースに新しいデータが届いているか |
| メモリやイベントの表が空 | AMA 拡張機能と DCR の関連付け、`Perf` / `Event` の取り込み遅延 |
| Chaos 実験の履歴が空 | `enable-activity-log.sh` を実行したか。転送は有効化以降の操作のみが対象 |
| 5xx が 0 のまま | ブラウザなどでリクエストを送ったか。Gateway が返す 502 は BackendResponseStatus に含まれない |
| ディスクのメトリクスがない | VM サイズがディスク指標に対応しているか（既定は `Standard_D2s_v5`） |

空のセクションは、障害がないことの証拠ではありません。
対象リソース、期間、ツールの権限、データの到着を順に確認してください。

## 公式ドキュメント

- [Azure SRE Agent のライブ レポート (プレビュー)](https://learn.microsoft.com/azure/sre-agent/live-reports)
- [Azure SRE Agent のコネクタ](https://learn.microsoft.com/azure/sre-agent/connectors)
- [ユーザーのロールとアクセス許可](https://learn.microsoft.com/azure/sre-agent/user-roles)
- [ツールのアクセス ポリシー](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)
- [価格と課金](https://learn.microsoft.com/azure/sre-agent/pricing-billing)

画面の項目名は日本語版ドキュメントの訳語に基づきます。
実際の表示がプレビュー中に変わる場合があるため、ポータルの表示を優先してください。
