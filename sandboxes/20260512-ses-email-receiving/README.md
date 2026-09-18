# SES でメール受信を試す

> 検証日: 2026-05-12
> Obsidian: [[ノートへのリンク]]

## 背景 / 課題

SES のメール受信機能は東京リージョン (`ap-northeast-1`) でも 2023 年 9 月以降利用可能。
ドメイン認証から MX 設定、Receipt Rule の挙動、Lambda への payload 受け渡し方法など、
実際にどこまで素直に動くのか/制約は何かを確認する。

## 仮説

- DKIM 済みドメインなら追加認証作業は不要で、MX を SES inbound endpoint に向けるだけで受信できる
- Receipt Rule の Lambda 直接アクションでは本文 (MIME body) は payload に含まれない → 本文を扱うには SNS or S3 経由が必要
- 同一 AWS アカウント内で Route53 Domains → Route53 Hosted Zone → SES → SNS → Lambda まで terraform 完結可能

## 検証環境

- Domain: `example.com` (Route53 Domains 登録済み、未使用)
- Region: `ap-northeast-1`
- AWS Profile: `terraform`
- 受信したメールは Lambda で MIME パース → CloudWatch Logs にヘッダと本文先頭を書き出す (副作用なし、検証用)

## Approach 比較

| #   | Approach                       | 概要                                                                                                                        | 制約                                                              | 結果                                                                |
| --- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------- |
| 01  | sns-to-lambda                  | SES Receipt Rule の SNS action → Lambda subscribe                                                                          | メールサイズ 150KB 超でバウンス                                   | OK: 日本語本文含めて Lambda で MIME パース成功 (02 へ state 移行済) |
| 02  | multi-recipient-archive-dlq    | 全件 S3 archive + 特定アドレスのみ Lambda + 別アドレスはバウンス。SQS DLQ と CloudWatch アラームで失敗経路を塞ぐ堅牢化版 | DKIM token を count で import する際の順序ミスで plan が壊れやすい | OK: 3 アドレスの分岐動作 + DLQ 0 件 + archive 全件保存を確認        |

## 仕様メモ (公式ドキュメント要約)

### Receipt Rule の Action 別 payload

| Action               | 本文を含むか                                       |
| -------------------- | -------------------------------------------------- |
| Lambda 直接          | **含まない** (header と receipt metadata のみ)       |
| SNS                  | **含む** (生 MIME を UTF-8 or Base64、150KB 上限)    |
| S3                   | **含む** (生 MIME を S3 オブジェクトとして保存、40MB) |
| Lambda + S3 (2 action) | Lambda は header のみ、本文は S3 から取得           |

### DKIM 済みドメインで送受信兼用
- ドメイン認証は send/receive 共通。Easy DKIM CNAME が引かれていれば追加検証不要
- 受信のために追加で要るのは MX レコードのみ
- SES sending sandbox 解除は受信には不要 (受信は最初から本番可)

### リージョン制約
- 受信に紐づく Lambda / SNS / KMS は SES と同一リージョン必須 (S3 のみクロスリージョン可)
- 東京リージョン inbound endpoint: `inbound-smtp.ap-northeast-1.amazonaws.com`

### Receipt Rule Set はアカウント singleton
- アクティブにできる rule set は 1 アカウントにつき 1 つまで
- `aws_ses_active_receipt_rule_set` は既存のアクティブ rule set を上書きする

## 結論 / 学び

- **DKIM 済みドメインで送受信兼用は素直に動く**: 既存の verified identity に MX を足すだけで受信開始可能
- **Lambda 直接呼び出しでは本文が来ない** は公式仕様 (該当ドキュメントに明記)。本文を Lambda で扱いたいなら最低限 SNS or S3 を経由する必要がある
- **SNS 経由は 150KB 上限が厳しい**: 添付付きメールを想定するなら S3 経由 (40MB) かハイブリッド構成が現実解
- **同一 AWS アカウント内なら terraform 完結度が高い**: Route53 Domains の NS 委任まで 1 回の apply で済む
- 注意: SES Receipt Rule Set は **アカウント × リージョンで 1 つしかアクティブにできない singleton**。受信系の検証を並行で走らせる場合は衝突する

## 関連リンク

- [Email receiving with Amazon SES](https://docs.aws.amazon.com/ses/latest/dg/receiving-email.html)
- [Lambda action](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-lambda.html) (本文を含まない旨が明記)
- [SNS action](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-sns.html) (150KB 制限の根拠)
- [SES regions and endpoints](https://docs.aws.amazon.com/general/latest/gr/ses.html)
