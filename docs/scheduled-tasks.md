# 毎朝 9 時 JST の定期タスク

## 対象と権限の準備

Azure SRE Agent の **Scheduled tasks** で、コストと操作履歴を読み取り専用で報告するタスクを 2 つ作成します。
これはエージェントポータルの機能であり、ローカル CLI のスケジューラーや Workbook の更新設定とは別です。
手順は [Create and edit scheduled tasks](https://learn.microsoft.com/azure/sre-agent/create-scheduled-task) を根拠とします。

管理対象はラボ RG の全 VM、Application Gateway、Workbook を含みます。
RG の管理リソース指定だけでは、サブスクリプション全体の操作や課金データの読み取り権限は得られません。

| 情報 | 取得元 | 別途確認する権限 |
|---|---|---|
| 現在の構成と VM 状態 | Azure Resource Manager / Azure Monitor | 対象 RG の Reader 等 |
| 操作履歴 | Activity Log、または LAW の `AzureActivity` | 取得先とスコープの読み取り権限 |
| LAW への Activity Log エクスポート設定 | サブスクリプションの診断設定 | 当該スコープの診断設定作成権限。管理者が任意で設定 |
| 費用 | Cost Management の API / 対応するコネクター | 対象スコープの Cost Management Reader、必要に応じて契約に対応する課金スコープの読み取り権限 |

**AzureActivity から利用料金は取得できません。**
Cost Management の認証、API アクセス、課金スコープを別途確認します。
Billing reader などの権限は契約と課金スコープによって異なるため、[コストへのアクセス割り当て](https://learn.microsoft.com/azure/cost-management-billing/costs/assign-access-acm-data)を確認してください。
不足を理由に SRE Agent へサブスクリプションの Owner / Contributor を自動追加しません。

費用はリアルタイムではありません。
[Cost Management のデータ仕様](https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data)に従い、更新遅延、未確定値、契約ごとの可用性を報告に含めます。
過去 24 時間の完全な費用が得られないときは、利用可能な日次データの範囲と欠損を明示します。

## ポータルでの作成

1. 対象エージェントを開き、サイドバーの **Scheduled tasks** を選びます。
2. ツールバーの **Create task** を選びます。
3. **Task name** と **Task details** に、下記のタスク名とプロンプトを入力します。
4. **Frequency** を **Custom cron** にし、**Cron expression (UTC)** に `0 0 * * *` を指定します。
5. **Response custom agent** はメインエージェントを使用する場合は空欄にします。
6. **Agent autonomy level** は既定の Autonomous のままにせず **Review** を選びます。
7. デモ用には **Run limit** や終了条件を必要に応じて設定し、**Create task** を選びます。
8. 一覧の **Task status** が **On**、**Next run** が意図した時刻であることを確認します。

> スクリーンショット挿入位置: Scheduled tasks の一覧と Create task。
>
> スクリーンショット挿入位置: UTC cron `0 0 * * *`、Review、Next run の確認画面。

公式手順が保証するカスタム cron は UTC です。
**UTC 00:00 = JST 09:00** なので、ここでは `0 0 * * *` を使用します。
未確認のタイムゾーン選択欄や独自の cron 形式は前提にしません。
画面の時刻表示がローカル時間の場合も、保存後の Next run を UTC と JST に換算して確認します。

読み取り専用プロンプトと Review は、RBAC の代わりにはなりません。
日次報告専用なら、エージェント自体も `Low` / `ReadOnly` の最小権限で運用することを検討します。

## タスク 1: 日次コスト報告

Task name の例は `Lab daily cost report` です。
以下の `rg-sreagentlab` は、実際に使用する RG 名に置き換えてください。

```text
対象 RG は rg-sreagentlab です。読み取り専用で日次コスト報告を作成してください。
実行予定は毎朝 9 時 JST（UTC 00:00）です。

Cost Management の API または利用可能な認可済みコネクターで、
過去 24 時間と過去 7 日間の費用を取得し、リソース種別とリソース別に整理してください。
前の 24 時間との比較と 7 日間の日次傾向を示し、前日比 20% 以上の増加を明示してください。
比較対象が 0 の場合は無理に増加率を計算せず、新規費用として示してください。
データが日次粒度や更新遅延で不完全な場合は、実際の対象期間、最終取得時刻、欠損を明示してください。
費用の種類（実績/償却など）、通貨、タイムゾーンをそろえて比較してください。

停止忘れの可能性がある VM、未使用の可能性がある Public IP を現在の構成と利用状況から候補化してください。
Application Gateway と NAT Gateway の Public IP は用途を照合し、未使用と即断しないでください。
VM 停止後も残る Gateway、NAT、ディスク、Public IP の費用に触れてください。

金額の根拠となるスコープ、API、集計期間を付けてください。
AzureActivity から費用を推定せず、権限やデータが不足していれば未取得と報告してください。
停止、削除、サイズ変更、権限変更は実行せず、対応案と期待する効果だけを提示してください。
```

## タスク 2: 日次操作履歴報告

Task name の例は `Lab daily activity report` です。

```text
対象 RG は rg-sreagentlab です。過去 24 時間の操作履歴を読み取り専用で報告してください。
NSG 規則、Application Gateway、VM の起動/停止/割り当て解除/再起動、
RBAC ロール割り当て、リソース削除を抽出してください。

各項目に操作名、対象の完全なリソース ID、ResourceGroup、Caller、
UTC と JST の時刻、結果/状態、CorrelationId を含めてください。
Started/Accepted と Succeeded/Failed を同じものとして数えず、
相関 ID を用いて一連の操作を整理してください。
取得できる場合は変更前後の差分と影響候補も示し、取得できない差分は推測で補わないでください。

操作名と状態の大文字小文字の差を吸収し、ラボ RG 以外の情報を報告に混ぜないでください。
エクスポートの開始前、取り込み遅延、テーブル未作成、権限不足は未取得として区別してください。
想定外の変更があれば警告し、疑わしい操作も Caller だけで意図を断定せず、根拠と確認先を示してください。
リソースや権限は変更せず、費用を AzureActivity から計算しないでください。
```

RG より上位で付与された RBAC は、RG のフィルターだけでは検出できない場合があります。
必要なら別途承認されたスコープで監査し、このタスクだけでサブスクリプション全体を監査したと扱わないでください。

## AzureActivity の KQL 例

LAW へ取り込む場合は、権限を持つ管理者が任意の `enable-activity-log.sh` を使用します。
通常の main デプロイには含まれません。
`modules/activity-log.bicep` はサブスクリプション全体をエクスポートするため、LAW の取り込み費用と閲覧可能な情報を管理者が確認してください。

以下では対象サブスクリプションと RG を置き換えます。
操作名には `=~` / `in~`、状態には `in~`、部分一致には大文字小文字を区別しない `startswith` / `endswith` を使用します。
`ResourceGroup` と `CorrelationId` は結果にも含めます。

```kusto
let subscriptionId = "<対象サブスクリプション ID>";
let rg = "rg-sreagentlab";
AzureActivity
| where TimeGenerated >= ago(24h)
| where SubscriptionId =~ subscriptionId and ResourceGroup =~ rg
| where OperationNameValue startswith "Microsoft.Network/networkSecurityGroups/"
    or OperationNameValue startswith "Microsoft.Network/applicationGateways/"
    or OperationNameValue in~ (
        "Microsoft.Compute/virtualMachines/start/action",
        "Microsoft.Compute/virtualMachines/powerOff/action",
        "Microsoft.Compute/virtualMachines/deallocate/action",
        "Microsoft.Compute/virtualMachines/restart/action",
        "Microsoft.Authorization/roleAssignments/write",
        "Microsoft.Authorization/roleAssignments/delete")
    or OperationNameValue endswith "/delete"
| where ActivityStatusValue in~ ("Started", "Accepted", "Succeeded", "Failed", "Canceled", "Cancelled", "Success", "Failure")
| project TimeGenerated, TimeJST = TimeGenerated + 9h, ResourceGroup,
          OperationNameValue, ResourceId, Caller, ActivityStatusValue, CorrelationId
| order by TimeGenerated desc
```

実験開始履歴だけを調べる例です。

```kusto
let subscriptionId = "<対象サブスクリプション ID>";
let rg = "rg-sreagentlab";
AzureActivity
| where TimeGenerated >= ago(24h)
| where SubscriptionId =~ subscriptionId and ResourceGroup =~ rg
| where OperationNameValue =~ "Microsoft.Chaos/experiments/start/action"
| project TimeGenerated, ResourceGroup, ResourceId, Caller, ActivityStatusValue, CorrelationId
| order by TimeGenerated desc
```

同じ CorrelationId に複数の状態が記録されることがあります。
一覧を単純に合計して実行回数と解釈しないでください。
Activity Log はコントロールプレーン操作の記録であり、ゲスト内の W3SVC 状態確認は `Event` や Run Command で補います。
エクスポート設定直後はテーブルが未作成の場合もあり、空の結果だけで「操作なし」と結論しません。

## 実行結果、変更、終了

最初の予定実行後、タスク名を選んで実行履歴を開きます。
公式手順では各実行が会話スレッドを作成し、計画、使用ツール、結果、失敗時のエラーを確認できます。
コスト API と Activity Log の取得先が正しいこと、結果に時刻と根拠があること、書き込み操作をしていないことを確認してください。
3 回連続失敗すると Failed になるため、単に次回まで放置せず取得権限と接続先を確認します。

編集時はタスクを選択して **Edit task**、内容を変更して **Save** を選びます。
公式手順では編集後も実行履歴を保持します。
デモ終了時は対象タスクを無効化または削除し、残した場合は Off で次の実行がないことを確認します。
削除操作のラベルは実際の画面を確認し、未確認の UI 名を前提にしません。

任意のサブスクリプション診断設定は RG 削除では消えません。
`cleanup.sh` は `sreagentlab-activity-${RESOURCE_GROUP}` の設定名と送信先 LAW がこのデモ用であることを照合し、その設定だけを RG より先に削除します。
検査権限がない場合や送信先が異なる場合は停止するため、管理者と調整してください。
別名で手動作成した診断設定は、管理者が用途を確認して別途削除します。
共有設定や他のタスクは削除しません。

## 公式資料と確認範囲

- [定期タスクの作成と編集](https://learn.microsoft.com/azure/sre-agent/create-scheduled-task)
- [定期タスクの概要と状態](https://learn.microsoft.com/azure/sre-agent/scheduled-tasks)
- [Activity Log](https://learn.microsoft.com/azure/azure-monitor/fundamentals/activity-log)
- [コストデータの更新と制約](https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data)

ポータル手順、UTC の cron、実行履歴は公式ドキュメントで照合しています。
この文書の更新時には、実環境でのタスク作成、コスト API の認証、データ到着時間までは検証していません。
利用するエージェントで権限、コネクター、Next run、実行結果を確認してください。
