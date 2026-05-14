# 01-sns-to-lambda

SES Receipt Rule の SNS action でメール全体を SNS topic に publish し、その topic に subscribe した Lambda で MIME をパースする構成。

## 概要

```
[sender] --SMTP-->  inbound-smtp.ap-northeast-1.amazonaws.com
                              |
                       (MX o2c.click)
                              |
                  +-----------v-----------+
                  | SES Receipt Rule Set  |
                  | recipients: o2c.click  |
                  +-----------+-----------+
                              |
                       SNS Publish (UTF-8)
                              |
                  +-----------v-----------+
                  |   SNS Topic (mail)   |
                  +-----------+-----------+
                              |
                        (subscription)
                              |
                  +-----------v-----------+
                  |  Lambda (processor)  |---> CloudWatch Logs
                  +-----------------------+
```

- SES → SNS → Lambda の単純パス。本文は SNS message の `content` フィールドに UTF-8 文字列で入る
- Route53 Hosted Zone と Route53 Domains の NS 委任もこの terraform で完結 (同一アカウント)
- 150KB 超のメールはバウンスする (制約)

## 前提

- `AWS_PROFILE=terraform` で credential 設定済み
- `o2c.click` が Route53 Domains に登録済み (確認済み)
- 既存の active receipt rule set がないこと (上書きされる)。確認:
  ```sh
  aws ses describe-active-receipt-rule-set --region ap-northeast-1
  ```

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

terraform 内で以下を作成・設定する:

1. Route53 Hosted Zone (`o2c.click`)
2. Route53 Domains の name_server を hosted zone の NS に同期 (registrar 側委任)
3. SES Domain Identity + Easy DKIM
4. Route53 レコード: `_amazonses.o2c.click` TXT (identity verification) / DKIM CNAME ×3 / MX
5. SNS Topic + topic policy (SES から publish 許可)
6. Lambda + IAM role / SNS subscription / SNS → Lambda invoke 許可
7. SES Receipt Rule Set + Active 化 + Receipt Rule (recipients=`["o2c.click"]`, SNS action)

### 2. NS 委任の伝播待ち

Route53 Domains の name_server 更新は数分〜数十分で反映される。確認:

```sh
# レジストリ側 (権威 NS) の確認
dig +short NS o2c.click @8.8.8.8

# 期待: awsdns-*.{org,co.uk,com,net} の 4 件 (Route53 Hosted Zone の NS)
```

### 3. SES Domain Identity の verification 待ち

DKIM CNAME と `_amazonses` TXT が DNS で引けるようになったら SES が自動検証する。

```sh
aws sesv2 get-email-identity \
  --email-identity o2c.click \
  --region ap-northeast-1 \
  --query '{Verified:VerifiedForSendingStatus, DkimStatus:DkimAttributes.Status}'
```

`Verified: true, DkimStatus: SUCCESS` になれば OK。

### 4. テストメール送信

外部のメールアドレス (gmail 等) から `test@o2c.click` 宛にメールを送る。
件名・本文に識別できる文字列を入れておく。

### 5. Lambda のログ確認

```sh
aws logs tail /aws/lambda/${sandbox_name}-processor \
  --region ap-northeast-1 \
  --follow
```

期待: `notificationType=Received`、Subject / From / To / Body preview がログに出る。

### 6. destroy

```sh
terraform destroy
```

注意: `aws_route53domains_registered_domain` を destroy しても **ドメイン登録自体は消えない**
(name_server の管理だけ解除される)。Hosted Zone を消すと name_server は宙に浮くので、
destroy 前に他のサービスで使う予定があれば name_server を別途設定すること。

## 結果

2026-05-12 検証。SES → SNS → Lambda の経路で end-to-end 動作確認。

### DNS 伝播
- `terraform apply` から約 30 分以内に `.click` レジストリ → 公開リゾルバ (8.8.8.8) に NS 委任が伝播
- SES の Domain Identity は DNS 伝播後すぐに `DkimAttributes.Status=SUCCESS` / `VerifiedForSendingStatus=true` に遷移

### テストメール (自アカウント SES から自ドメインへ送信)
```sh
aws sesv2 send-email --region ap-northeast-1 \
  --from-email-address "no-reply@o2c.click" \
  --destination "ToAddresses=inbox@o2c.click" \
  --content 'Simple={Subject={Data="...",Charset="UTF-8"},Body={Text={Data="日本語本文...",Charset="UTF-8"}}}'
```

Lambda ログ抜粋:
```
messageId=ad582otrfn180bs4e2a7ecliv8drib8u62bgce01
destinations=['inbox@o2c.click']
spamVerdict=PASS virusVerdict=PASS spfVerdict=PASS dkimVerdict=GRAY dmarcVerdict=GRAY
Subject: SES receive sandbox test
From: no-reply@o2c.click
To: inbox@o2c.click
Body preview:
これは SES → SNS → Lambda の動作確認用テストです。
日本語本文も含む。
Duration: 5.79 ms / Init: 118 ms / Max Memory: 41 MB / 256 MB
```

- SPF / spam / virus は PASS
- DKIM / DMARC は **GRAY** = SES が自分の outbound から受け取った経路では DKIM 署名検証が行われないため (外部 Gmail 等から送ると PASS になるはず)
- UTF-8 日本語本文がそのまま decode できた (rule action の encoding=UTF-8 設定が効いている)
- SES sending sandbox 状態 (`ProductionAccessEnabled=false`) でも、送信元/送信先ともに verified identity ならテスト送信可能だった

## 考察

### 良い点
- terraform 完結度が高い: Route53 Domains の NS 委任まで含めて 1 回の apply で済んだ (同一アカウントなので可能)
- Lambda 直接呼び出しの「本文 payload に入らない」制約を SNS 経由で回避できた。Lambda 側で `email.message_from_string` でそのままパース可能
- DKIM CNAME と `_amazonses` TXT 両方を入れておくと SES の verification が確実

### 悪い点 / 制約
- **150KB 上限**: 添付付きメールは即バウンス。実用では S3 経由併用が必須
- **Receipt Rule Set はアカウント singleton**: 別の検証で SES 受信を使う場合は active rule set を奪い合う
- Route53 Domains の `aws_route53domains_registered_domain` は us-east-1 endpoint のみ → provider alias が必要
- DKIM/DMARC verdict が GRAY なのは自アカウント送信特有 (要外部送信で再確認)

### 次にやるなら
- 外部 (Gmail 等) から送って DKIM/DMARC が PASS になるかを再確認
- 150KB 超のメール (添付付き) を送って実際にバウンスメッセージが返ってくるかを確認
- S3 経由のフォールバック構成 (02- としてもう 1 approach 追加) を比較

## メモ

- SNS encoding は `UTF-8` を選択。日本語が崩れたら `Base64` に変更してデコード処理を足す
- `aws_ses_active_receipt_rule_set` はアカウント singleton。既存アクティブがあれば置き換わる
- メール受信は SES sandbox 状態の影響を受けない (sandbox 制約は送信側のみ)
