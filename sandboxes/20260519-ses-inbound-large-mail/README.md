# SES 受信パイプライン: 大きいメール (≤40MB) 対応

> 検証日: 2026-05-19
> Obsidian: [[ノートへのリンク]]

## 背景 / 課題

20260516-ses-inbound-auth-allowlist の 03 sandbox で構築した SES 受信パイプラインは **SNS publish action 経由** のため SNS の 150KB 上限に縛られる。返信を含む長文メール / HTML email / 添付込みメールを LLM 処理に流すには手狭。

本検証では **S3 ObjectCreated event → SNS → Lambda** に組み替えて、最大 **40MB** までのメールを処理できる構成に切り替える。

## 仮説

- SES Receipt Rule の `sns_action` を削除し `s3_action` のみにすれば、メール本体は S3 に保存される (40MB 限度)
- S3 ObjectCreated event を SNS topic に publish → Lambda が subscribe する経路で Lambda 起動できる
- Lambda 内で S3 GetObject して raw MIME バイト列を取得 → email module で MIME パース
- SES が S3 に追加する `Authentication-Results` / `X-SES-Spam-Verdict` / `X-SES-Virus-Verdict` ヘッダから verdict を抽出 = SES SNS notification を捨てても判定ロジックは維持できる

## 検証環境

- Domain: `example.com` (Route53 Domains 登録済)
- Region: `ap-northeast-1`
- AWS Profile: `terraform`
- module: `modules/ses-inbound` (本 sandbox 配下、S3-trigger 版)
- 03 sandbox (20260516) の module とは別物。03 は SNS-content 直接処理 (軽量、≤150KB)、本 sandbox は S3 経由 (重い、≤40MB)

## Approach 比較

| #   | Approach              | 概要                                                       | 上限   | latency | 結果 |
| --- | --------------------- | ---------------------------------------------------------- | ------ | ------- | ---- |
| 01  | s3-trigger-processor  | SES → S3 → S3 event → SNS → Lambda、ヘッダから verdict 抽出 | 40 MB | 285ms (S3 GetObject 込) | OK: 1MB 画像添付メール処理成立、Lambda 失敗→DLQ→手動再投入も実証 |

詳細は `01-s3-trigger-processor/runbook.md` を参照。

## 結論 / 学び

- **S3 → SNS → Lambda の 3 段経路で 40MB 上限まで処理可能**。LLM 処理パイプラインで HTML email / 添付ファイル付き / 長文 reply chain を扱う前提なら本 sandbox の構成が筋
- **SES が S3 に保存するメールに追加するヘッダ (`Authentication-Results` / `X-SES-Spam-Verdict` / `X-SES-Virus-Verdict`) から verdict を抽出できる**ので、SES SNS notification を捨ててもフィルタロジックは維持できる
- **`aws_sns_topic_subscription.redrive_policy` と `aws_lambda_function.dead_letter_config` は別物**:
  - 前者は「SNS が Lambda Invoke API を呼ぶこと自体に失敗した」場合
  - 後者は「Lambda が起動して関数内で例外」の場合
  - 関数失敗を DLQ で拾うには **両方** か、少なくとも `dead_letter_config` の方が必須
- **DLQ メッセージは元の SNS message そのもの**なので、`aws sns publish` で同じ topic に再 publish すれば Lambda 再起動 = idempotent な処理なら復旧操作は単純
- Lambda async retry は **最大 2 retries で固定** (= 3 attempts 上限)。それ以上欲しいなら redrive Lambda 等のアプリ層実装が必要
- 失敗パイプラインの安全網は二重: **S3 archive (本体、1 年残る)** + **SQS DLQ (失敗イベント、14 日残る)**。両方失う条件は厳しいので実用上ロストは稀

## 関連リンク

- [SES email receiving concepts](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-concepts.html)
- [SES が S3 に追加するヘッダ (Authentication-Results 等)](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-s3.html)
- 20260516-ses-inbound-auth-allowlist (前提となる軽量処理版)
