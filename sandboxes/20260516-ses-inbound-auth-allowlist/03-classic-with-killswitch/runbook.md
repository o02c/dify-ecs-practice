# 03-classic-with-killswitch

02 と同じ strict allowlist + DMARC PASS + sender ドメイン allow list の構成を、本 sandbox 内に新規作成した `modules/ses-inbound` module 経由で構築する。
さらに、受信レート / Lambda 起動レートが閾値超えしたら自動で SES の active rule set を解除する **killswitch** を追加。

## 概要

```
       MX → SES inbound endpoint
                 │
                 ▼
         Receipt Rule Set
                 │
                 ▼
        Rule (recipients=列挙)
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
    S3 archive       SNS mail topic → Lambda processor → CW Logs
                                            │
                                            ▼
                                       SQS DLQ (失敗時)


  killswitch (受信 / 起動レート閾値超え時に発火):

   AWS/SES.Received  ──┐
   AWS/Lambda.Invocations ──┤
                            ▼
                CloudWatch アラーム (閾値超え)
                            │
                            ▼
                  SNS topic (killswitch)
                            │
                            ▼
              Lambda killswitch
                            │
                            ▼
        ses:SetActiveReceiptRuleSet (引数なし)
              = active rule set 解除 = 以降 SMTP 550 reject
```

## 前提

- `AWS_PROFILE=terraform`
- 既存 active receipt rule set がないこと
- 02 が apply 済の場合は state 移行 (`terraform state rm` + `terraform import`) で DNS 伝播待ちを省略可能 (本 sandbox の手順参照)

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

主要な変数 (`variables.tf`):
- `allowed_recipients` (default `["inbox@example.com"]`)
- `allow_list_domains` (default `["gmail.com"]`)
- `killswitch_received_threshold` (default 50 = 5 分間に 50 通受信したら遮断)
- `killswitch_invocation_threshold` (default 50)

### 2. (任意) 02 からの state 移行で DNS 伝播待ちを回避

02 が apply 済の場合、共有リソース (Hosted Zone / SES Identity / DKIM / DNS records) を 02 から state rm して 03-03 の module 配下に import する。詳細手順は 20260512 の同様パターン参照。

注意: import 先のアドレスは module-wrapped なので `module.ses_inbound.aws_route53_zone.main` 等になる。

### 3. DNS 伝播待ち + SES verification (新規 apply 時)

```sh
dig +short MX example.com @8.8.8.8
aws sesv2 get-email-identity --email-identity example.com --region ap-northeast-1 \
  --query '{V:VerifiedForSendingStatus,D:DkimAttributes.Status}'
```

### 4. 通常動作確認 (gmail 送信)

`inbox@example.com` 宛 → `ACCEPTED` ログ。02 と同じ挙動。

### 5. killswitch 動作確認

実機で 50 通/5 分のフラッドを試すのは難しいので、CloudWatch アラームを **手動で `ALARM` 状態に遷移** させて killswitch Lambda の発火を確認する:

```sh
# (1) 現状の active rule set を確認
aws ses describe-active-receipt-rule-set --region ap-northeast-1 --query 'Metadata.Name'

# (2) アラームを手動で ALARM 状態にして killswitch を起動
aws cloudwatch set-alarm-state --region ap-northeast-1 \
  --alarm-name ses-inbound-v3-received-rate \
  --state-value ALARM \
  --state-reason "manual test: simulate flood"

# (3) killswitch Lambda のログ確認
aws logs tail /aws/lambda/ses-inbound-v3-killswitch --region ap-northeast-1 --since 1m

# (4) active rule set が解除されたことを確認 (Metadata.Name が None)
aws ses describe-active-receipt-rule-set --region ap-northeast-1
```

期待ログ:
```
KILLSWITCH FIRED: SES active receipt rule set cleared. ...
```

### 6. 復旧 (rule set を再有効化)

```sh
aws ses set-active-receipt-rule-set --region ap-northeast-1 \
  --rule-set-name ses-inbound-v3-ruleset
```

または terraform 上で `aws_ses_active_receipt_rule_set` を再作成:

```sh
terraform apply -replace=module.ses_inbound.aws_ses_active_receipt_rule_set.main
```

### 7. (任意) AWS Chatbot 経由で Slack 通知を受ける

事前準備:
1. AWS Chatbot console で Slack workspace を OAuth 認証 (one-time、ブラウザ手動)。本アカウントは workspace `DEV` (TeamId `T0764FKRQLV`) が連携済
2. 通知先 Slack channel の Channel ID を取得 (Slack で channel 開いて About → 最下部)

`terraform.tfvars` (git 管理外) に:

```hcl
slack_team_id    = "T0764FKRQLV"
slack_channel_id = "C0XXXXXXXXX"
```

apply 後、CloudWatch アラーム → alerts SNS → AWS Chatbot → Slack channel に投稿される。**killswitch アラームの `alarm_description` に復旧コマンドが埋め込まれている** ので Slack の通知メッセージ内にコマンドが表示される。コピペで CLI 実行すれば復旧。

動作確認:

```sh
aws cloudwatch set-alarm-state --region ap-northeast-1 \
  --alarm-name ses-inbound-v3-received-rate \
  --state-value ALARM --state-reason "slack notify test"
```

Slack channel に投稿されるはず。失敗時は Chatbot console の `Configuration history` か CloudWatch Logs `/aws/chatbot/<config-name>` で配信ログを確認。

注意: AWS Chatbot は **us-east-2 専用 API**。本 sandbox は providers.tf に `aws.us_east_2` alias を追加してある。

### 8. destroy

```sh
terraform destroy
```

CloudWatch Log Group は module 内で terraform 管理しているので一緒に消える。

## 結果

2026-05-18 検証。02 sandbox から共有リソース (Hosted Zone / SES Identity / DKIM / DNS records 計 9 件) を `terraform state rm` + `terraform import` で 03-03 の module 配下に引き継ぎ、DNS 伝播待ちゼロで apply 成功。31 新規リソース作成。

### killswitch 発火テスト

```sh
aws cloudwatch set-alarm-state --region ap-northeast-1 \
  --alarm-name ses-inbound-v3-received-rate \
  --state-value ALARM --state-reason "manual test"
```

killswitch Lambda ログ:
```
Killswitch invoked: { "Records": [{ "EventSource": "aws:sns", ... "Trigger": {"Threshold": 50.0, ...} }] }
KILLSWITCH FIRED: SES active receipt rule set cleared. All inbound mail will be SMTP-rejected until manually restored.
Duration: 274.65 ms
```

発火前後の `aws ses describe-active-receipt-rule-set`:
- 発火前: `ses-inbound-v3-ruleset`
- 発火後: **空 (active rule set なし)** → 以降の inbound メールは全て SMTP 550 で reject、課金されない

### 復旧テスト

```sh
aws ses set-active-receipt-rule-set --region ap-northeast-1 \
  --rule-set-name ses-inbound-v3-ruleset
aws cloudwatch set-alarm-state --region ap-northeast-1 \
  --alarm-name ses-inbound-v3-received-rate --state-value OK
```

active rule set が `ses-inbound-v3-ruleset` に戻ったことを確認、通常受信再開。

## 考察

### 良い点
- **module 化で 03-03 の terraform は実質 1 ブロック** (`module "ses_inbound" { ... }`) になった。同じ構成を別 sandbox で再利用するときの労力が劇的に減る
- killswitch は **CloudWatch アラーム → SNS → Lambda → `set_active_receipt_rule_set()`** の素直な連鎖で実装できる
- アラーム発火から Lambda 実行まで実測 1-2 分程度。SES Received メトリクスの解像度 1 分なので、フラッド検知から遮断まで合計数分の遅延に収まる
- 復旧は手動コマンド or `terraform apply -replace` で 30 秒程度。誤発火しても復旧コスト低

### 悪い点 / 制約
- **アカウント × region singleton**: SES Receipt Rule Set はアカウント singleton なので、killswitch が動くと **同 region の他の SES 受信もすべて止まる**。複数 sandbox / 本番並行運用時は要注意
- **検知ラグ中の被害**: アラーム解像度 1 分 + 評価ウィンドウ 5 分 + SNS / Lambda 遅延で、フラッド開始から遮断まで最大 7-8 分の差。その間の受信は課金対象
- **誤発火リスク**: 閾値設定が低すぎると正規メールの集中で発火する。平常時を観測して安全側に倒す設計が必要 (本検証は sandbox 用に 50/5min と低めに設定)
- **状態管理**: terraform 側は `aws_ses_active_receipt_rule_set` を有効化のまま管理しているので、killswitch 発火後に手動復旧しないと next `terraform apply` で再有効化されてしまう (= killswitch の効果が消える)。本番運用なら kill 状態を SSM Parameter / Secrets に記録して terraform 側で参照する設計を要検討

### 次にやるなら
- **自動復旧** (低 traffic 確認後に再有効化する別アラーム + Lambda) を実装、誤発火耐性を上げる
- アラーム閾値を **CloudWatch Anomaly Detection** に切り替えて、平常時を機械学習で baseline 化
- **Mail Manager** 版の比較 (Ingress endpoint のスケーリング / Traffic Policy 側のレート制限と比較)
- 別 sandbox で同じ module を使いたい場合は `sandboxes/20260516-ses-inbound-auth-allowlist/modules/ses-inbound/` をその sandbox 配下にコピーして参照する

## メモ

- module の最初のドラフトでは module-wrapped アドレスの import で zsh の `read -ra` が使えず DKIM token 配列が空になる罠を踏んだ。次回は `for-each` で個別に import する方が確実
- `aws cloudwatch set-alarm-state` で **手動 ALARM 遷移** すると本物の SNS publish が起きる。killswitch の挙動確認に有用、本物のフラッドを起こす必要なし

## メモ

- module 設計は `modules/ses-inbound/README.md` 参照
- killswitch アラームの閾値は sandbox 用に低く (50/5min) してある。本番なら平常時を観測してから設定
- 復旧の自動化は今回未実装 (誤発火時の影響が大きいため手動推奨)。`set-alarm-state OK` で低 traffic 検出 → 別アラーム → 別 Lambda で復旧、というパターンは可能
