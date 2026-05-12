# 02-multi-recipient-archive-dlq

01 の構成を発展させ、receipt rule をアドレスごとに分岐 + S3 アーカイブ + DLQ + アラームを追加した堅牢化版。

## 概要

```
                                  +-- Rule "archive-all"   recipients=[o2c.click]      → S3 Bucket (全メール永続化)
                                  |
SES Receipt Rule Set (順序付き) --+-- Rule "process-inbox"  recipients=[inbox@o2c.click] → SNS Topic → Lambda → CW Logs
                                  |                                                              └→ (失敗時) SQS DLQ
                                  |
                                  +-- Rule "drop-noreply"   recipients=[noreply@o2c.click] → Bounce + Stop Rule Set
```

- 全メールは Rule 1 で必ず S3 にアーカイブされる (`inbox/<messageId>`)
- `inbox@o2c.click` 宛は Rule 2 で SNS → Lambda 処理 (Rule 1 とアクションが両方走る)
- `noreply@o2c.click` 宛は Rule 1 でアーカイブされた後、Rule 3 でバウンスして停止
- Lambda が 3 回失敗したら SNS subscription redrive で SQS DLQ に退避
- CloudWatch アラームで `Lambda Errors` / `DLQ depth` / `SNS NumberOfNotificationsFailed` を監視 (alerts SNS topic に通知)

## 前提

- 01 から共有リソース (Route53 zone / SES Identity / DNS records) を state 移行済みであること
  - 01 がまだ動いていれば下記の「01 からの state 移行手順」を先に実施する
- `AWS_PROFILE=terraform` が設定済み

## 01 からの state 移行手順

```sh
# A. 02 を init
cd 02-multi-recipient-archive-dlq/terraform
terraform init

# B. 01 から非共有リソースを destroy (state からも消える)
cd ../../01-sns-to-lambda/terraform
terraform destroy -auto-approve \
  -target=aws_ses_receipt_rule.main \
  -target=aws_ses_active_receipt_rule_set.main \
  -target=aws_ses_receipt_rule_set.main \
  -target=aws_sns_topic_subscription.lambda \
  -target=aws_lambda_permission.sns_invoke \
  -target=aws_lambda_function.processor \
  -target=aws_iam_role_policy_attachment.lambda_basic \
  -target=aws_iam_role.lambda \
  -target=aws_sns_topic_policy.mail \
  -target=aws_sns_topic.mail

# C. 01 から共有リソースを state rm (AWS には残る)
terraform state rm \
  aws_route53_zone.main \
  aws_route53domains_registered_domain.main \
  aws_ses_domain_identity.main \
  aws_ses_domain_dkim.main \
  aws_route53_record.amazonses_verification \
  'aws_route53_record.dkim[0]' \
  'aws_route53_record.dkim[1]' \
  'aws_route53_record.dkim[2]' \
  aws_route53_record.mx

# D. 02 に import
cd ../../02-multi-recipient-archive-dlq/terraform

ZONE_ID=$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`o2c.click.`].Id' --output text | sed 's|/hostedzone/||')

terraform import aws_route53_zone.main "$ZONE_ID"
terraform import aws_route53domains_registered_domain.main o2c.click
terraform import aws_ses_domain_identity.main o2c.click
terraform import aws_ses_domain_dkim.main o2c.click
terraform import aws_route53_record.amazonses_verification "${ZONE_ID}__amazonses.o2c.click_TXT"
terraform import aws_route53_record.mx "${ZONE_ID}_o2c.click_MX"

# DKIM tokens は SES から取得して順番に import
TOKENS=($(aws sesv2 get-email-identity --email-identity o2c.click --region ap-northeast-1 \
  --query 'DkimAttributes.Tokens' --output text))
for i in 0 1 2; do
  terraform import "aws_route53_record.dkim[$i]" \
    "${ZONE_ID}_${TOKENS[$i]}._domainkey.o2c.click_CNAME"
done

# E. plan で diff ゼロを確認
terraform plan

# F. apply で新規リソースを作成
terraform apply
```

## 手順 (新規 apply の場合)

01 からの移行ではなくクリーンに作る場合は通常通り:

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

## 検証

terraform output `test_commands` で各 recipient へのテスト送信コマンドが出る。

期待動作:
| 宛先              | S3 archive | Lambda 起動 | バウンス |
| ----------------- | ---------- | ----------- | -------- |
| inbox@o2c.click   | YES        | YES         | NO       |
| random@o2c.click  | YES        | NO          | NO       |
| noreply@o2c.click | YES        | NO          | YES      |

DLQ 動作確認は Lambda コードを一時的に `raise Exception` するように差し替えて test 送信 → 数分後に DLQ に payload が溜まるはず。

## destroy

```sh
terraform destroy
```

注意: S3 バケットは `force_destroy=true` にしてあるのでメール込みで削除される。アーカイブを残したい場合は事前に別バケットへコピー。

## 結果

2026-05-12 検証。01 から state 移行 + 新規リソース apply で動作確認。

### state 移行
- 01 の非共有リソース 10 件を `terraform destroy -target` で破棄
- 共有 9 リソース (Route53 zone / SES identity / DNS records) を `terraform state rm` → 02 で `terraform import`
- **DNS 伝播待ち再発なし**: Hosted Zone と SES Identity をそのまま引き継いだので再認証ゼロ秒
- 注意: DKIM CNAME 3 件の import で count 順序とトークン順序を厳密に揃える必要あり (`aws_ses_domain_dkim.main.dkim_tokens` の順序を `terraform state show` で確認してから import)。誤って同じトークンを別 index に import すると plan が `must be replaced` を出す

### Receipt Rule 分岐 (3 アドレスへ送信して挙動比較)

| 宛先              | S3 archive | Lambda 起動 | バウンス reply | 観測結果 |
| ----------------- | ---------- | ----------- | -------------- | -------- |
| inbox@o2c.click   | YES        | YES         | NO             | ✓        |
| random@o2c.click  | YES        | NO          | NO             | ✓        |
| noreply@o2c.click | YES        | NO          | YES (550 5.1.1) | ✓        |

S3 アーカイブには 4 オブジェクトが入った (3 つのテスト + noreply テストが返したバウンス reply が `test@o2c.click` に届いて再 archive)。
Lambda ログには `inbox test v2` のみ。DLQ 残量 0。

## 考察

### 良い点
- **recipient ベース分岐は素直**: `recipients` で full address や domain を指定するだけで Rule が独立。1 メールが複数 Rule にマッチした場合は順序通り全部実行されるので「全件アーカイブ + 一部に特殊処理」が自然に書ける
- **DKIM token と Hosted Zone を引き継いだので DNS 伝播待ちゼロ**: state 移行のメリットそのまま。同じドメインで別 approach を試す際の鉄板パターン
- **DLQ + 3 アラームでロスト経路を塞いだ**: Lambda 失敗、SNS 配信失敗、DLQ 滞留の 3 経路を CloudWatch アラームで監視

### 悪い点 / 制約
- **state 移行手順がトリッキー**: DKIM CNAME のような count リソースは順序込みで import しないと plan が壊れる。導入時に時間を食った
- **バウンス reply の再受信ループ**: 同一ドメイン内のテストだと bounce action の reply が再度自ドメインに着信して archive される。実運用では `From` フィルタなり別ドメインなりで切り分けが要る
- **drop-noreply の `stop_action` は最後の rule では意味がない**: 「全 archive を抑止して noreply は drop だけしたい」要件なら順序を入れ替えて drop を 1 番目に置く必要がある

### 次にやるなら
- Lambda コードを一時的に `raise Exception` にして 3 回リトライ後 DLQ に payload が落ちるかを実測
- `noreply` の bounce action 受け取り側 (test@o2c.click) を SES の自動応答ではなく外部 Gmail にすると、より現実的な挙動になる
- 150KB 超のメール (添付付き) を archive 経由で受けて、SNS publish 側は当然失敗するが S3 にはちゃんと残る、を実証
