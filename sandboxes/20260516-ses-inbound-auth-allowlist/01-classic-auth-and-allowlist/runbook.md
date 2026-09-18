# 01-classic-auth-and-allowlist

20260512-ses-email-receiving の 02 (S3 archive + DLQ + alarm) をベースに、Lambda 内に 3 段判定 (DMARC PASS + spam/virus + sender ドメイン allow list) を追加した版。
IP Address Filter は terraform のサンプルとして書くだけ (デフォルト空配列)。

## 概要

```
                        +-- Rule "archive-all"  recipients=[example.com] → S3 archive (全受信メール永続化)
                        |
Receipt Rule Set ------ +
                        |
                        +-- Rule "process-inbox" recipients=[inbox@example.com] → SNS → Lambda
                                                                                       │
                                                                                       ▼
                                                                              ┌────────────────────────┐
                                                                              │ 0. headersTruncated?    │ → INFO ログ
                                                                              │ 1. dmarcVerdict==PASS?  │ → 否なら WARN return
                                                                              │ 2. spam/virus FAIL?     │ → 該当なら WARN return
                                                                              │ 3. From domain allow?   │ → 外なら WARN return
                                                                              │ 4. From vs source 差?   │ → INFO ログ
                                                                              └────────────────────────┘
                                                                                       │
                                                                              通過 → MIME パース + CW Logs (ACCEPTED)
```

- allow list は Lambda env var `ALLOW_LIST_DOMAINS` (terraform variable から流し込み)、デフォルト `gmail.com`
- **allow list 判定は `commonHeaders.from` のドメイン** で行う (envelope MAIL FROM ではなく From ヘッダ。DMARC PASS 後はアラインが保証されているので信頼可能、かつユーザーが意図する「表示上の差出人」と一致)
- 棄却されたメールも archive-all rule で S3 には残っている (後追い調査可能)
- SES → Lambda の失敗系は 20260512/02 と同じく SQS DLQ (SNS subscription redrive policy) + CloudWatch アラームでカバー

## SES → Lambda payload で使うフィールド (公式ドキュメント参照)

| フィールド | 用途 |
|---|---|
| `receipt.dmarcVerdict.status` | 主判定: PASS 以外は reject |
| `receipt.dmarcPolicy` | DMARC FAIL 時の送信側要求 (`none` / `quarantine` / `reject`) を WARN ログに記録 |
| `receipt.spfVerdict.status` / `receipt.dkimVerdict.status` | DMARC FAIL の内訳をログに記録 |
| `receipt.spamVerdict.status` / `receipt.virusVerdict.status` | FAIL なら reject |
| `mail.commonHeaders.from` | allow list の判定対象 (表示上の差出人) |
| `mail.source` | 参考: envelope MAIL FROM。From ドメインと不一致なら INFO ログ |
| `mail.headersTruncated` | true (= header 10KB 超) なら WARN ログ |
| `mail.messageId` | 全 WARN/INFO ログに含めて trace 可能に |

不採用にしたが将来検討:
- `commonHeaders.replyTo` / `commonHeaders.sender` でフィッシング兆候 (From と Reply-To のドメイン乖離) を見る
- `receipt.recipients` と `mail.destination` の差で BCC 経由の不正利用検知

## 前提

- `AWS_PROFILE=terraform`
- 既存 active receipt rule set がないこと (20260512 の destroy 済を確認):
  ```sh
  aws ses describe-active-receipt-rule-set --region ap-northeast-1
  ```
- `example.com` の Route53 Hosted Zone は 20260512 destroy で消えているので、本 sandbox で新規作成 → DNS 伝播待ち (約 30 分) が発生する

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

apply で構築されるもの (20260512 の 02 とほぼ同じだが、Lambda env var と IP filter 用 variable が増える):
1. Route53 Hosted Zone + Route53 Domains NS 委任 同期
2. SES Domain Identity + Easy DKIM + 関連 DNS records (`_amazonses` TXT / DKIM CNAME ×3 / MX)
3. S3 archive バケット (Lifecycle 30 日 IA / 365 日削除、`force_destroy=true`)
4. SNS topic (mail) + topic policy (SES publish 許可)
5. SQS DLQ + queue policy (SNS から SendMessage 許可) + SNS subscription の redrive_policy
6. Lambda (Python 3.12) + IAM role + permission
7. SES Receipt Rule Set + Active 化 + 2 rules (archive-all + process-inbox)
8. CloudWatch アラーム 3 種 (Lambda Errors / DLQ depth / SNS NumberOfNotificationsFailed) + alerts SNS topic
9. IP Receipt Filter (サンプル、デフォルト空配列で no-op)

### 2. DNS 伝播待ち + SES verification

```sh
dig +short MX example.com @8.8.8.8
aws sesv2 get-email-identity --email-identity example.com --region ap-northeast-1 \
  --query '{V:VerifiedForSendingStatus,D:DkimAttributes.Status}'
```

`SUCCESS / true` になるまで待つ。

### 3. テスト (gmail から実機送信)

ユーザーに依頼: 「Gmail から `inbox@example.com` 宛にテスト送信してください (件名・本文に識別文字列入れてください)」

期待される動作:
- spfVerdict / dkimVerdict / dmarcVerdict すべて PASS
- allow list (gmail.com) match
- Lambda が ACCEPTED ログを吐く

### 4. allow list 外からの送信を試したい場合

- Gmail 以外 (Yahoo Mail / iCloud / Outlook 等) から送信して `WARN allowlist: ...` が出ることを確認
- ただし送信元によっては DMARC が PASS にならない可能性もあるので、その場合は最初の判定 `WARN auth: ...` で落ちる

### 5. ログ確認

```sh
aws logs tail /aws/lambda/${sandbox_name}-processor \
  --region ap-northeast-1 --follow
```

判定ステップごとに出るキーワード:
- `WARN headers:` → headersTruncated=true (10KB 超、不正利用兆候)
- `WARN auth:` → dmarcVerdict != PASS、`dmarcPolicy` も併記
- `WARN scan:` → spamVerdict / virusVerdict が FAIL
- `WARN allowlist:` → commonHeaders.from のドメインが allow list 外
- `INFO sender:` → From ドメインと envelope MAIL FROM ドメインの mismatch (reject せず情報のみ)
- `ACCEPTED` → 全段通過 (本処理)

### 6. IP Filter を試したい場合 (任意)

完全ホワイトリスト化したい場合は `terraform.tfvars` などで:

```hcl
ip_block_list = ["0.0.0.0/0"]
ip_allow_list = ["10.0.0.0/8"]  # 実環境の許可 IP に置き換える
```

を入れて `terraform apply`。**ただし apply 後はそれ以外の全 IP からの受信が止まるので注意**。

### 7. destroy

```sh
terraform destroy
```

destroy 後は post-pr skill の AWS 棚卸し手順で orphan log group をチェック・削除する。

## 結果

2026-05-17 検証。4 つのテストパスを実機 + Lambda invoke で確認。

### Test 1: Gmail からの正規メール → ACCEPTED

ユーザーが Gmail から `inbox@example.com` 宛に送信。

```
ACCEPTED messageId=1qfaf51hvpto30h832ntmfcd6vb79i3e29espsg1
From=Test Sender <test-sender@gmail.com> To=inbox@example.com
Body preview: テスト送信の内容
Duration: 14.72 ms / Init: 116 ms / Memory: 41 MB
```

- Gmail の SPF / DKIM / DMARC が正しく通る → DMARC PASS
- spam/virus PASS
- commonHeaders.from のドメイン `gmail.com` が allow list match → 本処理に到達

### Test 2: SES self-send → WARN auth (DMARC GRAY)

`aws sesv2 send-email --from test@example.com --to inbox@example.com` で送信。

```
WARN auth: dmarcVerdict=GRAY dmarcPolicy=- spf=PASS dkim=GRAY
messageId=l7ha2skik5cjmdg646315ia3l14umlvjts3pda01 — reject
```

- SES の自送信は内部経路で DKIM 署名が verifier から見えず DKIM GRAY
- そのため DMARC も GRAY (DMARC 評価不能)
- DMARC PASS 要求の厳しめ運用なので auth 段階で reject
- `dmarcPolicy=-` は送信側 DMARC レコードが SES 経路では引かれないため

### Test 3: Hotmail.co.jp からの正規メール → WARN allowlist

ユーザーが hotmail.co.jp の MUA から送信。

```
WARN allowlist: from_domain=hotmail.co.jp envelope_domain=hotmail.co.jp
allow_list=['gmail.com'] messageId=5ih9o7n9ijeibtr84tm3kc060jikfuqvqfumokg1 — reject
Duration: 2.51 ms
```

- hotmail.co.jp の DMARC は正しく設定済 → 認証は PASS で通過
- allow list 検査で `hotmail.co.jp not in ['gmail.com']` で reject
- 本処理に到達せず軽量 (2.51 ms)

### Test 4: スプーフィング攻撃シミュレーション → WARN auth (DMARC FAIL)

家庭 ISP は port 25 outbound を塞ぐので本物の SMTP 偽装は実機で試せない。
代わりに **Lambda を SNS event 形式の payload で直接 invoke** して、SES が SPF/DKIM/DMARC 全 FAIL を返したときの Lambda 挙動を検証する。

#### 再現手順

```sh
cat > /tmp/spoof-payload.json <<'EOF'
{
  "Records": [
    {
      "EventSource": "aws:sns",
      "EventVersion": "1.0",
      "Sns": {
        "Type": "Notification",
        "MessageId": "spoof-test-001",
        "TopicArn": "arn:aws:sns:ap-northeast-1:<account-id>:ses-inbound-v3-mail",
        "Message": "{\"notificationType\":\"Received\",\"mail\":{\"timestamp\":\"2026-05-17T01:00:00.000Z\",\"source\":\"attacker@evil.example\",\"messageId\":\"spoof-message-id-001\",\"destination\":[\"inbox@example.com\"],\"headersTruncated\":false,\"headers\":[{\"name\":\"From\",\"value\":\"Gmail Support <support@gmail.com>\"}],\"commonHeaders\":{\"from\":[\"Gmail Support <support@gmail.com>\"],\"to\":[\"inbox@example.com\"],\"subject\":\"Spoofing attempt\"}},\"receipt\":{\"timestamp\":\"2026-05-17T01:00:01.000Z\",\"processingTimeMillis\":100,\"recipients\":[\"inbox@example.com\"],\"spfVerdict\":{\"status\":\"FAIL\"},\"dkimVerdict\":{\"status\":\"FAIL\"},\"dmarcVerdict\":{\"status\":\"FAIL\"},\"dmarcPolicy\":\"reject\",\"spamVerdict\":{\"status\":\"PASS\"},\"virusVerdict\":{\"status\":\"PASS\"},\"action\":{\"type\":\"SNS\",\"topicArn\":\"arn:aws:sns:ap-northeast-1:<account-id>:ses-inbound-v3-mail\",\"encoding\":\"UTF8\"}},\"content\":\"From: Gmail Support <support@gmail.com>\\r\\nTo: inbox@example.com\\r\\nSubject: Spoofing attempt\\r\\n\\r\\nThis is spoofed.\"}",
        "Timestamp": "2026-05-17T01:00:01.000Z"
      }
    }
  ]
}
EOF

aws lambda invoke --region ap-northeast-1 \
  --function-name ses-inbound-v3-processor \
  --cli-binary-format raw-in-base64-out \
  --payload file:///tmp/spoof-payload.json \
  /tmp/lambda-response.json
```

シナリオの意味:
- `mail.source` (envelope MAIL FROM) = `attacker@evil.example` (実際の送信元)
- `commonHeaders.from` = `Gmail Support <support@gmail.com>` (**偽装 From ヘッダ**)
- `receipt.spfVerdict=FAIL`: 送信元 IP が `gmail.com` の SPF レコードに含まれない (= 攻撃者が gmail を装ったが IP がバレた)
- `receipt.dkimVerdict=FAIL`: gmail の DKIM 秘密鍵がないので署名できない
- `receipt.dmarcVerdict=FAIL`: SPF/DKIM 両方失敗 + アラインも取れない
- `receipt.dmarcPolicy=reject`: gmail.com の DMARC ポリシーは `reject` (= 失敗時の取り扱いを送信側が明示要求)

#### 結果

```
WARN auth: dmarcVerdict=FAIL dmarcPolicy=reject spf=FAIL dkim=FAIL
messageId=spoof-message-id-001 — reject
Duration: 5.53 ms
```

auth 段階で reject、本処理に到達せず。

#### 検証の射程

このテストは **「SES が verdict を FAIL で返したときに Lambda が正しく弾けるか」** をスコープとする。SES 側の SPF/DKIM/DMARC 評価そのものの正しさ (= 偽装メールが本当に SES に到達したら正確に FAIL 判定されるか) は AWS の責務で、Test 1 (Gmail 正規) で実機 PASS が返ることを以て妥当性は担保されている。

実機の SMTP 偽装で end-to-end 検証したい場合:
- AWS EC2 で port 25 outbound unblock 申請 (数日)、または
- 既にメールサーバーを持っている環境から SES inbound endpoint に SMTP 接続して実験

家庭 / オフィス ISP 経由では port 25 outbound が塞がれていて再現不可。

## 考察

### 良い点
- Classic SES + Lambda の範囲で **DMARC を主軸にした厳格なドメイン認証 + ドメイン allow list** を素直に実装できた。Mail Manager のような追加コスト不要
- 偽装メールは SES が SPF/DKIM/DMARC verdict を FAIL で返してくれるので、Lambda 側はその結果を信じて捨てるだけで良い (再実装の必要なし)
- `commonHeaders.from` を allow list の判定軸にしたことで、ユーザーが意図する「表示上の差出人」と一致して直感的
- 棄却されたメールも archive-all rule で S3 に残るので、誤判定の調査・再処理が可能
- Lambda invoke で SNS event を疑似発火させる検証手法が安く正確 (port 25 ISP 制約を回避)

### 悪い点 / 制約
- **DMARC PASS 要求は厳しすぎる副作用**: DMARC を未設定の正当ドメイン (古い社内システム等) からのメールも GRAY で全部落ちる。実運用では「GRAY は通すが警告ログだけ出す」など緩める判断が必要
- **Allow list 判定は DMARC PASS 後の From ヘッダに依存**: DMARC PASS 必須にしているので安全だが、もし DMARC 要件を緩めると From は偽装可能なので allow list の信頼性が下がる。設計のセットで考えるべき
- **`mail.source` と `commonHeaders.from` のドメイン乖離** が発生するケース (転送 / リレー) では INFO ログのみで通す。本格運用では一致を要求するかどうか要再検討
- **IP Address Filter は実用性が低い**: メールサーバーの IP は事前把握困難、運用負荷高。block list として既知の悪意 IP を入れる程度の用途に限られる
- **`port 25 outbound` がローカル ISP 制約で塞がれていて、本物の SMTP スプーフィング検証は不可**。Lambda invoke による疑似シナリオで代替

### 次にやるなら
- DMARC GRAY を通す緩めモードと厳しいモードを env var で切り替えられるようにする
- 完全アドレス単位の allow list (`ALLOW_LIST_ADDRESSES`) を実装してドメインと併用パターンを試す
- SPF / DKIM verdict のどれか一つでも PASS なら通す中庸モードも比較
- 既知の bogon IP プレフィックスを `ip_block_list` に入れて IP Filter の動作を実機で確認

## メモ

- DMARC PASS 要求は厳しめ設定: SPF または DKIM のいずれかが PASS かつ From ヘッダとアラインしている必要がある。DMARC 未設定の正当ドメインからのメールも `GRAY` で落ちる (= 過剰防御の副作用)
- allow list 判定は `commonHeaders.from` のドメインで行う (`mail.source` (envelope MAIL FROM) ではない)。理由は handler.py の docstring 参照
- アドレス単位の制限が必要なら `_passes_allow_list` を拡張 (handler.py 内コメント参照)
