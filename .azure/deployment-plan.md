# 実装計画

## 既存 SRE Agent を使用する参考デプロイ

状態: Ready for Validation（方針承認済み）。実リソースへのデプロイは行わない。

- 通常の SRE Agent 同梱デプロイは既定のまま維持する。
- ラボ部分を `modules/lab.bicep` に分離し、既存 Agent 用の `existing-agent.bicep` と生成 ARM JSON から共通利用する。既存 Agent 用では SRE Agent とその専用リソース、利用者ロール割り当てを作成しない。
- 専用エントリーポイントは既存 Agent のリソース ID を受け取り、運用スクリプトで必要な出力を維持する。既存 Agent の設定や権限は変更しない。
- README の参考資料だけに専用の Deploy to Azure ボタンと、既存 Agent への管理対象 RG の追加、権限確認、削除時の注意を記載する。本流の設定手順は変更しない。
- Bicep ビルドとテンプレート回帰テストで、新規 Agent を作らない経路と従来経路の互換性を確認する。

- `main.bicep` と `existing-agent.bicep` のビルドと lint は成功。
- 共通ラボに移した ARM リソース定義、通常構成の入力パラメータ、利用者 RBAC が変更前の `azuredeploy.json` と一致することを比較確認。
- ローカル回帰テスト 44 件を確認。初回の新規テストで配列形式の読み取りを修正し、テンプレートテスト 14 件の再実行が成功。既存スクリプトテスト 1 件の Python 起動エラーは単独再実行で成功。
- `azure-validate` のワークフローを開始し、計画と Bicep 検証項目を確認。ローカル検証のみ実施し、クラウド検証を必要とする段階で停止。
- クラウドの ARM validate、what-if、デプロイは作業範囲外。実動作確認済みとは扱わない。

状態: Ready for Validation（実リソースへのデプロイ・障害注入は実施しない）

方式: スタンドアロン Bicep + Azure CLI / Bash。今回の作業範囲はコード作成とローカル検証。

## フェーズ

| フェーズ | 対象 | 方針 |
|---|---|---|
| 1 | main.bicep、main.parameters.json、modules/network.bicep、modules/vm.bicep、modules/appgw.bicep、scripts/setup-iis.ps1 | Windows VM 配列、IIS、App Gateway、任意 RDP、共通タグ、明示的な NAT 外向き通信。既存 monitoring/chaos の Windows 化と複数 VM の接続も含む |
| 2 | modules/chaos.bicep、modules/monitoring.bicep、modules/activity-log.bicep、modules/sre-agent.bicep、main.bicep | 公式フォールト、VM スコープ RBAC、NSG スコープ RBAC、Windows DCR、VM/App GW アラート、独立したサブスクリプション診断設定 |
| 3 | scripts/*.sh、README.md、docs/demo-scenario.md、docs/runbook-template.md、docs/sre-agent-setup.md、docs/azure-portal-manual-setup.md、.gitignore、tests/ | 入力秘匿、出力からのリソース解決、start/status/stop、障害と復旧の対、限定されたクリーンアップ、日本語手順、スクリプトと生成 ARM の検証 |

各フェーズ終了時に `az bicep build --file main.bicep` を実行する。
既存 Linux VM のインプレース OS 変更は行わず、新規デモ環境へのデプロイを前提とする。

## 設計上の注意

- 指定 Windows Server イメージの OS ディスクは縮小不可。P4/E4 の 32 GiB を強制せず、イメージ最小容量の Standard_LRS とキャッシュ無効で IO 制限を観察する。VM は 2 vCPU / 8 GiB を維持して費用を抑える Standard_B2ms を既定とし、デプロイ先で必要なディスク指標を確認する。
- VM に公開 IP を付けない既定構成では、AMA/Chaos Agent 用に NAT Gateway + 外向き専用 Public IP を追加する。受信公開は App Gateway のみ。
- App Gateway の cookie affinity 無効化は厳密な交互応答を保証しない。複数回更新して両 VM が観測できることを確認する。
- App Gateway 診断設定は要件の「AccessLog / PerformanceLog / FirewallLog は不要」に従い AllMetrics を Log Analytics に送る。
- ライブレポートは Azure Monitor ブックではなく SRE Agent のライブ レポート (プレビュー) 機能。ポータルでチャットから作成するため IaC 化せず、docs/sre-agent-setup.md に作成手順とプロンプトを記載する。
- NSG v1.0 フォールトは既存接続を即時切断しない。このため 502 まで遅延し得ることを明記する。
- tags をサポートする全リソースへ共通タグを適用する。子リソースや RBAC など tags 非対応の API は除外する。
- API は 2024 年以降の安定版を優先し、新しい安定版がないリソースは既存のサポート済みバージョンを維持する。
- 機能検証はローカル静的検証とデプロイ後の確認手順まで。Azure 上の実動作を未検証のまま成功扱いしない。

## 検証記録

- 変更前: `az bicep build --file main.bicep --outfile <temp>` 成功。
- フェーズ 1: `az bicep build --file main.bicep` 成功。
- フェーズ 2: `az bicep build --file main.bicep`、独立した Activity Log テンプレートのビルド成功。
- フェーズ 3: `az bicep build --file main.bicep` 成功。Bash 操作のモックテスト 26 件成功。
- OS ディスクにもタグ拡張リソースで共通タグを適用。生成 ARM の回帰テスト 9 件成功（計 35 件）。
- ライブレポートを SRE Agent の機能に修正: Workbook モジュールと出力を削除し、スクリプトの main デプロイ判定を `sreAgentPortalUrl` 出力に変更。DCR に Network Interface カウンターを追加。`az bicep build`、テンプレートテスト 9 件、スクリプトテスト 26 件成功。

## All validation checks pass

- [ ] Core Validation (CLI, auth, build, validate, what-if)
  - [x] Azure CLI と Bicep ビルド（main / Activity Log）
  - [ ] 対象サブスクリプションの認証・ARM validate・what-if: 今回は対象サブスクリプションと実値の入力を伴う Azure 検証を実施しない
- [x] Linting: main / Activity Log の `az bicep lint` 成功
- [ ] Azure Policy Validation: 対象サブスクリプションでデプロイ前に実施

ローカル検証は完了。上記クラウド検証とデプロイ後のブラウザ、バックエンド正常性、実験の復旧確認は未実施。
未実施項目があるため、計画をクラウド検証済み（Validated）とは扱わない。
