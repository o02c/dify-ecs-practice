# ses-inbound module (S3-trigger 版、最大 40 MB 対応)

SES 受信パイプライン全部入り module。**S3 ObjectCreated event → SNS → Lambda** 経路で構築されているので、SNS publish action の 150KB 上限から解放され **40MB までのメールを処理できる**。長文 reply chain / HTML / インライン画像付き / 添付ファイル付きが想定される LLM 処理パイプライン向け。

Route53 zone / SES domain identity / DKIM / 受信用 MX / S3 archive / S3 event → SNS → Lambda processor / SQS DLQ / CloudWatch アラーム / IP filter / optional killswitch / optional Chatbot 連携を一括構築する。

軽量処理 (≤ 150KB、SNS content 直接) で済む場合は `sandboxes/20260516-ses-inbound-auth-allowlist/modules/ses-inbound/` の SNS-trigger 版を参照する。

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
                            ▼
        Rule (recipients matched、s3_action のみ)
                            │
                            ▼
                    S3 archive bucket (40MB)
                            │ s3:ObjectCreated event
                            ▼
                    SNS topic (mail)
                            │
                            ▼
                  Lambda processor
                  - S3 GetObject で raw MIME を読む
                  - Authentication-Results ヘッダから SPF/DKIM/DMARC を抽出
                  - X-SES-Spam-Verdict / X-SES-Virus-Verdict ヘッダで scan 判定
                  - From ヘッダドメインで allow list 判定
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

- `lambda/processor/handler.py` — S3 イベントを受けて S3 GetObject で raw MIME を読み、ヘッダから verdict 抽出 → 多段判定
- `lambda/killswitch/handler.py` — `ses.set_active_receipt_rule_set()` 呼ぶだけのシンプルな関数

## SES が S3 に追加するヘッダ (verdict 抽出元)

| ヘッダ | 内容 |
|---|---|
| `Authentication-Results` | RFC 8601 形式、`spf=pass; dkim=pass; dmarc=pass` 等 |
| `X-SES-Spam-Verdict` | `PASS` / `FAIL` / `GRAY` / `PROCESSING_FAILED` |
| `X-SES-Virus-Verdict` | 同上 |
| `X-SES-DKIM-Signature` | DKIM 署名そのもの |
| `X-SES-Receipt` | receipt metadata |

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

## 既知の制約 / 注意

- Lambda の処理速度: S3 GetObject 1 回追加するので latency は SNS-content 版より高い (数十 ms オーダ、許容範囲)
- メール本体は S3 にしか存在しない: Lambda 経路の前段で消えると本体ロスト (SES が S3 PutObject 失敗 = SES 側で配信失敗扱い、送信者にバウンス)
- `Authentication-Results` ヘッダの parse 精度: 簡易正規表現。multi-DKIM や `policy.dmarc=...` のような注釈付き値があってもまず動くが、エッジケースは正規表現を見直すこと
- killswitch / Chatbot 連携は SNS-trigger 版と同じ仕組み (alarms → SNS → Lambda / Chatbot)
