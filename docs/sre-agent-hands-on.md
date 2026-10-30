# Azure SRE Agent ステップバイステップ ハンズオン

このハンズオンでは、Azure SRE Agent を一度に作り込まず、運用能力を 3 段階で拡張します。
各レベルは前のレベルの成果を再利用します。
最初は必ず **Review** モードと読み取り専用の調査から始めてください。

ラボは README の **Deploy to Azure** ボタンからデプロイすることを前提とします。
Azure CLI でラボをデプロイし直す必要はありません。
デプロイ後の障害注入と復旧確認には Bash と Azure CLI を使うため、共通準備で Azure Cloud Shell などの実行環境を用意します。

| レベル | 学ぶこと | 成果物 | 目安 |
|---|---|---|---|
| 1 | 単一エージェントによるアラート調査 | Review モードのインシデント対応計画と調査記録 | 20 分 |
| 2 | カスタム エージェントとスキルによる役割分担と承認付き変更 | 1 つのカスタム エージェント、調査スキル、修復スキル、承認と復旧の記録 | 35 分 |
| 3 | ナレッジベースによる組織知の再利用 | インデックス済み文書と出典付きの調査回答 | 15 分 |

> Azure SRE Agent はプレビュー機能を含みます。ポータルの表示名が本書と異なる場合は、現在のポータル表示と[公式ドキュメント](https://learn.microsoft.com/azure/sre-agent/overview)を優先してください。

## 共通準備

### 1. ラボをデプロイする

1. [README の Deploy to Azure](../README.md#1-deploy-to-azure-でデプロイ)ボタンを選び、Azure portal から専用リソースグループへデプロイします。
2. 完了画面の **出力** を開きます。画面を閉じた場合は、対象の **リソース グループ** → **デプロイ** から、このテンプレートをデプロイした成功済みの項目を選び、**出力** を開きます。
3. `sreAgentPortalUrl`、`resourceGroupName`、`lawName`、`appGwName`、`appGwPublicIp`、`vmNames` を記録します。サブスクリプション ID はリソースグループの **概要** で確認します。
4. ブラウザで `http://<appGwPublicIp の値>/` を開き、IIS のページが表示されることを確認します。

### 2. 実験スクリプトの実行環境を準備する

実験スクリプトの実行には **Bash 環境** が必要です。
デプロイはブラウザだけで完了しますが、以降の `bash scripts/...` や `az ...` は SRE Agent のチャット欄ではなく、実施者のシェルで実行します。

Azure portal の上部から **Cloud Shell** を開き、**Bash** を選択してください。
初回起動時の設定は[Azure Cloud Shell の開始手順](https://learn.microsoft.com/azure/cloud-shell/get-started/new-storage)を参照してください。
ローカルの Git Bash や WSL を使う場合は、Azure CLI と `python3` を用意し、`az login` でサインインします。

Cloud Shell でリポジトリを取得し、そのルートへ移動します。
すでに取得済みなら、そのフォルダーへ移動してください。

```bash
git clone https://github.com/yuriwoof/sreagentlab.git
cd sreagentlab
```

続いて、ポータルで確認した値を設定し、対象サブスクリプションを選択します。
`RESOURCE_GROUP` には、Deploy to Azure で指定した実際のリソースグループ名を使います。
CLI デプロイ用の既定名 `rg-sreagentlab` と同じである必要はありません。

```bash
export SUBSCRIPTION_ID="<対象のサブスクリプション ID>"
export RESOURCE_GROUP="<resourceGroupName の値>"
az account set --subscription "$SUBSCRIPTION_ID"
az account show --query '{subscription:name,id:id}' -o table
```

これ以降のシェル操作は、このリポジトリのルートから実行します。
Cloud Shell を開き直した場合も、フォルダーへの移動と環境変数の設定を行ってください。
`scripts/deploy.sh` の実行や `main.parameters.local.json` の作成は不要です。

### 3. SRE Agent をオンボードする

1. `sreAgentPortalUrl` を開きます。
2. [初回オンボーディング](sre-agent-setup.md#手順-1-初回オンボーディングで-azure-monitor-を接続)に従い、インシデント プラットフォームとして **Azure Monitor** を接続します。
3. [手順 2: `/learn` の実行結果を確認](sre-agent-setup.md#手順-2-learn-の実行結果を確認)に従い、初期状態、管理対象リソース、取得できない情報と権限を確認します。不足がある場合だけ同じスレッドで追加調査します。
4. エージェントのモードが **Review** であることを確認します。自動修復を試すハンズオンではありません。
5. [README の月間 AAU 上限設定](../README.md#sre-agent-の月間-aau-上限を設定する)に従い、ハンズオンで使うアクティブ フローの上限と現在の消費量を確認します。

**チェックポイント:** `/learn` の結果に対象 RG、主要リソース、テレメトリの確認時刻、未確認事項が記録され、欠損を正常値として扱っていないこと。

## Level 1: インシデント対応計画を作成し、単一エージェントで調査する

### ゴール

Azure Monitor アラートを SRE Agent にルーティングし、エージェントが証拠を集めて修復案を提示し、実行前に人の承認を待つ状態を作ります。

### 1. インシデント対応計画を作成する

1. [応答プランの作成手順](sre-agent-setup.md#手順-4-応答プランを作成してアラート受信を確認)を開きます。
2. `srelab-alerts-review` を作成し、Sev1 と Sev2 を対象にします。
3. **応答エージェント** は既定のエージェント (Meta Agent) を選択します。
4. **エージェントの自律性レベル** は **Review** を選択します。
5. 作成後、状態が **オン**、モードが **Review** であることを確認します。
6. 既定の `quickstart_handler` が存在する場合は、二重処理を避けるため無効化または削除します。

### 2. CPU 高騰を発生させる

共通準備で設定した Cloud Shell（Bash）などの環境で、リポジトリのルートから実行します。
`SUBSCRIPTION_ID` と `RESOURCE_GROUP` が今回のラボを指していることを確認してください。

```bash
bash scripts/run-chaos.sh start cpu
bash scripts/run-chaos.sh status cpu
```

Azure Monitor の評価と SRE Agent への取り込みを待ちます。
5 分の評価窓があっても、必ず 5 分で発報するとは限りません。

### 3. エージェントの調査を評価する

自動作成されたインシデント スレッドを開き、次を確認します。

1. アラートの内容の把握と初期情報の収集を実施している。
2. Chaos 実験の実行状態と時刻を実際の実行履歴から確認し、メトリクス変化と照合している。実験定義の継続時間だけで終了時刻を決めていない。
3. イベントログ、AppGW の併行調査を実施している。
   ログが 0 件でも、取得範囲と取り込み遅延を調べずに障害を除外していない。
   メトリクスの平均には対象期間、集計方法、到着サンプル数と期待数を記載し、部分期間を 5 分平均と呼んでいない。
4. プロセス停止や VM 再起動を勝手に実行していない。
5. 実験が稼働中なら停止を提案して承認を待ち、終了済みなら停止を提案せず復旧状態を確認している。

不足がある場合は、同じスレッドで次を入力します。

```text
調査結果を、影響、時系列、確認済みの証拠、原因候補、未確認事項、
推奨する次の操作、ロールバック、復旧確認条件の順に整理してください。
変更操作は実行せず、承認を待ってください。
```

### 4. 実験を停止して復旧を確認する

```bash
bash scripts/run-chaos.sh status cpu
```

最新の実行が稼働中で、停止が必要な場合に限り、承認を得て次を実行します。
終了済みなら `stop` を送らず、状態と症状の回復を確認します。

```bash
bash scripts/run-chaos.sh stop cpu
bash scripts/run-chaos.sh status cpu
```

CPU の低下、Gateway 経由の HTTP 200、実験終了、アラート解消を確認します。
結果は[承認付き修復の Runbook](runbook-template.md)の項目に沿って記録します。

### Level 1 の合格条件

- [ ] 対応計画が **オン / Review** である。
- [ ] 発報した各 CPU アラートが意図した対応計画へルーティングされ、同じ発報を重複して処理していない。
- [ ] 調査に対象、期間、証拠、未確認事項が含まれる。
- [ ] 修復操作は承認前に実行されていない。
- [ ] 実験停止後の復旧条件を確認した。

## Level 2: カスタム エージェントとスキルで役割を分ける

### ゴール

この演習では、実施者が Application Gateway の正常性プローブのパスだけを `/health.htm` から `/healthz` に変更します。
原因探索は目的にせず、実施者が行った既知の変更をエージェントにレビューさせ、承認後に戻します。
正常時の記録と障害注入の実行結果を同じインシデント スレッドに提示し、調査、変更案のレビュー、承認、復旧確認を順に行います。
この判定条件は、原因と変更内容を特定したラボに限ります。
原因が未特定の本番障害では、別途証拠を集めて調査してください。

> [!WARNING]
> 現在の SRE Agent（workspace mode）では、カスタム エージェント間の新しい引き継ぎ（`handoffs`）を設定できません。
> 設定すると次のエラーになります。
>
>New agent-to-agent handoffs are not supported in workspace mode.
>Existing handoffs may only be retained or removed.
>Deliver cross-agent capabilities through skills and Task-based subagents instead.

このハンズオンでは、エージェントを切り替えず、同じエージェントが **スキル** を使ってフェーズを切り替えます。

| 要素 | 役割 | 書き込み |
|---|---|---|
| `srelab-incident-triage` スキル | 読み取り専用の調査手順 | なし |
| `srelab-appgw-probe-remediation` スキル | 対象と現在値を再確認し、承認後にプローブのパスだけを戻して復旧を確認する手順 | `RunAzCliWriteCommands` |
| `srelab-triage-agent` | 調査して停止し、実施者の明示的な依頼後に同じスレッドで変更をレビューする | 修復スキル経由のみ |

変更の承認は、プロンプト上の「承認をお願いします」という文章ではなく、Review モードで Azure の書き込み操作を呼び出したときに表示される **Approve** / **Deny** で行います。
書き込みツールが実行時に提供されていなければ、承認ボタンは表示されません。

ツールのアクセス ポリシーで Allow を設定した場合などは Review モードの承認を省略できるため、この演習では書き込みツールを Allow で自動承認しません（[ツールのアクセス ポリシー](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)）。

### 1. 調査スキルを作成する

1. SRE Agent ポータルで **ビルダー** → **エージェント キャンバス** を開きます。
2. **+ 作成** のプルダウンで、**スキル** を選択します。
3. `SKILL.md` を次の内容にします。

```markdown
---
name: srelab-incident-triage
description: SRE Agent Lab の VM、IIS、Application Gateway、NSG のアラートを読み取り専用で調査するときに使用する
---

## 使用条件

SRE Agent Lab の CPU、メモリ、ディスク IO、IIS、Application Gateway、
NSG に関するアラートまたは障害調査で使用する。

## 手順

1. アラート ID、重大度、対象の完全なリソース ID、評価期間を確認する。
2. 同じ期間について、異常なリソースと正常なリソースを比較する。
3. Azure Monitor メトリクスは Azure CLI の読み取り操作で取得し、Perf、Event、AzureActivity は Log Analytics で照会する。
   平均を示す場合は集計方法、サンプル間隔、期間、到着サンプル数と期待数を併記し、部分期間を完全なアラート評価窓と区別する。
4. Azure CLI の読み取り操作で Chaos 実験の実行履歴を確認する。
   投影前の API 応答でフィールド名と値を確認してから実行状態、startedAt、stoppedAt を読み、実験定義、開始要求の成功、実行の完了を区別する。
   定義の継続時間を開始時刻に足して実行全体の終了時刻とせず、現在の症状も再照会する。
5. 事実、原因候補、未確認事項を分ける。
   null、0 件、API エラー、サンプル未到着、投影からの省略を区別し、取得できない値を正常、未実行、または 0 とみなさない。
   ログが 0 件でも、取得期間と取り込み遅延を確かめずに原因を除外しない。
   Perf の照会が空の場合は実際の ObjectName と CounterName、DCR、対象リソースと期間を確認する。
   プラットフォームログがない場合は診断設定と転送先を確認し、照会ツールが使えない場合にだけ接続状態を調べる。
6. 影響、原因、対策の根拠を区別する。
   プローブ周期だけで無停止や復旧時間の上限を保証しない。
   ディスク IO からファイル固有の書き込みや内部機構を、空きメモリだけから OOM 発生を断定しない。
7. 変更が必要なら、対象、差分、影響、最小権限、ロールバック、復旧条件を提示する。
   変更後の値は、デプロイ定義、ナレッジ、正常なリソースとの比較で根拠を示せる既知の正常値に限定し、推測で選ばない。
   Chaos 実験が終了済みなら停止を提案せず、稼働中で停止が必要な場合だけ承認を待つ。
8. 調査フェーズでは変更を実行せず、変更レビュー依頼を出力して停止する。
   同じスレッドで実施者から明示的なレビュー依頼を受けるまで修復スキルを使用しない。
9. 調査完了後に、時刻、状態、根拠を含む時系列を Markdown の表で示す。
   Mermaid を併用する場合も表を残し、図が描画できないときに時系列を失わないようにする。

## 出力

影響、時系列、証拠、原因候補、未確認事項、推奨アクション、
ロールバック、復旧確認条件を含む構造化レポートを返す。

このハンズオンのプローブ復旧演習では、実施者が正常時の記録と
`break-appgw-probe.sh` の実行結果を提示した場合に、次の条件で調査します。

1. 正常時記録に、同じ対象のリソース ID、採取時刻、プローブ設定、
   全バックエンドの Healthy、Gateway 経由の HTTP 200 があることを確認する。
2. 障害注入記録に実行時刻と成功結果があり、実施者がプローブのパスだけを
   `/healthz` に変更し、ほかの障害や構成変更を加えていないことを確認する。
3. `RunAzCliReadCommands` で現在のプローブ設定と backend health を取得する。
   正常時とのプローブ設定の差分がパスだけで、全バックエンドが HTTP 404 により
   Unhealthy なら、`/health.htm` へ戻す変更レビュー依頼を作成する。
   正常値の根拠は正常時記録とする。ナレッジ検索は必須にしない。
4. 記録不足、対象不一致、想定外の設定差分や症状があれば、変更案を確定せず、
   不足または不一致を示して停止する。現在のパスが `/health.htm` なら変更しない。
5. 影響、時系列、証拠、変更差分、実行予定コマンド、必要最小権限、
   ロールバック、復旧確認条件を示して停止する。
   実施者からレビューと変更開始の依頼を受けるまで修復スキルを使わない。

根拠には Gateway の読み取り結果と実施者の記録だけを使います。
記録にない状態を推測で補いません。
それ以外の障害では、前述の一般的な調査手順を使います。
```

4. **ツール** → **ツールを選択する** で、次のツール名を検索して選択します。

   | 選択するツール名 | 用途 |
   |---|---|
   | `QueryLogAnalyticsByResourceId` | Azure リソース ID で指定した Log Analytics ワークスペースの `Perf`、`Event`、`AzureActivity` を KQL で照会する |
   | `RunAzCliReadCommands` | Azure Monitor メトリクス、対象リソースの構成と状態、Chaos 実験の状態を `az ... show`、`az ... list` などの読み取り操作で確認する |

   `QueryLogAnalyticsByResourceId` だけでは Azure Monitor のネイティブ メトリクスや Chaos 実験の現在状態を取得できないため、`RunAzCliReadCommands` も必要です。`RunAzCliWriteCommands`、`RunShellCommand`、`ExecutePythonCode` などの変更または任意コード実行が可能なツールはスキルに追加しません。
5. **作成** を選択します。

![alt text](./imgs/agentskill.png)

### 2. 修復スキルを作成する

明示的なレビュー依頼を受けたときだけ使う、承認付きの修復手順を作成します。
対象はこのラボのプローブ誤設定 `/healthz` → `/health.htm` だけに限定します。

1. **ビルダー** → **エージェント キャンバス** → **+ 作成** → **スキル** を選択します。
2. `SKILL.md` を次の内容にします。

```markdown
---
name: srelab-appgw-probe-remediation
description: 実施者からレビューと変更開始を依頼されたとき、ラボのプローブ復旧案を再検証し、Review モードの承認後にパスだけを戻す
---

## 使用条件

同じスレッドに変更レビュー依頼があり、実施者から明示的にレビューと変更開始を依頼されたときに使用する。
対象はラボ RG の Application Gateway のプローブ `iis-health`、変更は `/healthz` から `/health.htm` へのパス更新 1 件に限る。

## レビュー条件

- 正常時記録に、同じ対象の ID、採取時刻、プローブの全設定、
  全バックエンドの Healthy、Gateway 経由の HTTP 200 がある。
- 障害注入記録に `break-appgw-probe.sh` の実行時刻と成功結果がある。
  実施者が、パスだけを `/healthz` に変更し、ほかの障害や構成変更を加えていないと明示している。
- 最新のプローブ設定は正常時と比べてパスだけが異なり、現在値は `/healthz` である。
- 最新の backend health で、全バックエンドが HTTP 404 により Unhealthy である。
- 変更差分、実行予定コマンド、影響、必要最小権限、ロールバック、復旧条件が、
  この 1 件のパス更新に対応している。

正常値の根拠は提示された正常時記録とし、ナレッジ検索は必須にしない。
Gateway の観測と提示された記録を使い、バックエンドのプライベート IP への接続は行わない。

## 手順

1. `RunAzCliReadCommands` で対象の完全なリソース ID、プローブ設定、backend health を再取得し、
   レビュー条件を検査する。不足や不一致があれば「レビュー結果: 不合格」と理由を示して停止する。
2. 現在のパスが `/healthz` でなければ変更せず停止する。`/health.htm` なら変更不要、それ以外は想定外の値として所有者確認を求める。
3. レビュー条件を満たしていても、スキルが有効な状態で `RunAzCliWriteCommands` が実行時のツールセットにない場合は、
   「レビュー結果: 実行保留（ツール未提供）」と報告する。別の実行ツールに切り替えず停止する。
4. レビュー条件を満たし、書き込みツールを利用できる場合だけ「レビュー結果: 合格」と根拠を示す。
   `RunAzCliWriteCommands` で次の 1 コマンドだけを呼び出す。値は確認済みの実値に置き換える。
   `az network application-gateway probe update --subscription <SUBSCRIPTION_ID> --resource-group <RG> --gateway-name <APPGW_NAME> --name iis-health --path /health.htm`
5. Review モードの Approve / Deny を待つ。Deny の場合は再実行せず、追加確認事項を返して停止する。
6. 承認後、実行結果を確認して最新のプローブ設定と backend health を取得する。
   パスが `/health.htm` に戻り、全バックエンドが Healthy であることを確認する。
   実施者に Gateway 経由の HTTP 応答を提示してもらい、200 であることを確認する。
   アラート状態を取得できる場合は確認する。取得できない場合は実施者に Azure Monitor での確認を依頼する。
   アラートが未解消または未確認なら、その状態を記録する。
7. 書き込みが失敗した場合や復旧条件を確認できない場合は、結果と未確認事項を示して停止する。
   追加の変更、再試行、ロールバックを自動実行しない。

## 禁止事項

- バックエンド、ポート、HTTP 設定、NSG、VM、IIS を同時に変更しない。
- `/` など、既知の正常値として根拠がないパスへ変更しない。
- 承認待ちを文章だけで表現して終了せず、書き込みツールを呼び出して承認ゲートを表示する。

## 出力

対象 ID、変更前後の値、実行コマンド、承認結果、実行時刻、復旧確認結果、未確認事項を返す。
```

3. **ツール** → **ツールを選択する** で、`RunAzCliReadCommands` と `RunAzCliWriteCommands` を選択します。
4. **作成** を選択し、保存後にスキルの編集画面を開き直して、両ツールが選択済みであることを確認します。

このスキルは、[手順 3](#3-カスタム-エージェントを作成する) で調査スキルとともに 1 つのエージェントに割り当てます。

スキルの条件や指示だけでは書き込み権限を分離できません。
書き込みの実行可否は Review モードの承認と SRE Agent のマネージド ID の RBAC で制御されます。
Deploy to Azure の **Sre Agent Access Level** を既定の `High` にした場合、ラボ RG の Contributor が付与されています（[セットアップ](sre-agent-setup.md)）。

### 3. カスタム エージェントを作成する

1. **ビルダー** → **エージェント キャンバス** → **+ 作成** → **カスタム エージェント** を選択します。
2. 次を設定します。

   | 項目 | 値 |
   |---|---|
   | カスタム エージェント名 | `srelab-triage-agent` |
   | 指示 | 下記の調査・変更レビュー用指示 |
   | スキル | `srelab-incident-triage`、`srelab-appgw-probe-remediation` |

```text
あなたは SRE Agent Lab の調査と変更レビューを担当します。

調査依頼には srelab-incident-triage を使い、読み取り専用で調査してください。
プローブ復旧演習では、実施者が提示する正常時記録と障害注入記録を、
現在のプローブ設定と backend health に照合してください。
変更案には対象の完全な ID、証拠と時系列、差分、実行予定コマンド、
影響、必要最小権限、ロールバック、復旧条件を含めてください。
「変更レビュー依頼」を出力して停止し、調査中は修復スキルを使わないでください。
記録不足や想定外の症状は明示し、取得していない状態を推測で補わないでください。

同じスレッドで実施者からレビューと変更開始を依頼されたら、
対象と差分が iis-health の /healthz から /health.htm への変更 1 件であることを確認し、
srelab-appgw-probe-remediation を読み込んでください。
レビュー条件の検査、最新状態の確認、書き込みツールの確認はそのスキルに従ってください。
現在のパスが /health.htm なら変更不要として停止してください。
情報不足や不一致は不合格、スキルや書き込みツールの未提供は実行保留として停止してください。
条件を満たす場合だけ書き込みツールを呼び出し、Review モードの Approve / Deny を待ってください。
実施者の変更開始依頼を Approve 操作の代わりとして扱わないでください。
別のエージェントやツールに切り替えて変更しないでください。
```

3. **ツール** → **ツールを選択する** で `QueryLogAnalyticsByResourceId` と `RunAzCliReadCommands` だけを選択します。個別に選択してグローバル設定を上書きし、書き込みツールを直接継承させないようにします。
4. **作成** を選び、保存後に編集画面を開き直して両スキルと読み取りツールの選択を確認します。`RunAzCliWriteCommands` はエージェントに直接割り当てず、修復スキル経由でだけ使用させます。

### 4. 継承表示と自律性レベルを確認する

1. エージェント キャンバスで `srelab-triage-agent` のカードを確認します。ツールまたはスキルを 1 つでも選択して保存すると、グローバル設定の継承が上書きされます。選択した読み取りツールと 2 つのスキルだけが設定されていることを確認します。
2. カードに表示される **自律** は、カスタム エージェント個別に切り替える設定ではありません。モードは対応計画またはスケジュールされたタスク単位で設定されます。YAML タブにも `agent_type: Autonomous` と表示されますが、この値を変更しても保存・反映されません（新規作成時も同様です）。
3. `srelab-triage-agent` の直接の Tools 欄には読み取りツールだけが表示され、修復スキルが選択されていることを確認します。
   `RunAzCliWriteCommands` は修復スキルを読み込んでいる間だけ利用可能です（[スキルのツールと有効期間](https://learn.microsoft.com/azure/sre-agent/skills#limits-and-constraints)）。
   Review モードの承認ゲートを確認する前に、書き込みツールへの Allow ポリシーや承認を省略するフックがないことを確認します。
   これらがなくツールが実際に呼び出せる場合、実行前に **Approve** / **Deny** が表示されます。
4. 対応計画（`srelab-alerts-review`）経由のインシデント対応には、[Level 1 で設定した **Review** モード](#1-インシデント対応計画を作成する)が適用されます。対応計画を経由しないチャットではエージェント全体の既定モードが使われるため、**設定** → **基本** のモードも **Review** であることを確認します（デプロイ時の既定値は `sreAgentMode=Review` です）。
5. 承認ボタンを操作できるのは **SRE Agent Administrator** だけです。承認するユーザーにこのロールがあることを確認します。

### 5. プレイグラウンドで調査フェーズをテストする

プレイグラウンドでは、調査フェーズが読み取り専用で進むかだけを確認します。
障害注入は不要です。

正常状態では変更案が出ず、修復スキルと承認ゲートは確認できません。
この手順では読み取り専用の調査だけを確認します。

1. エージェント キャンバス の **テスト プレイグラウンド** を開きます。
2. `srelab-triage-agent` を選び、次を入力します。

```text
Application Gateway の直近 3 時間のバックエンド正常性とプローブ設定を調査してください。
実施者が提示した正常時記録と障害注入記録がない場合は、変更案を作らず必要な記録を示してください。
現在のプローブ設定とバックエンド正常性を再取得し、事実と未確認事項を分けてください。
```

3. 次を確認します。
   - `srelab-incident-triage` の手順に沿って、事実、原因候補、未確認事項を分けて出力している。
   - API や KQL の取得失敗、空結果、null を正常や「接続なし」と断定せず、実際の応答と設定を確認している。
   - 時系列が Markdown 表で読める。Mermaid を併用した場合は、プレイグラウンドで描画エラーがないことを確認する。
   - 正常時記録、障害注入記録、現在のプローブ設定、backend health を照合している。
   - 記録が不足する場合は、必要な記録を具体的に示し、取得していない状態を推測していない。
   - 調査フェーズで修復スキルを読み込まず、変更を実行していない。
   - プローブが `/health.htm` で全バックエンドが Healthy であれば、変更案を作らず「変更不要」と結論している（この場合に変更レビュー依頼が出ないのは正しい挙動です）。

### 6. 対応計画をカスタム エージェントへルーティングして承認付き変更を確認する

1. Level 1 で作成した `srelab-alerts-review` を編集します。
2. **応答エージェント**を `srelab-triage-agent` に変更します。

![alt text](imgs/response-agent-change.png)

3. モードが **Review** のままであることを確認して保存します。
4. Azure Monitor アラートの受信を確認する前に、[セットアップの権限確認](sre-agent-setup.md#手順-4-応答プランを作成してアラート受信を確認)に従い、SRE ID のロールとスコープを確認します。
   必要なサブスクリプション権限がない場合は管理者の承認を得るまで先へ進まず、Owner / Contributor を代替として付与しません。
   また、修復スキルに `RunAzCliWriteCommands` が保存され、`srelab-triage-agent` に両スキルが選択されていることを確認します。
   これは設定の確認であり、スキルを読み込んだ実行時にツールが使えることの確認ではありません。
   書き込みツールに一致する Allow ポリシー（グローバル、カスタム エージェント、スレッド）や承認を省略するフックがある場合は、承認ゲートを確認できないため障害注入を始めません。
5. 共通準備で使用した Cloud Shell（Bash）などの環境に戻り、Azure portal のデプロイ画面で記録した値を設定します。`SUBSCRIPTION_ID` と `RESOURCE_GROUP` はスクリプトの子プロセスにも渡るよう `export` します。

   ```bash
   export SUBSCRIPTION_ID="<対象のサブスクリプション ID>"
   export RESOURCE_GROUP="<resourceGroupName の値>"
   APPGW_NAME="<appGwName の値>"
   APPGW_IP="<appGwPublicIp の値>"
   ```

6. 障害注入の前に、対象 ID、プローブ、backend health、Gateway の HTTP 応答を記録します。
   これがエージェントの変更レビューで使う正常時の基準です。

   ```bash
   date -u '+sampledAtUtc=%Y-%m-%dT%H:%M:%SZ'
   az network application-gateway show --subscription "$SUBSCRIPTION_ID" \
     -g "$RESOURCE_GROUP" -n "$APPGW_NAME" --query id -o tsv
   az network application-gateway probe show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" \
     --gateway-name "$APPGW_NAME" -n iis-health \
     --query "{id:id,name:name,protocol:protocol,host:host,path:path,interval:interval,timeout:timeout,unhealthyThreshold:unhealthyThreshold,match:match}" -o json
   az network application-gateway show-backend-health --subscription "$SUBSCRIPTION_ID" \
     -g "$RESOURCE_GROUP" -n "$APPGW_NAME" \
     --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,healthProbeLog:healthProbeLog}" -o table
   curl -s -o /dev/null -w '%{http_code}\n' "http://$APPGW_IP/"
   ```

   プローブが `/health.htm`、全バックエンドが Healthy、Gateway の応答が `200` であることを確認します。
   時刻、コマンド出力、対象 Gateway の ID を記録してください。バックエンド一覧は省略せず、各アドレスと状態を残します。
   3 条件が揃わない場合は障害を注入せず、先に正常状態へ戻します。
   正常時の記録がないと、後の変更レビューを完了できません。

   次に、実施者がパスだけを変更します。
   変更前後の出力と UTC 時刻を記録し、別の障害や構成変更を加えないでください。

   ```bash
   date -u '+faultInjectionStartedAtUtc=%Y-%m-%dT%H:%M:%SZ'
   bash scripts/break-appgw-probe.sh
   date -u '+faultInjectionCompletedAtUtc=%Y-%m-%dT%H:%M:%SZ'
   ```

7. Sev1 の `UnhealthyHostCount` アラートが発報し、`srelab-triage-agent` が担当するインシデント スレッドが自動作成されることを確認します。メトリクスの評価、アラートの取り込み、ロール設定にはそれぞれ確認が必要です。
   インシデント スレッドで、先ほどの正常時記録と次の障害注入記録を提示します。
   続けて調査を依頼し、エージェントが変更レビュー依頼を出して停止することを確認します。

   ```text
   【正常時の記録】
   Gateway ID: <対象リソース ID>
   採取時刻 (UTC): <時刻>
   probe iis-health の設定: <上の Azure CLI 出力を貼り付け>
   全バックエンドのアドレス、状態、healthProbeLog: <CLI 出力を貼り付け>
   Gateway 経由の HTTP 応答: 200
   Gateway ID と採取時刻を含め、上記の値は直前の Azure CLI 出力から転記してください。

   【障害注入の記録】
   スクリプト: bash scripts/break-appgw-probe.sh
   実行時刻 (UTC): <開始時刻と完了時刻>
   結果: 成功
   変更内容: probe iis-health の path だけを /health.htm から /healthz に変更
   ほかの障害注入や構成変更: なし
   実行結果を確認して、値と時刻を実際の出力に置き換えてください。

   上の記録と現在のプローブ設定、backend health を照合し、
   変更レビュー依頼を作成してください。
   変更は実行せず、レビュー依頼を出したところで停止してください。
   記録不足や想定外の差分があれば、変更案を確定せず、不足事項を示してください。
   ```

8. インシデント スレッドで、調査担当が次を含む「変更レビュー依頼」を出して停止したことを確認します。
   - 対象: プローブ `iis-health` の完全なリソース ID
   - 差分: パス `/healthz` → `/health.htm`
   - 根拠: 実施者が提示した正常時記録、障害注入の実行結果と時刻、最新のプローブ設定、backend health
   - 実行予定の `az network application-gateway probe update ... --path /health.htm`
   - 影響、最小権限、ロールバック、復旧確認条件

9. 変更レビュー依頼の対象と差分を確認します。
   同じスレッドでエージェントを切り替えず、次を入力します。
   これはレビューと変更開始の依頼です。Approve の代わりにはなりません。

```text
上に提示した正常時記録と障害注入記録を使い、直前の変更レビュー依頼を再確認してください。
対象 ID、現在のプローブ設定、backend health を読み取り操作で再取得してください。
記録不足や不一致があれば不合格として不足事項を示し、変更しないでください。
レビュー条件を満たす場合は srelab-appgw-probe-remediation の手順に従ってください。
書き込みツールが実行時に提供されない場合は実行保留とし、別のツールで変更しないでください。
条件を満たす場合は書き込みツールを呼び出し、
Review モードの Approve / Deny を待ってください。
```

10. 同じエージェントが修復スキルを読み込んでレビュー結果を示し、実際の書き込みツール呼び出しで **Approve** / **Deny** が表示されることを確認します。
    レビュー結果はエージェント自身による再検証であり、独立した二者レビューではありません。
    「ツールがセッションにない」と報告された場合は実行保留です。設定ファイルにツール名があるだけで合格とせず、[トラブルシューティング](#承認ボタンが表示されない場合)に進みます。
    承認画面に表示されたコマンドの対象、プローブ名、パスがレビュー結果と一致することを確認します。
11. 承認画面のコマンドで対象 Gateway、プローブ名、変更後のパスが変更レビュー依頼と一致することを確かめてから **Approve** を選びます。
12. エージェントが実行結果を返したら、プローブ設定とバックエンド状態を読み取り操作で確認します。
    プローブ周期と反映を待ち、次でも確認します。

    ```bash
    az network application-gateway probe show --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
      -n iis-health --query path -o tsv
    az network application-gateway show-backend-health --subscription "$SUBSCRIPTION_ID" -g "$RESOURCE_GROUP" -n "$APPGW_NAME" \
      --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health}" -o table
    curl -s -o /dev/null -w '%{http_code}\n' "http://$APPGW_IP/"
    ```

    パスが `/health.htm`、全バックエンドが `Healthy`、HTTP 応答が `200` なら、記載した復旧条件を満たしています。
    Azure Monitor でアラートの解消も確認します。

13. 承認ボタンが表示されずに終了した場合は、プローブが `/healthz` のままであることを読み取りで確認し、[トラブルシューティング](#承認ボタンが表示されない場合)を確認します。
    ツールが利用できない状態で障害を残せない場合は、実施者が対象と操作内容を確認し、別途承認を得て手動で復旧します。
    手動復旧は Level 2 の承認付き自動修復の成功には含めません。

    ```bash
    bash scripts/fix-appgw-probe.sh
    ```

14. 次を確認します。
    - 調査フェーズで変更を実行していない。
    - 明示的なレビュー依頼後に、同じエージェントが同じスレッドの変更レビュー依頼を参照し、現在値を読み取りで再確認している。
    - 正常時記録と障害注入記録が揃わない場合や想定外の差分がある場合、合格にしていない。
    - 変更は **Approve** の後に 1 件だけ実行され、バックエンド、ポート、NSG などを変更していない。
    - 実行結果に承認結果、変更前後の値、復旧確認結果が含まれる。

#### 承認ボタンが表示されない場合

| 症状 | 確認すること |
|---|---|
| エージェントが「承認をお願いします」と文章だけで終了する | スキルと指示が保存されているか。同じスレッドでスキルを読み込み直して手順 3 のツール確認から再開し、実際に書き込みツールが呼び出されたか確認する。文章上の承認依頼だけでは変更しない |
| 修復スキルが読み込まれない | `srelab-triage-agent` に `srelab-appgw-probe-remediation` が選択されているか、スキルの説明が使用条件と一致するか確認する。会話の圧縮でスキルが解除された場合は同じスレッドで読み込み直す |
| `RunAzCliWriteCommands` がセッションのツールセットにない | エージェントの直接の Tools 欄ではなく、保存済みの修復スキルの Tools 欄に書き込みツールが選択されているか確認する。スキルを読み込み直しても実行時に提供されなければ、設定上の選択、スキルの読み込み状況、ツール不足のエラーと時刻を記録して停止する。グローバル Allow やエージェントへの直接付与で迂回しない |
| ツールはあるが呼び出しが拒否される | 「ツールがない」と区別し、**設定** → **アクセス許可** のグローバル Deny と適用対象を管理者と確認する。Deny を無断で解除しない |
| 承認なしで実行された | スレッドが Review の対応計画から作成されたか、**設定** → **基本** が Review か、書き込みツールに一致する Allow ポリシーや承認を省略するフックがないか確認する。結果を記録し、承認ゲートを回復するまで修復スキルをエージェントから外す |
| Approve を選択できない | 承認者に SRE Agent Administrator があるか |
| 承認後に権限エラーになる | SRE Agent のマネージド ID に対象 Application Gateway の更新権限があるか |

エージェント設定を変更した場合は、新しい設定が既存のインシデント スレッドに反映されないことがあります。
更新した設定を試すには、新しいインシデント スレッドを作成してください。

### Level 2 の合格条件

- [ ] 調査スキルと修復スキルが作成された。
- [ ] 1 つのカスタム エージェントに両スキルと読み取りツールを選択し、引き継ぎ先（handoff）を設定していない。
- [ ] エージェントのカードが継承ではなく選択したツール・スキルを表示し、書き込みツールを直接割り当てていない。
- [ ] 修復スキルを読み込んだ実行時に `RunAzCliWriteCommands` が提供されることを確認した。
- [ ] 対応計画が `srelab-triage-agent` へルーティングされる。
- [ ] 同じインシデント スレッドで明示的なレビュー依頼を受けてから、同じエージェントが変更レビュー依頼を再検証した。
- [ ] 初回の調査結果で、時系列と根拠を示した。
- [ ] 書き込み操作の前に **Approve** / **Deny** が表示され、承認後にだけプローブが変更された。
- [ ] 手動復旧やツール不足による実行保留を、承認付き自動修復の成功として扱っていない。
- [ ] 全バックエンドの Healthy と Gateway 経由の HTTP 200 を確認し、Azure Monitor でアラート状態を確認した。

## Level 3: ナレッジベースを整備する

### ゴール

ラボ固有の構成と運用ルールをナレッジベースへ登録し、新しい会話でも文書を出典として再利用できる状態を作ります。

### 1. `/learn` が作成したメモリを確認する

`/learn` が作成する `overview.md`、`architecture.md`、`logs.md`、`debugging.md`、`team.md` は、エージェントの **メモリ**（`memories/synthesizedKnowledge/`）に保存されます。
スレッドには `Created memory: logs.md` のように表示されます。
アップロードした文書を管理する **ナレッジ ソース** には表示されません。

`overview.md` は会話の開始時に自動で読み込まれ、その他のファイルは必要に応じて参照されます。

1. 新しいチャットで次を入力します。

   ```text
   /learn で保存したナレッジ ファイルの一覧と、各ファイルの要点を表示してください。
   確認時刻と、検証済みの事実と未確認事項を区別してください。
   ```

2. 内容が現在のラボ構成と一致していることを確認します。リソース名、RG、しきい値などが実際の環境と異なる場合は、対象のファイル名と正しい内容を指定して、同じチャットで修正を依頼します（例:「`architecture.md` に記載された RG 名を、実際の `resourceGroupName` に修正してください」）。

### 2. ナレッジ ソースに運用ベースラインを登録する

1. このリポジトリの [`docs/knowledge/sre-lab-operating-baseline.md`](knowledge/sre-lab-operating-baseline.md) の **最終確認日** を実施日に更新します。
2. SRE Agent ポータルで **ビルダー** → **ナレッジ ソース** を開き、**ファイルを追加する** からアップロードします。
3. 状態が **インデックス作成済み** になるまで待ちます。`Pending` の場合は少し待って更新します。

![alt text](imgs/knowledge-source.png)

実際の調査結果を記入した Runbook も必要に応じて追加できます。
空のテンプレートや未確認の推測はナレッジに登録しないでください。

### 3. カスタム エージェントへナレッジ利用を許可する

1. エージェント キャンバスの **テスト プレイグラウンド** を開き、**サブエージェント** で `srelab-triage-agent` を選択します。
2. **詳細設定** の **ナレッジ ベースへのアクセス権を付与する** をオンにして保存します。

### 4. カスタム エージェントを呼び出して検索を検証する

**ナレッジ ベースへのアクセス権を付与する** はカスタム エージェントごとの設定です。既定のエージェント (Meta Agent) との新しいチャットではこの設定が使われないため、必ず `srelab-triage-agent` を直接呼び出して確認します。過去の会話コンテキストに依存しないことを確認するため、次のいずれかの方法でコンテキストのない状態から呼び出します。

- エージェント キャンバスの **テスト プレイグラウンド** を開き直し、**サブエージェント** で `srelab-triage-agent` を選択する。
- 新しいチャットを作成し、`/agent` で `srelab-triage-agent` を選択する。

```text
SRE Agent Lab で IIS 停止が疑われる場合の、最初の復旧操作と禁止事項を説明してください。
ナレッジベースを検索し、使用した文書名をソースとして示してください。
文書にない情報は推測で補わず、未記載としてください。
```

`sre-lab-operating-baseline.md` には「禁止事項」「復旧確認」「エスカレーション条件」を明記していますが、検索言語ごとの挙動は、文書、インデックス、権限、サービスの状態によって変わる可能性があります。日本語だけのクエリが必ず失敗する、または検索結果がない理由は言語だけだと決めつけないでください。

検索結果を比較するときは、同じ文書と権限を使い、新しい会話から日本語、英語、文書中の英数字の固有語をそれぞれ検索します。
各クエリの結果件数、出典、実施日時を記録します。

結果がない場合は、ナレッジ ソースのインデックス状態、対象エージェントのアクセス設定、クエリと文書の内容を確認します。
確認できていない原因を断定しないでください。

回答が `/learn` のメモリ（`debugging.md` など）だけを出典にしている場合は、次を確認します。

1. 同じチャットで、文書内の英数字トークンを含めて聞き直します（例:「`ManualDenyAppGatewayHTTP` 以外の規則を変更してよいか教えてください」）。ヒットすれば検索自体は機能しています。
2. 文書と質問の表記が大きく異なる場合は、見出しや主要語に英語の別名を併記し、再インデックス後に同じ条件で再検証します。英語キーワードを追加しても、日本語の質問が必ずヒットするとは限りません。

続けて、文書にない情報を尋ねます。

```text
このラボの本番環境の SLA とオンコール担当者名を教えてください。
ナレッジベースに根拠がなければ、推測せず不足情報として回答してください。
```

本番 SLA や担当者名を創作せず、情報不足として扱えば成功です。

![alt text](./imgs/wrongquery.png)

### 5. 調査結果を Runbook として追加する

Level 1 または Level 2 の調査スレッドで、次を入力します。

```text
この調査で確認できた事実だけを使い、原因、診断手順、緩和策、
エスカレーション条件、復旧確認条件を含む Runbook を作成してください。
推測と未確認事項は明示し、メモリではなくナレッジ ソース (Knowledge settings) に
srelab-cpu-investigation-runbook.md として保存してください。
```

保存後、**ナレッジ ソース** で **Indexed** を確認し、新しいチャットから検索できることを確認します。

ナレッジ ソースに表示されず、スレッドに `Created memory` と表示された場合はメモリに保存されています。
その場合は、エージェントが作成した Runbook を Markdown ファイルとして保存し、**Add file** からアップロードします。

![alt text](imgs/uploadedknowledge1.png)
![alt text](imgs/uploadedknowledge2.png)

### 6. 更新と廃止のルールを決める

- 文書には対象環境、所有者、確認日、有効期限を記載する。
- 同名ファイルを再アップロードして更新し、古い手順を併存させない。
- 障害対応後に Runbook の事実と手順をレビューする。
- 削除したリソースや廃止した手順の文書はナレッジベースから削除する。
- 回答に出典が表示されることを定期的にテストする。

### Level 3 の合格条件

- [ ] `/learn` が作成したメモリの内容を確認し、誤りがあれば修正した。
- [ ] `sre-lab-operating-baseline.md` がナレッジ ソースで **Indexed** である。
- [ ] カスタム エージェントがナレッジを利用できる。
- [ ] 新しいチャットで登録文書が Sources に表示される。
- [ ] 文書にない SLA や担当者名を創作しない。
- [ ] 実際の調査結果から作成した Runbook を再検索できる。

## ハンズオン終了時の確認

| 確認項目 | 完了 |
|---|---|
| 対応計画のルーティング先、重大度、Review モードを記録した | [ ] |
| カスタム エージェント、スキル、ツール、同じスレッドでのレビュー開始手順を記録した | [ ] |
| 修復スキルによる変更の承認者、変更前後の値、復旧確認結果を記録した | [ ] |
| Application Gateway のプローブが `/health.htm` に戻っている | [ ] |
| ナレッジ文書の所有者と更新日を記録した | [ ] |
| デモ用の定期タスクと不要な対応計画を無効化した | [ ] |
| 実行中の Chaos 実験がないことを確認した | [ ] |
| 必要な調査記録を保存した | [ ] |

ラボを終了する場合は、[README の削除手順](../README.md#ラボを削除する)に従います。
VM の停止だけでは Application Gateway、NAT Gateway、Public IP、ディスクなどの課金は止まりません。

## 公式ドキュメント

- [Tools | Azure SRE Agent](https://sre.azure.com/docs/concepts/tools)
- [Tools & Skills | Azure SRE Agent](https://sre.azure.com/docs/capabilities/global-tools-page)
- [Create an incident response plan](https://learn.microsoft.com/azure/sre-agent/response-plan)
- [Create a Custom Agent](https://sre.azure.com/docs/tutorials/automation/create-subagent)
- [Create a skill](https://learn.microsoft.com/azure/sre-agent/create-skill)
- [Skills in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/skills)
- [Run modes in Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Upload knowledge documents](https://learn.microsoft.com/azure/sre-agent/tutorial-upload-knowledge-document)
- [Agent playground](https://learn.microsoft.com/azure/sre-agent/agent-playground)
- [Tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)
