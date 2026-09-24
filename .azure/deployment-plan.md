# 実装計画

状態: Ready for Validation（実リソースへのデプロイ・障害注入は実施しない）

方式: スタンドアロン Bicep + Azure CLI / Bash。今回の作業範囲はコード作成とローカル検証。

## フェーズ

| フェーズ | 対象 | 方針 |
|---|---|---|
| 1 | main.bicep、main.parameters.json、modules/network.bicep、modules/vm.bicep、modules/appgw.bicep、scripts/setup-iis.ps1 | Windows VM 配列、IIS、App Gateway、任意 RDP、共通タグ、明示的な NAT 外向き通信。既存 monitoring/chaos の Windows 化と複数 VM の接続も含む |
| 2 | modules/chaos.bicep、modules/monitoring.bicep、modules/dashboard.bicep、modules/activity-log.bicep、modules/sre-agent.bicep、main.bicep | 公式フォールト、VM スコープ RBAC、NSG スコープ RBAC、Windows DCR、VM/App GW アラート、Workbook、独立したサブスクリプション診断設定 |
| 3 | scripts/*.sh、README.md、docs/demo-scenario.md、docs/runbook-template.md、docs/sre-agent-setup.md、docs/azure-portal-manual-setup.md、docs/scheduled-tasks.md、docs/live-report.md、.gitignore、tests/ | 入力秘匿、出力からのリソース解決、start/status/stop、障害と復旧の対、限定されたクリーンアップ、日本語手順、スクリプトと生成 ARM の検証 |

各フェーズ終了時に `az bicep build --file main.bicep` を実行する。
既存 Linux VM のインプレース OS 変更は行わず、新規デモ環境へのデプロイを前提とする。

## 設計上の注意

- 指定 Windows Server イメージの OS ディスクは縮小不可。P4/E4 の 32 GiB を強制せず、イメージ最小容量の Standard_LRS とキャッシュ無効で IO 制限を観察する。VM はストレージ制限の観測に適した Standard_D2s_v5 を推奨する。
- VM に公開 IP を付けない既定構成では、AMA/Chaos Agent 用に NAT Gateway + 外向き専用 Public IP を追加する。受信公開は App Gateway のみ。
- App Gateway の cookie affinity 無効化は厳密な交互応答を保証しない。複数回更新して両 VM が観測できることを確認する。
- App Gateway 診断設定は要件の「AccessLog / PerformanceLog / FirewallLog は不要」に従い AllMetrics を Log Analytics に送る。Workbook のメトリックは Azure Monitor を直接参照する。
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
- Workbook の自動更新間隔は保存できないという公式仕様に従い、開くたびに 1 分の自動更新を選択する手順を記載する。

## All validation checks pass

- [ ] Core Validation (CLI, auth, build, validate, what-if)
  - [x] Azure CLI と Bicep ビルド（main / Activity Log）
  - [ ] 対象サブスクリプションの認証・ARM validate・what-if: 今回は対象サブスクリプションと実値の入力を伴う Azure 検証を実施しない
- [x] Linting: main / Activity Log の `az bicep lint` 成功
- [ ] Azure Policy Validation: 対象サブスクリプションでデプロイ前に実施

ローカル検証は完了。上記クラウド検証とデプロイ後のブラウザ、バックエンド正常性、実験の復旧確認は未実施。
未実施項目があるため、計画をクラウド検証済み（Validated）とは扱わない。
