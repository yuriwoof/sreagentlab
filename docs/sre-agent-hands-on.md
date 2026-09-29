# Azure SRE Agent ステップバイステップ ハンズオン

このハンズオンでは、Azure SRE Agent を一度に作り込まず、運用能力を 3 段階で拡張します。
各レベルは前のレベルの成果を再利用します。最初は必ず **Review** モードと読み取り専用の調査から始めてください。

| レベル | 学ぶこと | 成果物 | 目安 |
|---|---|---|---|
| 1 | 単一エージェントによるアラート調査 | Review モードのインシデント対応計画と調査記録 | 20 分 |
| 2 | サブエージェントとスキルによる役割分担 | 調査用・変更レビュー用サブエージェントと調査スキル | 25 分 |
| 3 | ナレッジベースによる組織知の再利用 | インデックス済み文書と出典付きの調査回答 | 15 分 |

> Azure SRE Agent はプレビュー機能を含みます。ポータルの表示名が本書と異なる場合は、現在のポータル表示と[公式ドキュメント](https://learn.microsoft.com/azure/sre-agent/overview)を優先してください。

## 共通準備

### 1. ラボをデプロイする

1. [README](../README.md#1-deploy-to-azure-でデプロイ)に従って専用リソースグループへデプロイします。
2. デプロイ出力の `sreAgentPortalUrl`、`resourceGroupName`、`lawName` を記録します。
3. Gateway URL を開き、IIS のページが HTTP 200 を返すことを確認します。

### 2. SRE Agent をオンボードする

1. `sreAgentPortalUrl` を開きます。
2. [初回オンボーディング](sre-agent-setup.md#手順-1-初回オンボーディングで-azure-monitor-を接続)に従い、インシデント プラットフォームとして **Azure Monitor** を接続します。
3. [手順 2: `/learn` の実行結果を確認](sre-agent-setup.md#手順-2-learn-の実行結果を確認)に従い、初期状態、管理対象リソース、取得できない情報と権限を確認します。不足がある場合だけ同じスレッドで追加調査します。
4. エージェントのモードが **Review** であることを確認します。自動修復を試すハンズオンではありません。

**チェックポイント:** `/learn` の結果に対象 RG、主要リソース、テレメトリの確認時刻、未確認事項が記録され、欠損を正常値として扱っていないこと。

## Level 1: インシデント対応計画を作成し、単一エージェントで調査する

### ゴール

Azure Monitor アラートを SRE Agent にルーティングし、エージェントが証拠を集めて修復案を提示し、実行前に人の承認を待つ状態を作ります。

### 1. インシデント対応計画を作成する

1. [応答プランの作成手順](sre-agent-setup.md#手順-4-応答プランを作成してアラート受信を確認)を開きます。
2. `srelab-alerts-review` を作成し、Sev1 と Sev2 を対象にします。
3. **応答エージェント** は既定のエージェントを選択します。
4. **エージェントの自律性レベル** は **Review** を選択します。
5. 作成後、状態が **オン**、モードが **Review** であることを確認します。
6. 既定の `quickstart_handler` が存在する場合は、二重処理を避けるため無効化または削除します。

### 2. CPU 高騰を発生させる

リポジトリのルートから Bash で実行します。複数のラボがある場合は `RESOURCE_GROUP` を指定してください。

```bash
bash scripts/run-chaos.sh start cpu
bash scripts/run-chaos.sh status cpu
```

Azure Monitor の評価と SRE Agent への取り込みを待ちます。5 分の評価窓があっても、必ず 5 分で発報するとは限りません。

### 3. エージェントの調査を評価する

自動作成されたインシデント スレッドを開き、次を確認します。

1. 対象 VM と同じ期間の Application Gateway の状態を比較している。
2. Chaos 実験の開始時刻とメトリクス変化を相関している。
3. 事実、原因候補、未確認事項を区別している。
4. プロセス停止や VM 再起動を勝手に実行していない。
5. 最初の復旧案として、Chaos 実験の停止を提案して承認を待っている。

不足がある場合は、同じスレッドで次を入力します。

```text
調査結果を、影響、時系列、確認済みの証拠、原因候補、未確認事項、
推奨する次の操作、ロールバック、復旧確認条件の順に整理してください。
変更操作は実行せず、承認を待ってください。
```

### 4. 実験を停止して復旧を確認する

```bash
bash scripts/run-chaos.sh stop cpu
bash scripts/run-chaos.sh status cpu
```

CPU の低下、Gateway 経由の HTTP 200、実験終了、アラート解消を確認します。
結果は[承認付き修復の Runbook](runbook-template.md)の項目に沿って記録します。

### Level 1 の合格条件

- [ ] 対応計画が **オン / Review** である。
- [ ] CPU アラートから 1 件の調査スレッドが作成された。
- [ ] 調査に対象、期間、証拠、未確認事項が含まれる。
- [ ] 修復操作は承認前に実行されていない。
- [ ] 実験停止後の復旧条件を確認した。

## Level 2: サブエージェントとスキルで役割を分ける

### ゴール

「証拠を集める担当」と「変更案をレビューする担当」を分離し、繰り返し使う調査手順をスキルとして定義します。

### 1. 調査スキルを作成する

1. SRE Agent ポータルで **Builder** → **Agent Canvas** を開きます。
2. **+ Create skill** を選択します。
3. 次を設定します。

   | 項目 | 値 |
   |---|---|
   | Name | `srelab-incident-triage` |
   | Description | `SRE Agent Lab の VM、IIS、Application Gateway、NSG のアラートを読み取り専用で調査するときに使用する` |

4. `SKILL.md` を次の内容にします。

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
3. Azure Monitor メトリクス、Perf、Event、AzureActivity を用途別に使い分ける。
4. Chaos 実験中なら、実験開始時刻と症状の相関を確認する。
5. 事実、原因候補、未確認事項を分ける。欠損値を 0 とみなさない。
6. 変更が必要なら、対象、差分、影響、最小権限、ロールバック、復旧条件を提示する。
7. Review モードでは変更を実行せず、承認を待つ。

## 出力

影響、時系列、証拠、原因候補、未確認事項、推奨アクション、
ロールバック、復旧確認条件を含む構造化レポートを返す。
```

5. **Tools** には、Azure Monitor メトリクス、Log Analytics、Resource Health など、調査に必要な読み取り専用ツールだけを選びます。表示されるツール名はポータルで確認してください。
6. **Create** を選択します。

### 2. 調査用サブエージェントを作成する

1. **Builder** → **Agent Canvas** → **+ Create subagent** を選択します。
2. 次を設定します。

   | 項目 | 値 |
   |---|---|
   | Subagent name | `srelab-triage-agent` |
   | Instructions | 下記の調査用指示 |
   | Handoff instructions | `Azure Monitor のアラートまたはラボの障害調査を依頼されたときに引き継ぐ` |
   | Enable Skills | オン |
   | Allowed Skills | `srelab-incident-triage` |
   | Give access to knowledge base | Level 3 まではオフ |

```text
あなたは SRE Agent Lab の一次調査担当です。
読み取り専用で証拠を収集し、事実と仮説を分けてください。
変更が必要な場合は変更案を作成しますが、実行しないでください。
変更案の妥当性確認は srelab-change-reviewer に引き継いでください。
```

3. **Tools** は調査に必要な読み取り専用ツールに限定します。
4. **Create** を選択します。

### 3. 変更レビュー用サブエージェントを作成する

1. もう一度 **+ Create subagent** を選択します。
2. 次を設定します。

   | 項目 | 値 |
   |---|---|
   | Subagent name | `srelab-change-reviewer` |
   | Instructions | 下記のレビュー用指示 |
   | Handoff instructions | `調査担当が修復または構成変更を提案したときに引き継ぐ` |
   | Enable Skills | オフ |
   | Give access to knowledge base | Level 3 まではオフ |

```text
あなたは変更レビュー担当です。
提案された操作について、対象の完全なリソース ID、変更前後の差分、
影響範囲、必要最小権限、ロールバック、復旧確認条件を検査してください。
情報が不足していれば承認せず、追加確認事項を返してください。
変更操作は実行しないでください。
```

3. 書き込みツールは割り当てず、**Create** を選択します。
4. `srelab-triage-agent` を編集し、**Handoff subagents** に `srelab-change-reviewer` を追加します。

### 4. Playground で役割分担をテストする

1. Agent Canvas の **Test playground** を開きます。
2. `srelab-triage-agent` を選び、次を入力します。

```text
vm-01 の CPU アラートを調査してください。
証拠が不足する場合は不足を明示し、変更案を作る場合は変更レビュー担当へ引き継いでください。
```

3. 次を確認します。
   - `srelab-incident-triage` の手順に沿った出力になっている。
   - 調査担当が変更を実行していない。
   - 変更案がある場合に `srelab-change-reviewer` へ引き継がれる。
   - レビュー担当が証拠不足の案を承認しない。

### 5. 対応計画のルーティング先を変更する

1. Level 1 で作成した `srelab-alerts-review` を編集します。
2. **応答エージェント**を `srelab-triage-agent` に変更します。
3. モードが **Review** のままであることを確認して保存します。
4. [Level 1 の CPU 高騰](#2-cpu-高騰を発生させる)をもう一度実行し、インシデントが調査用サブエージェントへルーティングされることを確認します。

### Level 2 の合格条件

- [ ] 調査スキルが作成され、テストで使用された。
- [ ] 調査用と変更レビュー用の 2 サブエージェントが存在する。
- [ ] 調査担当からレビュー担当への引き継ぎを確認した。
- [ ] 書き込みツールを持たないレビュー担当が変更を実行していない。
- [ ] 対応計画が調査用サブエージェントへルーティングされる。

## Level 3: ナレッジベースを整備する

### ゴール

ラボ固有の構成と運用ルールをナレッジベースへ登録し、新しい会話でも文書を出典として再利用できる状態を作ります。

### 1. `/learn` が作成したナレッジを確認する

1. SRE Agent ポータルで **Builder** → **Knowledge settings** を開きます。ポータルによっては **Knowledge base** または **Knowledge Sources** と表示されます。
2. `/learn` の結果に記載された `overview.md`、`architecture.md`、`logs.md`、`debugging.md`、`team.md` が存在することを確認します。
3. 各文書の状態が **Indexed** になるまで待ちます。`Pending` の場合は少し待って **Refresh** を選択します。
4. 文書を開き、現在のラボ構成、確認時刻、検証済みの事実、不足事項が `/learn` の結果と一致することを確認します。

これらの文書が作成されていない場合だけ、代替としてこのリポジトリの
[`docs/knowledge/sre-lab-operating-baseline.md`](knowledge/sre-lab-operating-baseline.md) の **最終確認日** を実施日に更新し、**Add file** からアップロードします。

実際の調査結果を記入した Runbook も必要に応じて追加できます。空のテンプレートや未確認の推測はナレッジに登録しないでください。

### 2. サブエージェントへナレッジ利用を許可する

1. Agent Canvas で `srelab-triage-agent` を編集します。
2. **Give access to knowledge base** をオンにします。
3. `srelab-change-reviewer` も同様にオンにします。
4. 保存します。

### 3. 新しいチャットで検索を検証する

過去の会話コンテキストに依存しないことを確認するため、必ず新しいチャットを作成します。

```text
SRE Agent Lab で IIS 停止が疑われる場合の、最初の復旧操作と禁止事項を説明してください。
ナレッジベースを検索し、使用した文書名を Sources として示してください。
文書にない情報は推測で補わず、未記載としてください。
```

期待する回答:

- 最初に Chaos 実験の状態を確認し、実験所有の停止なら実験停止を優先する。
- NSG、Gateway、VM サイズなど無関係な構成を同時に変更しない。
- `/learn` が作成した `debugging.md` など、回答の根拠となる文書が出典に表示される。
  代替文書をアップロードした場合は `sre-lab-operating-baseline.md` が表示される。

続けて、文書にない情報を尋ねます。

```text
このラボの本番環境の SLA とオンコール担当者名を教えてください。
ナレッジベースに根拠がなければ、推測せず不足情報として回答してください。
```

本番 SLA や担当者名を創作せず、情報不足として扱えば成功です。

### 4. 調査結果を Runbook として追加する

Level 1 または Level 2 の調査スレッドで、次を入力します。

```text
この調査で確認できた事実だけを使い、原因、診断手順、緩和策、
エスカレーション条件、復旧確認条件を含む Runbook を作成してください。
推測と未確認事項は明示し、Knowledge settings に
srelab-cpu-investigation-runbook.md として保存してください。
```

保存後、**Knowledge settings** で **Indexed** を確認し、新しいチャットから検索できることを確認します。

### 5. 更新と廃止のルールを決める

- 文書には対象環境、所有者、確認日、有効期限を記載する。
- 同名ファイルを再アップロードして更新し、古い手順を併存させない。
- 障害対応後に Runbook の事実と手順をレビューする。
- 削除したリソースや廃止した手順の文書はナレッジベースから削除する。
- 回答に出典が表示されることを定期的にテストする。

### Level 3 の合格条件

- [ ] `/learn` が作成した文書、または代替の初期ナレッジ文書が **Indexed** である。
- [ ] 2 つのサブエージェントがナレッジを利用できる。
- [ ] 新しいチャットで登録文書が Sources に表示される。
- [ ] 文書にない SLA や担当者名を創作しない。
- [ ] 実際の調査結果から作成した Runbook を再検索できる。

## ハンズオン終了時の確認

| 確認項目 | 完了 |
|---|---|
| 対応計画のルーティング先、重大度、Review モードを記録した | [ ] |
| サブエージェント、スキル、ツール、引き継ぎ関係を記録した | [ ] |
| ナレッジ文書の所有者と更新日を記録した | [ ] |
| デモ用の定期タスクと不要な対応計画を無効化した | [ ] |
| 実行中の Chaos 実験がないことを確認した | [ ] |
| 必要な調査記録を保存した | [ ] |

ラボを終了する場合は、[README の削除手順](../README.md#監視とコストの注意)に従います。VM の停止だけでは Application Gateway、NAT Gateway、Public IP、ディスクなどの課金は止まりません。

## 公式ドキュメント

- [Create an incident response plan](https://learn.microsoft.com/azure/sre-agent/response-plan)
- [Create a subagent](https://learn.microsoft.com/azure/sre-agent/create-subagent)
- [Create a skill](https://learn.microsoft.com/azure/sre-agent/create-skill)
- [Upload knowledge documents](https://learn.microsoft.com/azure/sre-agent/tutorial-upload-knowledge-document)
- [Agent playground](https://learn.microsoft.com/azure/sre-agent/agent-playground)
- [Tool access policies](https://learn.microsoft.com/azure/sre-agent/tool-access-policies)
