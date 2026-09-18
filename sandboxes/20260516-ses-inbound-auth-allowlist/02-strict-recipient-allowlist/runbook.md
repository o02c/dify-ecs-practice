# 02-strict-recipient-allowlist

01 と同じ DMARC PASS + sender ドメイン allow list の Lambda 判定はそのままに、SES Receipt Rule の `recipients` に **許可するアドレスだけを明示列挙** する構成。catchall を撤廃したことで、列挙外のアドレス宛のメールは SMTP 会話中に reject され、SES 受信課金が発生しない。

## 概要

```
Receipt Rule Set
  └─ Rule "process-allowed"  recipients=[allowed-list]
      ├─ S3 deliver (archive)        ← マッチした分だけ archive
      └─ SNS publish → Lambda        ← 同じく 3 段判定
                          │
                          ▼
                  ┌─────────────────────┐
                  │ DMARC PASS + 認証   │
                  │ spam/virus PASS     │
                  │ From ドメイン allow │
                  └─────────────────────┘
                          │
                          ▼
                  ACCEPTED → CW Logs
```

01 との差分:
- **`archive-all` (catchall) rule を削除**: `*@example.com` を網羅する rule なし
- **`recipients` に許可アドレスを明示列挙**: 例 `["inbox@example.com", "alerts@example.com"]`
- 列挙外のアドレス宛メールは SES SMTP 中 reject → 課金なし、CloudWatch `Received` メトリクスにも乗らない
- archive は許可アドレスにマッチしたメールのみ (S3 deliver action を同じ rule の 1 番目に置く)

## 前提

- `AWS_PROFILE=terraform`
- 既存 active receipt rule set がないこと
- `example.com` の Hosted Zone は前 sandbox の destroy で消えているので新規作成 (DNS 伝播待ち発生)

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

terraform variable `allowed_recipients` に列挙したいアドレスのリストを渡す。デフォルトは `["inbox@example.com"]` のみ。複数欲しいなら `terraform.tfvars` で:

```hcl
allowed_recipients = ["inbox@example.com", "alerts@example.com"]
```

### 2. DNS 伝播待ち + SES verification

```sh
dig +short MX example.com @8.8.8.8
aws sesv2 get-email-identity --email-identity example.com --region ap-northeast-1 \
  --query '{V:VerifiedForSendingStatus,D:DkimAttributes.Status}'
```

### 3. テスト (gmail から実機送信)

ユーザー依頼:
- 「Gmail から `inbox@example.com` 宛に送信」 → ACCEPTED 期待
- 「Gmail から `random@example.com` 宛に送信」 → **gmail 側で配信失敗の DSN が返るはず** (SES が SMTP RCPT TO 段階で 550 を返す)

### 4. 課金回避の検証

CloudWatch メトリクスで `Received` (Receipt Rule Set Metrics) が **inbox 宛のみカウント** されることを確認:

```sh
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START=$(date -u -v-30M +"%Y-%m-%dT%H:%M:%SZ")  # 30 分前 (macOS BSD date)
aws cloudwatch get-metric-statistics --region ap-northeast-1 \
  --namespace AWS/SES \
  --metric-name Received \
  --dimensions Name=RuleSetName,Value=ses-inbound-strict-ruleset \
  --start-time "$START" --end-time "$NOW" \
  --period 300 --statistics Sum
```

random 宛が増えないことを期待 (inbox 宛だけ +1)。

S3 archive も同様に inbox 宛のみが保存される:

```sh
aws s3 ls s3://ses-inbound-strict-archive-<acct>/inbox/ --region ap-northeast-1
```

### 5. Lambda ログ確認

```sh
aws logs tail /aws/lambda/ses-inbound-strict-processor --region ap-northeast-1 --follow
```

許可アドレス宛のみ Lambda が起動するので、許可外メールは Lambda レイヤには到達しない (= Lambda 起動コストもかからない)。

### 6. destroy

```sh
terraform destroy
```

Lambda の CloudWatch Log Group は本 sandbox では terraform 管理しているので一緒に消える。

## 結果

(検証後に記入)

## 考察

(検証後に記入)

## メモ

- 「列挙外は受信前 SMTP reject = 無料」が 01 の catchall 構成と一番違うところ
- 後追い調査 (誰が `bbb@example.com` に送ろうとしたか) が必要なケースは catchall + archive を使う (01 アプローチ) ことになる。トレードオフ
- 許可アドレスを増やすには `allowed_recipients` を変更して `terraform apply` するだけ (Lambda の env var ALLOW_LIST_DOMAINS とは別軸)
