# ses-inbound module

SES 受信パイプライン全部入り module。Route53 zone / SES domain identity / DKIM / 受信用 MX / S3 archive / SNS → Lambda processor / SQS DLQ / CloudWatch アラーム / IP filter / optional killswitch を一括構築する。

## 使い方

```hcl
provider "aws" {
  region = "ap-northeast-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "ses_inbound" {
  source = "../../modules/ses-inbound"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name   = "ses-inbound-v3"
  region = "ap-northeast-1"
  domain = "example.com"

  allowed_recipients = ["inbox@example.com"]
  allow_list_domains = ["gmail.com"]

  enable_killswitch               = true
  killswitch_received_threshold   = 50   # 5 分間に 50 通超えたら遮断
  killswitch_invocation_threshold = 50
}
```

## 入力

| 変数 | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `name` | ✓ | | リソース名 prefix |
| `region` | ✓ | | SES 受信リージョン |
| `domain` | ✓ | | 受信対象ドメイン |
| `allowed_recipients` | | `[]` | 列挙アドレスのみ受信。空なら `[domain]` (catchall) |
| `allow_list_domains` | | `[]` | Lambda env var、sender ドメイン allow list |
| `log_retention_days` | | `14` | CW Log Group の retention |
| `ip_block_list` | | `{}` | SES Receipt Filter (Block) の CIDR |
| `ip_allow_list` | | `{}` | SES Receipt Filter (Allow) の CIDR |
| `manage_registered_domain` | | `true` | Route53 Domains の name_server 同期 |
| `enable_killswitch` | | `false` | 受信レート閾値超えで active rule set を解除する Lambda + アラームを作る |
| `killswitch_received_threshold` | | `100` | SES Received Sum の閾値 |
| `killswitch_invocation_threshold` | | `100` | Lambda Invocations Sum の閾値 |
| `killswitch_period_seconds` | | `300` | アラーム評価ウィンドウ (秒) |
| `archive_lifecycle_ia_days` | | `30` | S3 → STANDARD_IA 遷移日数 |
| `archive_lifecycle_expiration_days` | | `365` | S3 削除日数 |
| `slack_team_id` | | `""` | AWS Chatbot 連携済の Slack Workspace ID (Team ID)。`slack_channel_id` と両方指定で Chatbot 経由の Slack 通知を有効化 |
| `slack_channel_id` | | `""` | 通知先 Slack Channel ID。両方指定で alerts SNS → Chatbot → Slack の経路を作る |

## 出力

`hosted_zone_id` / `hosted_zone_name_servers` / `rule_set_name` / `archive_bucket` / `sns_mail_topic_arn` / `sns_alerts_topic_arn` / `sns_killswitch_topic_arn` / `processor_function_name` / `processor_log_group` / `killswitch_function_name` / `killswitch_log_group` / `chatbot_configuration_arn` / `dlq_url` / `effective_recipients` / `recovery_command`

## アーキテクチャ

```
       MX → inbound-smtp.<region>.amazonaws.com
                                 │
                                 ▼
                    SES Receipt Rule Set (singleton)
                                 │
                    +────────────+
                    │
        recipients matched (= var.allowed_recipients or [domain] catchall)
                    │
            ┌───────┴───────┐
            ▼               ▼
        S3 archive      SNS topic (mail)
        (lifecycle)         │
                            ▼
                    Lambda processor
                    (DMARC PASS + spam/virus + From allow list)
                            │
                    ┌───────┴────┐
                    ▼            ▼
                CW Logs       SQS DLQ (failure)


  enable_killswitch=true のとき追加:

        AWS/SES.Received           AWS/Lambda.Invocations
              │                              │
              └──────┬──────────────┬────────┘
                     ▼              ▼
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
              = active rule set 解除 = 以降の全 inbound メール SMTP 550 reject
```

## killswitch の挙動

- 受信レート / Lambda 起動レートが閾値超え → SNS killswitch topic に publish
- Lambda killswitch が `ses:SetActiveReceiptRuleSet` を引数なしで呼び、active rule set を解除
- 以降の inbound メールは「マッチする rule なし」状態で **SMTP 550 reject、課金されない**
- 復旧は手動: `aws ses set-active-receipt-rule-set --rule-set-name <name>` または `terraform apply` で `aws_ses_active_receipt_rule_set` を再作成
- alerts SNS topic にも同時 publish されるので人間にも通知が飛ぶ (email/Slack subscriber 用)

## Lambda ソースの場所

- `lambda/processor/handler.py` — メールフィルタ判定 (DMARC PASS + sender ドメイン allow list + spam/virus)
- `lambda/killswitch/handler.py` — `ses.set_active_receipt_rule_set()` 呼ぶだけのシンプルな関数

## 通知フロー (slack_team_id と slack_channel_id を指定したとき)

```
CloudWatch アラーム → alerts SNS topic → AWS Chatbot → Slack channel
```

- AWS Chatbot がアラームの標準フォーマット (アラーム名 / State / Reason / Description) を Slack に投稿
- **復旧コマンドはアラームの `alarm_description` に埋め込まれている** ので Slack メッセージ内に表示される
- 復旧は人間が表示されたコマンドをコピペして CLI で実行 (auto-recover なし)

AWS Chatbot は us-east-2 専用 API なので `aws.us_east_2` provider alias が必要。caller 側で:

```hcl
provider "aws" {
  alias  = "us_east_2"
  region = "us-east-2"
}

module "ses_inbound" {
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    aws.us_east_2 = aws.us_east_2
  }
  ...
}
```

事前準備: Slack workspace を AWS Chatbot console から OAuth 認証 (one-time、ブラウザ手動)。terraform で行うのは Slack channel との紐付けと SNS topic の購読設定のみ。

両方とも `archive_file` data source で `${path.module}/.build/<name>.zip` にビルドされる。
