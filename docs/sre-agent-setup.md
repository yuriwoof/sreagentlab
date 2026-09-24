# Azure SRE Agent のセットアップ

## デプロイされる構成

`main.bicep` は SRE Agent、専用ユーザー割り当てマネージド ID、Log Analytics に接続した Application Insights、ロール割り当てを作成します。
VM の共有 Chaos ID と SRE Agent の ID は別の用途です。
VM ごとのシステム割り当て ID は Azure Monitor Agent（AMA）が使用します。

SRE Agent の `knowledgeGraphConfiguration.managedResources` には、デプロイ先 RG の ID を登録します。
その RG の Windows VM、NSG、Application Gateway、Log Analytics、Workbook が対象です。
RG 内のリソースが対象であることは、サブスクリプション全体の操作権限を意味しません。

## モードと権限

| 設定 | 既定値 | 用途 |
|---|---|---|
| `sreAgentAccessLevel` | `High` | SRE ID に対象 RG の Contributor を追加 |
| `sreAgentMode` | `Review` | 修復提案を確認し、承認後に実行するデモ |
| 読み取り専用の組み合わせ | `Low` / `ReadOnly` | ライブレポートや調査のみ |
| `deployerPrincipalId` | 実行者のユーザーオブジェクト ID | 利用者の SRE Agent アクセス権を設定 |

`High` と `Review` は権限の最小化そのものではありません。
実装では RG スコープの Contributor を付与するため、読み取り中心のデモでは `Low` / `ReadOnly` を検討します。
修復が必要な場合も対象、変更差分、影響、ロールバックを確認し、最小スコープの権限で承認してください。
プロンプトの「変更しない」という指示だけを、RBAC に代わる境界として扱わないでください。

| ID / 実行者 | 実装上のスコープと権限 |
|---|---|
| デプロイ実行者 | 対象 RG の作成操作とロール割り当て操作が必要。RG 作成やプロバイダー登録は別途管理者と調整 |
| デプロイ利用者 | `main.bicep` が対象 RG に SRE Agent 用ロールと Contributor を割り当て |
| SRE ID | 対象 RG の Reader と Log Analytics Reader、High の場合のみ Contributor |
| 共有 Chaos ID | 各対象 VM の Reader |
| CPU / メモリ実験 ID | 全対象 VM の Reader |
| IIS / ディスク IO 実験 ID | 最初の VM の Reader |
| NSG 実験 ID | 対象 NSG の Network Contributor |

VM Run Command はゲストで高い権限を持つ操作です。
実行する PowerShell 全文、VM ID、実行者、結果を記録し、サービス確認と必要な復旧以外へ権限を広げないでください。
NSG 修復は対象 NSG、プローブ修復は対象 Gateway に限定します。

## ポータルからの確認

1. 成功した main デプロイの出力 `sreAgentPortalUrl`、または [SRE Agent ポータル](https://aka.ms/sreagent/portal)を開きます。
2. 作成したエージェントを選び、対象 RG が管理リソースに含まれていることを確認します。
3. IAM で SRE ID の割り当て先が目的の RG であることを確認します。
4. チャットで下記の読み取り専用確認を実行します。

```text
管理対象リソースの ID を一覧にしてください。
対象 RG 内の全 Windows VM、Application Gateway、NSG、Log Analytics、Workbook を確認し、
現在取得できるメトリクスと不足している権限を説明してください。
リソース変更や権限追加はしないでください。
```

ポータルの表示はサービス更新やテナントで変わるため、未確認の設定ラベルを探すのではなく、リソース ID と実際の権限で確認します。
SRE Agent の利用可能リージョンや利用要件は[公式概要](https://learn.microsoft.com/azure/sre-agent/overview)で確認してください。
このラボの既定のデプロイ先は `eastus2` です。

## アラートとインシデント対応

`monitoring.bicep` は次の監視を作成します。

| 対象 | 条件 / データソース |
|---|---|
| 各 VM の CPU | Percentage CPU の 5 分平均 > 80% |
| 各 VM の OS ディスク | IOPS 消費率の 5 分平均 > 90%、キュー深度の 5 分平均 > 10 |
| Cached IOPS | 5 分平均 > 90%。caching=None ではデータ欠損があり得る参考指標 |
| メモリ | `Perf` の Available Bytes の 5 分平均 < 200 MiB |
| IIS 停止 | `Event` の SCM 7036、W3SVC / World Wide Web Publishing Service の stopped |
| Gateway | UnhealthyHostCount の 5 分平均 >= 1、frontend / backend 5xx の 5 分合計 > 0 |

IIS イベントの状態文字列は、このラボで使用する英語 Windows イメージを前提にしています。
App Gateway の診断設定は `AllMetrics` のみであり、アクセスログやファイアウォールログを追加する必要はありません。
Workbook のメトリクス表示はその診断設定ではなく Azure Monitor の直接クエリを使用します。

Azure Monitor のアラート作成と、SRE Agent での自動インシデント対応は別に確認します。
利用環境の[公式インシデント対応ガイド](https://learn.microsoft.com/azure/sre-agent/overview)から現在の接続設定を確認し、発報済みアラートが対象エージェントで扱えるか試してください。
テンプレートだけで全アラートの自動調査が保証されるとは説明しません。
連携が未設定でも、チャットから対象アラートと期間を指定して調査できます。

## 安全な修復の実演

```text
現在のアラートと実験状態を読み取り、原因候補と証拠を示してください。
対象 ID、変更前後の差分、想定影響、ロールバック、必要最小限の権限を提示して承認を待ってください。
Chaos 所有の操作は実験停止を優先し、実行中の NSG 実験を外部から編集しないでください。
承認後の操作と復旧確認結果を記録してください。
```

IIS 実験停止後に W3SVC が復旧していなければ、`fix-iis.sh` または承認済み Run Command で確認して起動します。
ディスクや VM のサイズを自動変更するデモにはしません。
詳細は[Runbook](runbook-template.md)に従います。

## 追加の読み取り権限

Activity Log を Log Analytics に送る診断設定はサブスクリプションスコープです。
任意の `enable-activity-log.sh` は、当該スコープに診断設定を作成できる管理者が実行します。
SRE Agent にサブスクリプションの Contributor や Owner を暗黙に追加する手順ではありません。
取り込み済み `AzureActivity` の読み取りと、エクスポート設定の作成権限を区別してください。

Cost Management の取得には別の API と、対象のコストスコープに合った読み取り権限が必要です。
Azure RBAC スコープの Cost Management Reader と、契約に応じた課金スコープの Billing reader 等の権限は、管理者が別途確認します。
RG の管理リソース指定だけで、請求アカウントの費用が読めるとは限りません。
[定期タスク](scheduled-tasks.md)では、利用できないデータを未取得として報告します。

## 関連手順

- [8 シナリオ](demo-scenario.md)
- [ライブレポート](live-report.md)
- [定期タスク](scheduled-tasks.md)
- [ポータルによる Windows 構成](azure-portal-manual-setup.md)
