# SRE Agent Lab 運用ベースライン

> 検索言語ごとの結果は文書、インデックス、権限、サービスの状態によって変わる可能性があります。見出しと主要語には英語の別名も併記していますが、日本語クエリの検索結果は実際に確認してください。
> Search keywords: prohibited actions, recovery verification, escalation conditions, first recovery action, IIS stop, CPU spike, memory pressure, NSG misconfiguration, disk IO pressure, probe failure.

| 項目 | 値 |
|---|---|
| 対象 | SRE Agent Lab の専用リソースグループ |
| 用途 | Azure SRE Agent と Chaos Studio を使った非本番の障害対応演習 |
| 所有者 | ハンズオン実施者 |
| 最終確認日 | アップロード時に実施者が記入する |
| 見直し条件 | ラボ構成、アラート、復旧スクリプト、SRE Agent の設定を変更したとき |

## 対象構成

- Windows Server 2022 の IIS VM を Application Gateway のバックエンドに配置する。
- VM の Public IP は既定で作成しない。
- VM の通常の管理操作には Azure VM Run Command を使用する。
- Azure Monitor メトリクス、Log Analytics の `Perf` と `Event`、Azure Monitor アラートを調査に使用する。
- `AzureActivity` は任意の Activity Log 転送を有効にした後の操作だけを含む。
- 費用は Cost Management から取得する。`AzureActivity` から費用を推定しない。

## 調査時の境界

1. 対象リソース、期間、取得時刻、データソースを明示する。
2. 取得できない値を 0 または正常として扱わない。
3. 確認済みの事実、原因候補、未確認事項を分ける。
4. 異常な VM と正常な VM を同じ期間で比較する。
5. Chaos 実験の状態と開始時刻を確認する。
6. Review モードでは変更を実行せず、対象、差分、影響、最小権限、ロールバック、復旧条件を提示して承認を待つ。

## 障害別の最初の対応 (First recovery action by symptom)

| 症状 | 最初に確認すること | 最初の復旧候補 |
|---|---|---|
| CPU 高騰 | 全 VM の CPU、Gateway の正常ホスト数、Chaos 実験状態 | CPU 実験の停止 |
| メモリ圧迫 | `Available Bytes`、`% Committed Bytes In Use`、取り込み時刻 | メモリ実験の停止 |
| IIS 停止 | W3SVC のイベント、Gateway のバックエンド正常性、IIS 実験状態 | IIS 実験の停止。停止後も未復旧なら承認済みのサービス起動 |
| NSG 誤設定 | `ManualDenyAppGatewayHTTP` と正常な許可規則の優先順位 | 手動で追加した拒否規則だけを削除 |
| ディスク IO 圧迫 | IOPS 消費率、キュー深度、ディスク IO 実験状態 | ディスク IO 実験の停止 |
| Gateway プローブ異常 | IIS の `/health.htm` とプローブのパス | 既知の誤設定 `/healthz` だけを `/health.htm` に戻す |

## 禁止事項 (Prohibited actions)

- 複数の構成を同時に変更しない。
- 原因の証拠なしに VM を再起動、サイズ変更、再作成しない。
- ディスクを縮小または破壊的に再作成しない。
- SRE Agent にサブスクリプションの Owner または Contributor を一括付与しない。
- NSG の `ManualDenyAppGatewayHTTP` 以外の規則を障害復旧の名目で変更しない。
- Application Gateway のバックエンド、ポート、NSG をプローブ復旧と同時に変更しない。
- プロンプトの指示だけを RBAC やツールアクセス ポリシーの代わりにしない。

## 復旧確認 (Recovery verification)

変更または実験停止の後、次を確認する。

1. 対象の Chaos 実験が終了している。
2. Gateway の全バックエンドが Healthy である。
3. Gateway 経由の HTTP 応答が 200 である。
4. 対象メトリクスまたはゲスト状態が平常値へ戻っている。
5. Azure Monitor アラートが解消している。
6. 実行者、承認者、変更差分、時刻、結果、未確認事項が記録されている。

## エスカレーション条件 (Escalation conditions)

- 対象リソースまたは所有者を特定できない。
- 必要な証拠が権限不足またはデータ欠損で取得できない。
- 既知の障害注入と一致しない構成差分がある。
- 復旧操作がラボの専用リソースグループ外へ影響する。
- ロールバック方法または復旧確認条件を定義できない。
- 実験停止後も症状が継続する。
