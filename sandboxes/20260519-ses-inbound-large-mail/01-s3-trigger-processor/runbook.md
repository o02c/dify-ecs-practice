# 01-s3-trigger-processor

S3 ObjectCreated event を trigger に Lambda が起動する構成。SES SNS publish action を使わない代わりに、Lambda 内で S3 GetObject して raw MIME を読み、ヘッダから verdict を抽出する。

## 概要

```
       MX → inbound-smtp.ap-northeast-1.amazonaws.com
                            │
                            ▼
                 SES Receipt Rule Set
                            │
                            ▼
        Rule (recipients=[allowed-list]、s3_action のみ)
                            │
                            ▼ S3 PutObject (最大 40MB)
                  S3 archive bucket
                            │ s3:ObjectCreated event
                            ▼
                    SNS topic (mail)
                            │
                            ▼
                  Lambda processor
                  ├ S3 GetObject で raw MIME 取得
                  ├ Authentication-Results ヘッダ → SPF/DKIM/DMARC
                  ├ X-SES-Spam-Verdict / X-SES-Virus-Verdict → scan
                  ├ From ヘッダ → allow list 判定
                  └ ACCEPTED ログ
```

## 前提

- `AWS_PROFILE=terraform`
- 既存 active receipt rule set がないこと
- `o2c.click` の Hosted Zone は前 sandbox の destroy で消えているので新規作成 → DNS 伝播待ち発生

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

### 2. DNS 伝播 + SES verification 待ち

```sh
dig +short MX o2c.click @8.8.8.8
aws sesv2 get-email-identity --email-identity o2c.click --region ap-northeast-1 \
  --query '{V:VerifiedForSendingStatus,D:DkimAttributes.Status}'
```

### 3. テスト送信

Gmail から `inbox@o2c.click` 宛にテスト送信。

期待ログ (`/aws/lambda/ses-inbound-v4-processor`):
```
Processing s3://...-archive-.../inbox/<messageId> (messageId=<messageId>)
ACCEPTED messageId=<id> size=<bytes> Subject=... From=... To=...
Body preview: ...
```

### 4. 大きめメールのテスト (≥ 150KB)

長い reply chain や HTML formatted メール、または小さな画像添付付きで送信。150KB を超えるメールでも:
- S3 に保存される (40MB まで)
- Lambda が S3 から読んで処理する
- ACCEPTED ログが出る (size= が 150000 を超えていれば成功)

03 sandbox との挙動比較:
- 03 (SNS content 経由): 150KB 超え → SES が SNS publish 失敗 → 送信者にバウンス DSN
- 04 (S3 経由): 40MB まで素直に処理

### 5. 失敗系の検証

Lambda code を一時的に壊して (`raise Exception` 等) 再 deploy → メール送信 → SNS retry (Lambda async 既定 2 回) → 全失敗で SQS DLQ に payload 退避 → CloudWatch アラーム `dlq-depth` 発火を確認。

### 6. DLQ に滞留したメッセージの手動再実行

Lambda async invoke の 3 attempts 全失敗 → DLQ にメッセージ滞留する。
本 module は **`aws_lambda_function.processor.dead_letter_config`** で SQS DLQ に payload 保存している (SNS subscription の redrive_policy は SNS→Lambda invoke 自体の失敗のみ拾うため別途必要)。

**前提: DLQ アラーム発火 → Slack で気付く → 失敗原因を調査・修正 → 復旧 deploy → DLQ メッセージを再投入。**

#### CLI で再投入する手順

DLQ に入っているメッセージは **Lambda invocation の入力 event** そのもの (= SNS message 形式)。これを再度 SNS topic に publish するか、Lambda を直接 invoke する。

注: 以下のコマンド例は `--output json` 明示。`~/.aws/config` で `output = yaml` を default にしている環境だと jq に渡せないので、明示するか `AWS_DEFAULT_OUTPUT=json` を export する。

```sh
DLQ_URL=https://sqs.ap-northeast-1.amazonaws.com/<account-id>/ses-inbound-v4-lambda-dlq
SNS_TOPIC_ARN=arn:aws:sns:ap-northeast-1:<account-id>:ses-inbound-v4-mail
REGION=ap-northeast-1

# 1. DLQ からメッセージを 1 件受信 (visibility timeout 60 秒中に検証)
aws sqs receive-message \
  --queue-url "$DLQ_URL" --region "$REGION" \
  --max-number-of-messages 1 --visibility-timeout 60 --wait-time-seconds 5 \
  --output json > /tmp/dlq.json
jq '.Messages[0] | {MessageId, BodyLength: (.Body | length)}' /tmp/dlq.json

# 2. body (= Lambda invocation event) と nested S3 event を確認
jq -r '.Messages[0].Body' /tmp/dlq.json | jq '.Records[0] | {EventSource, "Sns.TopicArn": .Sns.TopicArn}'
jq -r '.Messages[0].Body' /tmp/dlq.json | jq -r '.Records[0].Sns.Message' | jq '.Records[0].s3'

# 3. 元の S3 event を取り出して SNS に再 publish (= Lambda 再起動)
ORIG_S3_EVENT=$(jq -r '.Messages[0].Body' /tmp/dlq.json | jq -r '.Records[0].Sns.Message')
aws sns publish --region "$REGION" \
  --topic-arn "$SNS_TOPIC_ARN" \
  --message "$ORIG_S3_EVENT"

# 4. 再実行成功を Lambda ログで確認
aws logs tail /aws/lambda/ses-inbound-v4-processor --region "$REGION" --since 1m

# 5. 成功確認できたら DLQ からメッセージを削除
RH=$(jq -r '.Messages[0].ReceiptHandle' /tmp/dlq.json)
aws sqs delete-message --queue-url "$DLQ_URL" --region "$REGION" \
  --receipt-handle "$RH"
```

**重要**: SNS subscription の redrive_policy だけだと Lambda 関数失敗をキャプチャできない。`aws_lambda_function.dead_letter_config` を Lambda 関数自体に設定して初めて関数失敗が DLQ に入る。本 module は両方設定済 (SNS-level も Lambda-function-level も同じ SQS を指している)。

複数件まとめて再投入したい場合は `--max-number-of-messages 10` (SQS 上限) で取得して loop。

#### マネコン (AWS Console) で再投入する手順

##### (a) 内容確認 + 削除のみ (推奨パス)
1. SQS console → Queues → `ses-inbound-v4-lambda-dlq` を選択
2. 右上の **Send and receive messages** ボタン → **Receive messages** セクション → **Poll for messages**
3. 表示されたメッセージ行を展開、**Body** タブで Lambda invocation event を確認
4. 中の `Records[0].Sns.Message` (文字列の中の JSON) を取り出して失敗対象 S3 オブジェクトを特定
5. (再実行する場合は) 別タブで SNS console → mail topic を開いて **Publish message** で本文に取り出した S3 event JSON を貼り付けて publish
6. 再実行成功を CloudWatch Logs (`/aws/lambda/<name>-processor`) で確認したら、SQS console に戻って当該メッセージにチェック → **Delete**

##### (b) SQS の Start DLQ redrive (2022〜の組込機能)
1. SQS console → DLQ を選択 → 右上 **Start DLQ redrive**
2. **Redrive to**: 「Custom destination」を選択し、別 SQS queue ARN を指定
3. **Number of messages**: 投入したい件数
4. 開始

(b) は SQS-to-SQS の redrive を想定した機能で、SNS topic を直接指定はできない。SNS subscription DLQ + Lambda DLQ の本構成では中継 SQS が必要で本末転倒なので、**(a) → CLI で SNS publish** の方が現実的。

#### 自動再投入 Lambda (将来検討)

人間オペレーションを省きたい場合は **DLQ → SQS event source mapping → 再投入 Lambda → SNS publish** の chain を追加する。ただし試行回数の上限管理 (DynamoDB に attempt count を記録、N 回超えたら諦める) を入れないと永遠に loop する。本検証スコープ外。

### 7. destroy

```sh
terraform destroy
```

## 結果

2026-05-19 - 05-20 検証。

### 通常メール (S3 trigger 経由)
- Gmail から 1MB の画像添付付きメールを送信 → S3 archive bucket に `inbox/<messageId>` で 1,034,250 byte 保存
- S3 ObjectCreated event → SNS → Lambda 起動、`s3.get_object` で raw MIME を読んで MIME パース、ACCEPTED ログ
- Duration 285ms (SNS-content 直接版は ~5ms だったので S3 GetObject 分の latency 増、許容範囲)
- 03 sandbox (SNS-content 直接、150KB 上限) では SES が SMTP 段階で bounce していたサイズが本 sandbox では処理成立

### Lambda 失敗 → DLQ → 再実行
- 存在しない S3 key を含む synthetic S3 event を SNS に publish → Lambda が `s3:GetObject` で 403 AccessDenied (存在しないキーかつ ListBucket 権限なしで NoSuchKey ではなく AccessDenied になる AWS 仕様)
- Lambda async retry: 3 attempts (1 + 2 retries) 全失敗 ✓
- 当初 DLQ に 0 件のままだった → 原因: SNS subscription の `redrive_policy` は SNS→Lambda invoke 自体の失敗のみキャッチ、関数失敗には反応しない
- 修正: `aws_lambda_function.processor.dead_letter_config.target_arn` を追加 + Lambda 実行ロールに `sqs:SendMessage` 権限
- 修正後再テスト: 3 attempts 失敗 → DLQ に 1 件入る ✓
- DLQ メッセージの中身を `aws sqs receive-message` で確認 → `Body.Records[0].Sns.Message` に元の S3 event JSON が入っている = SNS message そのまま
- `aws sns publish` で同じ S3 event を再 publish すれば Lambda 再起動できる (= 復旧成立)
- DLQ から `aws sqs delete-message` で削除して状態クリア

## 考察

### 良い点
- **S3 trigger 方式で 40MB まで処理可能** = LLM パイプライン向けの実用ライン
- SES が S3 deliver 時に追加するヘッダ (`Authentication-Results` / `X-SES-Spam-Verdict` / `X-SES-Virus-Verdict`) からの verdict 抽出が機能、SNS notification を捨てても判定ロジックは維持できる
- Lambda 失敗時の 3-attempts retry → DLQ → 手動再投入の流れが揃った
- DLQ メッセージは Lambda invocation event そのものなので、SNS topic に再 publish するだけで失敗時と完全に同じ条件で Lambda 起動できる (idempotent な処理ならば二重実行も無害)

### 悪い点 / 制約
- **SNS subscription redrive_policy だけでは関数失敗を拾えない** という落とし穴 (今回踏んだ)。`aws_lambda_function.dead_letter_config` も併設するのが正解
- Lambda async retry は最大 2 retries (= 3 attempts) で固定。それ以上の再試行はアプリケーション層で実装する必要 (例: redrive Lambda + 試行回数管理)
- DLQ visibility timeout が 30 秒なので、検証中に短時間で何度も receive すると次の receive で空が返る挙動。runbook の例では `--visibility-timeout 60` 明示
- `~/.aws/config` の `output = yaml` が default だと jq へのパイプが壊れる。`--output json` 明示 or `AWS_DEFAULT_OUTPUT=json` で対応
- 存在しないキーで `s3:GetObject` 呼ぶと NoSuchKey ではなく **AccessDenied** が返る AWS 仕様。エラーログを読み解く時の罠

### 次にやるなら
- 自動 redrive Lambda (DLQ → 再 publish + 試行回数管理) を追加実装
- メッセージ body 中身が壊れている場合 (idempotency 取れないケース) の handling パターン整理
- KMS 暗号化 (SES → S3 暗号化付き保存、Lambda 復号化) を入れて compliance 向けの構成
