# Windows IIS ラボのポータル手動構築

この手順は、現在の `main.bicep` と各モジュールに対応する Windows IIS 構成です。
旧 Ubuntu / nginx 構成の構築手順は、この手順に置き換えています。
既存 VM の OS をインプレースで変更せず、新しい専用 RG に作成してください。

GUI での個別作成は Bicep のデプロイ outputs を生成しません。
`common.sh` を利用する運用スクリプトは main の outputs を必要とするため、純粋な手動構築では以下のリソース名と ID を記録し、ポータルで操作します。
スクリプトを使うデモでは [README](../README.md)の Bicep デプロイを推奨します。
画面上の配置や翻訳が異なる場合は、下表のリソース設定値とモジュールを照合してください。

## 1. RG と入力値

Azure Portal で専用 RG（既定 `rg-sreagentlab`）を `East US 2` に作成します。
作成権限と、必要なスコープでロールを割り当てる権限を管理者に確認します。
SRE Agent の利用可否と VM クォータも先に確認してください。

| 項目 | 設定 |
|---|---|
| prefix | `srelab`、1～9 文字 |
| VM 名 | `srelab-vm-01`、`srelab-vm-02`。Windows computerName は 15 文字以下 |
| 台数 | 既定 2、Bicep は 1～99。1 台ではフェイルオーバーなし |
| タグ | 対応するリソースに `project=sreagentlab`、`env=demo` |
| 管理者 | 管理者名と新しい強固なパスワードを安全な入力欄から指定 |
| 通知先 | 実際のアラート通知用メールアドレス |

パスワードをメモ、ドキュメント、パラメータファイルに転記しません。
Bicep で作成する場合はコミット対象とローカル用の `adminPassword.value` を空文字のままにし、`deploy.sh` の非表示入力を使用します。

## 2. ネットワークと NAT

VNet `srelab-vnet` にアドレス空間 `10.0.0.0/16` を設定し、次のサブネットを作成します。

| サブネット | プレフィックス | 関連付け |
|---|---|---|
| `srelab-snet-vm` | `10.0.1.0/24` | VM 用 NSG と NAT Gateway。既定の外向きアクセスを無効化 |
| `srelab-snet-appgw` | `10.0.2.0/24` | Gateway 用 NSG。Application Gateway 専用 |

Standard / 静的 IPv4 の Public IP `srelab-nat-pip` と、Standard NAT Gateway `srelab-nat` を作成します。
NAT のアイドルタイムアウトは 4 分とし、VM サブネットへ関連付けます。
VM に Public IP を付けない構成でも、拡張機能や Azure エンドポイントへの外向き通信が必要です。
NAT の Public IP は受信管理用ではありません。

### VM 用 NSG

`srelab-nsg` を VM サブネットへ関連付け、以下を設定します。
ソースポートは `*`、方向は Inbound です。

| 名前 | 優先度 | ソース | 宛先 | 宛先ポート / プロトコル | 動作 |
|---|---|---|---|---|---|
| `AllowHTTPFromApplicationGateway` | 200 | `10.0.2.0/24` | `10.0.1.0/24` | 80 / TCP | Allow |
| `DenyOtherHTTP` | 210 | `*` | `*` | 80 / TCP | Deny |
| `AllowRestrictedRDP`（任意） | 300 | 明示した狭い接続元 CIDR | `10.0.1.0/24` | 3389 / TCP | Allow |
| `DenyOtherRDP` | 310 | `*` | `*` | 3389 / TCP | Deny |

RDP は既定で無効です。
有効化する場合だけ、実際の接続元 CIDR（通常 `/32`）を指定します。
ワイルドカードや `/0` を許可元にせず、未指定のまま VM Public IP を追加しません。
優先度 100 は障害規則用に空けておきます。

### Gateway 用 NSG

`srelab-appgw-nsg` を Gateway サブネットへ関連付けます。

| 名前 | 優先度 | ソース | 宛先ポート / プロトコル | 動作 |
|---|---|---|---|---|
| `AllowInternetHTTPHTTPS` | 200 | `Internet` | 80, 443 / TCP | Allow |
| `AllowGatewayManager` | 210 | `GatewayManager` | 65200-65535 / TCP | Allow |
| `AllowAzureLoadBalancer` | 220 | `AzureLoadBalancer` | `*` / `*` | Allow |

HTTPS 用ポートを NSG で許可していても、このラボで構成するリスナーは HTTP 80 のみです。
TLS 証明書と HTTPS リスナーは構成していません。

## 3. ID と Windows VM

共有ユーザー割り当てマネージド ID `srelab-chaos-identity` を 1 つ作成し、各 VM に割り当てます。
各 VM ではシステム割り当て ID も有効にします。
共有 ID は Chaos、システム割り当て ID は AMA に使用します。

各 VM を次の値で作成します。

| 設定 | 値 |
|---|---|
| イメージ publisher / offer | `MicrosoftWindowsServer` / `WindowsServer` |
| SKU / version | `2022-datacenter-azure-edition` / `latest` |
| サイズ | `Standard_D2s_v5` |
| OS ディスク | 127 GiB、Standard HDD LRS（`Standard_LRS`）、ホストキャッシュなし（`None`） |
| ネットワーク | VM サブネット、NIC への追加 NSG なし |
| VM Public IP | なし。限定した RDP を明示的に有効化する場合だけ追加 |
| ブート診断 | マネージドストレージで有効 |
| ID | システム割り当てと共有ユーザー割り当て |

承認された元イメージは 127 GiB を必要とするため、32 GiB に縮小しません。
`Standard_D2s_v5` は、このラボで使用するディスクメトリクスに対応する VM サイズとして選択しています。
サイズを変更する場合は対応指標とクォータを再確認してください。
`vm.bicep` はラボ用に `enableAutomaticUpdates=false` としています。
手動構築でも OS 更新設定を照合し、本番の更新方針へそのまま流用しません。

## 4. IIS の初期化

各 VM の Run Command で `RunPowerShellScript` を選び、リポジトリの `scripts/setup-iis.ps1` の内容を実行します。
外部サイトから任意のスクリプトを取得せず、確認済みのリポジトリ版を使用します。
Bicep 版は同じスクリプトを Windows Custom Script Extension で実行します。

スクリプトは IIS をインストールし、次を構成します。

- `Default.htm` にコンピューター名と VM 固有の背景色を表示。
- `/health.htm` に `OK` を配置。
- HTTP 応答とページにキャッシュ抑止設定を適用。
- Windows Firewall で HTTP を許可。
- `W3SVC` を自動起動に設定して起動し、ローカル HTTP 200 を検証。
- IO 負荷用ディレクトリ `C:\ChaosTemp` を作成。

Run Command の終了結果と、`Get-Service W3SVC` の Running を確認します。
ゲスト内での高権限実行になるため、対象 VM とスクリプト内容を承認してから実行してください。

## 5. Application Gateway

Public IP `srelab-appgw-pip` を Standard / 静的 IPv4 で作成します。
Application Gateway `srelab-appgw` を次の値で作成します。

| 設定 | 値 |
|---|---|
| SKU / capacity | `Standard_v2` / 1 |
| サブネット | `srelab-snet-appgw` |
| フロントエンド | Gateway 用 Public IP |
| バックエンドプール `iis-pool` | 各 VM のプライベート IP |
| バックエンド設定 `iis-http` | HTTP 80、timeout 30 秒、Cookie affinity 無効 |
| プローブ `iis-health` | HTTP、host `127.0.0.1`、path `/health.htm` |
| プローブの判定 | interval 15 秒、timeout 10 秒、失敗回数 2、正常コード `200` |
| リスナー / ルール | HTTP 80、Basic、優先度 100、`iis-pool` と `iis-http` に接続 |

Backend health で全 VM が Healthy になったら、Gateway の Public IP へブラウザで HTTP アクセスします。
反復更新して両 VM のページを確認します。
Cookie affinity 無効でも、表示順が厳密に交互になる保証はありません。

## 6. 監視

`srelab-law` を PerGB2018、保持期間 30 日で作成します。
Windows 用 DCR `srelab-dcr` を作成し、全 VM を関連付けます。
各 VM の `AzureMonitorWindowsAgent` がシステム割り当て ID を使用することを確認します。

| データソース | 設定 |
|---|---|
| パフォーマンス、10 秒間隔 | `\Processor Information(_Total)\% Processor Time` |
| メモリ | `\Memory\Available Bytes`、`\Memory\% Committed Bytes In Use` |
| ディスク | `\LogicalDisk(*)\% Free Space`、`\LogicalDisk(*)\Disk Reads/sec`、`\LogicalDisk(*)\Disk Writes/sec`、`\LogicalDisk(*)\Avg. Disk Queue Length` |
| Windows Event | `System!*[System[Provider[@Name='Service Control Manager'] and (EventID=7036)]]` |
| 送信先 | Log Analytics の `Perf` / `Event` |

Gateway の診断設定は、同じワークスペースへ **AllMetrics のみ**を送信します。
アクセスログ、パフォーマンスログ、ファイアウォールログは選択しません。
プラットフォームメトリクスは Azure Monitor から直接表示できます。

メール通知用 Action Group を作成し、[SRE Agent 手順のアラート表](sre-agent-setup.md#アラートとインシデント対応)の条件を設定します。
メモリと IIS はログ検索アラートであり、未対応のプラットフォームメモリ指標を選ばないでください。
IIS の KQL は `monitoring.bicep` と同じサービス名と stopped の条件を使用します。
SCM 7036 のすべてをサービス停止として数えません。

## 7. Chaos のターゲットと実験

全 VM にエージェントベースターゲット `Microsoft-Agent` を有効化し、共有 ID を指定します。
Windows 拡張機能 `ChaosWindowsAgent` を使用し、次の能力を有効化します。

| 実験 | 能力 / パラメータ | 対象 / 期間 |
|---|---|---|
| CPU | `CPUPressure-1.0`、pressureLevel `95` | 全 VM / 10 分 |
| メモリ | `PhysicalMemoryPressure-1.0`、pressureLevel `90` | 全 VM / 10 分 |
| IIS | `StopService-1.0`、serviceName `W3SVC` | vm-01 / 5 分 |
| ディスク IO | `DiskIOPressure-1.1`、pressureMode `PremiumStorageP10IOPS`、targetTempDirectory `C:\ChaosTemp` | vm-01 / 10 分 |
| NSG | `Microsoft-NetworkSecurityGroup` の `SecurityRule-1.0` | VM 用 NSG / 10 分 |

NSG 実験は Inbound / TCP / Deny、source `10.0.2.0/24`、destination `10.0.1.0/24`、source port `*`、destination port `80`、priority `100`、name `ChaosDenyAppGatewayHTTP` とします。
実際の型と配列形式は `chaos.bicep` を正本とします。
SecurityRule 1.0 は既存フローを切断しません。
実験中の外部編集を避け、手動障害版の `ManualDenyAppGatewayHTTP` と同時実行しないでください。

各実験のシステム割り当て ID を有効にし、[権限表](sre-agent-setup.md#モードと権限)に従って VM の Reader または対象 NSG の Network Contributor を割り当てます。
サブスクリプション全体の Contributor を一括付与する必要はありません。
現在の公式資料ではこのラボの `Microsoft.Chaos/experiments` モデルを **Experiments (classic)** と分類しています。
新しい Workspaces の Scenario と同じ API や障害パラメータだと仮定しないでください。

## 8. SRE Agent と Workbook

[SRE Agent 手順](sre-agent-setup.md)に従い、管理リソースへ対象 RG を登録します。
Application Gateway と Workbook も同じ RG の管理対象として確認します。
読み取り専用では Low / ReadOnly、承認付き修復では対象を限定した Review 運用を選びます。

手動で Workbook を作る場合、Azure Monitor の Workbooks で新規ブックを作成し、全 VM と Gateway のメトリクス、LAW の `Perf` / `Event` クエリを追加します。
`dashboard.bicep` の各パネルと[ライブレポート](live-report.md)の一覧を照合して保存します。
Bicep の `serializedData` はデプロイ時に ID を解決するため、Bicep ソース全体を Workbook の JSON として貼り付けないでください。
既定期間は過去 1 時間にし、読み取りモードで毎回 **Auto refresh → 1 minute** を選びます。
更新間隔は保存されません。

実験開始履歴と変更履歴が必要な場合は、管理者がサブスクリプションの Activity Log に診断設定を作成し、LAW へ送ります。
この操作は任意であり、通常の RG デプロイとは権限も削除範囲も異なります。
Cost Management の読み取り権限も別途確認します。

## 9. 構成確認と削除

- [ ] 全 VM は Windows Server 2022、127 GiB Standard_LRS、caching=None。
- [ ] VM Public IP はなし、または承認済みの限定 RDP 用だけ。
- [ ] NAT による外向き通信があり、IIS、AMA、Chaos 拡張機能が正常。
- [ ] Gateway 経由で両 VM のページが表示され、全バックエンドが Healthy。
- [ ] `Perf` / `Event` が取り込まれ、Workbook のデータ欠損とゼロを区別できる。
- [ ] 実験 ID の権限は対象 VM / NSG に限定されている。
- [ ] [デモ手順](demo-scenario.md)に従って 1 障害ずつ検証する。

終了時はデモ用スケジュールを無効化または削除し、保存が必要な記録を退避してから専用 RG を削除します。
任意のサブスクリプション診断設定は、作成した正確な名前と送信先を確認して個別に削除します。
VM の停止だけでは Gateway、NAT、Public IP、ディスク等の費用が残ります。

## API と参照元

実装は対応するサービスで 2024 年以降の API を優先します。
ただし、メトリクスアラート `2018-03-01`、診断設定 `2021-05-01-preview`、Workbook `2023-06-01`、RBAC `2022-04-01`、マネージド ID `2023-01-31`、Application Insights `2020-02-02` は、実装が使用する対応スキーマを維持しています。
SRE Agent 用の Smart Detector `2021-04-01` と付随する Action Group `2023-09-01-preview` も既存スキーマを維持しています。
古い日付という理由だけで、存在しない API バージョンへ置換しません。
SRE Agent は `2025-05-01-preview` であり、Preview の契約変更を確認してから更新します。

- [Chaos の障害ライブラリ](https://learn.microsoft.com/azure/chaos-studio/chaos-studio-fault-library)
- [Windows AMA の管理](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage)
- [Application Gateway のプローブ](https://learn.microsoft.com/azure/application-gateway/application-gateway-probe-overview)
- [VM の対応メトリクス](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-compute-virtualmachines-metrics)
- [Gateway の対応メトリクス](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-applicationgateways-metrics)
