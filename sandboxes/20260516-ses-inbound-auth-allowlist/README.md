# SES 受信メールのドメイン認証 + ホワイトリスト制限

> 検証日: 2026-05-16
> Obsidian: [[ノートへのリンク]]

## 背景 / 課題

20260512-ses-email-receiving で SES 受信の基本動作と多段 receipt rule + DLQ 構成は確認済み。
本検証ではさらに「不正な送信者からのメールを弾く」要件を classic SES の範囲でどこまでカバーできるか確認する。

具体的に押さえたいのは 2 点:

1. **送信ドメイン認証 (SPF / DKIM / DMARC) に基づくフィルタ**
2. **送信元アドレス / ドメインのホワイトリスト制限**

## 仮説

- Classic SES の Receipt Rule の条件 (`recipients`) では送信者・ヘッダ・認証結果で分岐できない
- SES は SPF / DKIM / DMARC を自動検証して verdict を notification に載せてくれるので、Lambda 側で評価して落とす
- ホワイトリストは Lambda 内で env var ベースに持てば軽い (DB 不要)
- IP Address Filter は `Receipt Filter` リソースで簡単に書けるが、メールサーバーの IP は事前把握が難しいため運用には向かない (書き方だけ押さえる)

## 検証環境

- Domain: `o2c.click` (20260512 の sandbox で destroy 済 → 新規に Hosted Zone 作り直し)
- Region: `ap-northeast-1`
- AWS Profile: `terraform`
- 受信したメールは Lambda で 3 段判定 → 通過したものだけ MIME パースして CW Logs に出力
- 棄却したメールも S3 archive には残る (堅牢化を 20260512 から継承)

## Approach 比較

| #   | Approach                          | 概要                                                            | 制約                                            | 結果 |
| --- | --------------------------------- | --------------------------------------------------------------- | ----------------------------------------------- | ---- |
| 01  | classic-auth-and-allowlist        | DMARC PASS 必須 + sender ドメインの allow list (env var)、IP Filter サンプル付き。catchall archive あり | DMARC 未設定ドメインからの正当メールも `GRAY` で落ちる / 全 @domain 宛が課金対象 | OK: 4 シナリオ (Gmail 正規 / SES 自送信 / Hotmail allow list 外 / 偽装 payload) すべて期待通りの判定 |
| 02  | strict-recipient-allowlist        | 01 の Lambda 判定はそのまま、SES Receipt Rule の `recipients` を **許可アドレス列挙のみ** にして catchall 撤廃。列挙外は SMTP 中 reject で課金回避 | 不正な宛先への送信試行が記録に残らない (CloudWatch メトリクスにも乗らない) | OK: inbox 宛 ACCEPTED + random 宛 SMTP 550、受信は inbox 宛 1 件のみ課金対象 |
| 03  | classic-with-killswitch           | 02 を module (`modules/ses-inbound`) 経由で再構築 + 受信レート / Lambda 起動レート閾値超過時に自動で active rule set を解除する killswitch Lambda を追加 | アカウント × region singleton なので発火すると同 region の他 SES 受信も止まる / 検知ラグで数分間の被害は発生 / 自動復旧は未実装 (誤発火時の影響大きいため手動推奨) | OK: アラーム手動 ALARM 遷移 → SNS → killswitch Lambda → active rule set 解除を end-to-end 確認、復旧手順も実証 |

詳細は各 approach の `runbook.md` を参照。

## 仕様メモ

### Classic SES の限界
- Receipt Rule の条件は **recipient (To address) のみ**。From / Subject / 認証結果での条件分岐は **Lambda action 必須**
- SES は SPF / DKIM / DMARC を自動評価し、SNS / S3 経由で結果 (`spfVerdict`, `dkimVerdict`, `dmarcVerdict`) を渡す
- SES 自身は verdict に基づく action を取らない (= 全部 Lambda 任せ)

### Mail Manager (今回スコープ外)
- Ingress Endpoint + Traffic Policy + Rule Set でネイティブに From / DKIM verdict / sender IP 等で分岐可能
- Address List (最大 100k 件) でホワイトリスト/ブラックリスト
- 固定費用 (Ingress endpoint per hour) が sandbox にはオーバーキル

### IP Address Filter (classic)
- アカウント × region 単位、最大 100 件
- 接続元 IP (= 送信メールサーバーの IP) でブロック/許可。SMTP 会話中に弾く = 受信課金されない
- 完全ホワイトリスト化したい場合: `0.0.0.0/0` block + 特定 IP allow

## 結論 / 学び

- **Classic SES + Lambda で「ドメイン認証 + ホワイトリスト」は実装可能**: SES が SPF/DKIM/DMARC を自動評価して verdict を notification に載せるので、Lambda はそれを信じて分岐するだけ。Mail Manager のような追加 stack 不要
- **DMARC PASS 要求を主軸にすると From ヘッダを信頼できる**: アラインが取れている前提が成り立つので、allow list 判定で `commonHeaders.from` を見るのが意味的に正しい
- **DMARC PASS は厳しすぎる場合あり**: 古い / 個人 / 社内メールサーバーで DMARC 未設定だと GRAY で落ちる。緩めの代替として「SPF か DKIM いずれか PASS」「DMARC GRAY を許容」を検討する
- **`commonHeaders.from` ≠ `mail.source` (envelope MAIL FROM)** が普通: バウンス受け取り先は別アドレスで設定されることが多い。DMARC PASS 後は From ヘッダが信頼できるのでこれを軸にすれば良い
- **IP Address Filter は限定用途**: メールサーバーの IP 事前把握は困難で、SPF レコード追跡のメンテも辛い。既知の悪意 IP を block list で永続ブロックする程度の用途に向く
- **port 25 outbound は家庭/オフィス ISP で塞がれていることが多い**: 本物の SMTP 偽装テストは EC2 で port 25 unblock 申請 or 既存 MTA から行う必要あり。代替として Lambda invoke で SNS event を疑似発火させれば Lambda 側ロジックは厳密に検証可能
- **Lambda payload に入る有用フィールドのうち未使用のもの**: `replyTo` / `sender` / `returnPath` (フィッシング兆候検出)、`receipt.recipients` と `mail.destination` の差 (BCC 経由検知)。本格的なアンチフィッシングなら追加検討

## 関連リンク

- [Email receiving concepts (classic)](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-concepts.html)
- [IP Address Filter walkthrough](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-ip-filtering-console-walkthrough.html)
- [SNS notification contents (verdict 形式)](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-notifications-contents.html)
- 20260512-ses-email-receiving (本検証の前提となる SES 受信構成)

## Q&A (要点だけ知りたい人向け)

これだけ読めば全体像が掴める Q&A。前の A の知識で次の Q が分かる順序。

### Q1. SES で受信したメールの送信元ドメインを認証する方法は?
SES が自動で SPF / DKIM / DMARC を評価し、結果 (`PASS` / `FAIL` / `GRAY` / `PROCESSING_FAILED`) を Lambda / SNS notification の `receipt.spfVerdict.status` などに載せる。SES 自身は verdict に基づく action を取らず、**Lambda 側で見て分岐する** のが classic SES の流儀。

### Q2. SPF / DKIM / DMARC それぞれを Lambda で個別に判定するべき?
**DMARC PASS だけ要求すれば足りる**。DMARC PASS の定義は「SPF か DKIM の少なくとも一方が PASS」かつ「From ヘッダのドメインと SPF/DKIM のドメインがアラインしている」なので、これが通れば SPF/DKIM の少なくとも片方は信頼できる状態。本検証は DMARC PASS のみ厳格要求。

### Q3. `dmarcVerdict=GRAY` って何? PASS と何が違う?
**SES が DMARC 判定をできなかった状態**。送信側ドメインが DMARC レコードを設定していない、もしくは SPF/DKIM 共に PASS しない場合に出る。Q2 の厳格運用では reject 扱い (本検証もこれ)。緩めたい場合は GRAY を通すなどの判断が必要。

### Q4. ホワイトリストの判定はどのフィールドで行う?
**`commonHeaders.from` のドメイン** が正しい。Q2 の DMARC PASS が通っていれば From ヘッダのドメインは SPF/DKIM とアラインされていて信頼できる。`mail.source` (envelope MAIL FROM) はバウンス受け取り先のことが多く別ドメインになりがちで、ユーザーが意図する「表示上の差出人」とずれる。

### Q5. アドレス単位で許可したい場合は?
`commonHeaders.from` を `email.utils.parseaddr` でパースすればフルアドレスが取れる。env var `ALLOW_LIST_ADDRESSES` を別途読んで `_passes_allow_list` に分岐を足す。実装サンプルは handler.py のコメント参照。

### Q6. 偽装メール (gmail を装う他社からの送信) はブロックできる?
できる。攻撃者の IP は gmail.com の SPF レコードに含まれず SPF FAIL、DKIM 秘密鍵を持たないので DKIM FAIL、結果 DMARC FAIL。Q2 の DMARC PASS 要求で auth 段階で reject される。Test 4 で Lambda invoke による疑似 payload で実証済 (`spfVerdict=FAIL / dkimVerdict=FAIL / dmarcVerdict=FAIL / dmarcPolicy=reject` で `WARN auth` 発火)。

### Q7. なぜ本物の SMTP で偽装テストしなかった?
多くの家庭 / オフィス ISP は **port 25 outbound を spam 対策で塞いでいる**。SES inbound endpoint は port 25 のみ受信なので、ローカル機 / 一般 EC2 からは SMTP 接続できない。AWS でやるなら EC2 で port 25 unblock 申請 (承認に数日)。代替として Lambda を SNS event 形式の payload で直接 invoke すれば、SES が verdict を FAIL で返したときの Lambda 側ロジックを厳密に検証可能 (Q6)。

### Q8. IP アドレスベースのフィルタもあると聞いたが?
**SES Receipt Filter** が classic にある。CIDR の block / allow リストをアカウント × region 単位で 100 件まで設定可能。SMTP 会話中に弾くので受信課金されない (Lambda にも到達しない)。本検証では terraform に書き方サンプルを残したが、デフォルト空配列で no-op。

### Q9. 完全ホワイトリスト化 (信頼する IP からだけ受ける) はできる?
`ip_block_list = ["0.0.0.0/0"]` + `ip_allow_list = ["信頼 IP の CIDR"]` で構成可能 (Q8 の延長)。ただし **メールサーバーの IP を事前把握するのが現実問題として困難** (Gmail / iCloud / Outlook はレンジ広く変動)。社内 SMTP リレーがある等、IP が固定で分かっているケース限定の手段。

### Q10. DMARC PASS を厳格にしすぎると何が困る?
DMARC 未設定の正当ドメイン (古い社内メールサーバー / 個人レンタルサーバー等) からのメールも GRAY で全部 reject される。実運用では「GRAY は WARN ログだけ出して通す」「SPF か DKIM のどちらかだけ PASS なら通す」など緩める判断が必要。本検証は厳しい側に倒した方針。

### Q11. 棄却されたメールはロストする?
**しない (01 アプローチ)**。Receipt Rule の archive-all (S3 deliver) が Lambda 検査の前段で実行されるので、すべての受信メールは S3 に生 MIME で保存される。誤判定があれば S3 から messageId で取り出して再処理可能。

ただし **02 アプローチ (strict-recipient-allowlist)** では catchall を撤廃したため、許可アドレス以外宛のメールは SES SMTP 中 reject で **そもそも S3 にも残らない**。Q14 のトレードオフ参照。

### Q15. 受信が大量に来たときに自動で止める仕組みは?
SES 自体に per-customer の inbound rate limit / throttle はない。代替として **CloudWatch アラーム → SNS → Lambda → `ses:SetActiveReceiptRuleSet()` (引数なし) で active rule set を解除** する killswitch パターンを実装する (03 approach)。発火後は全 inbound メールが SMTP 550 で reject される (= 課金されない)。SES Receipt Rule Set がアカウント × region singleton な点を逆手に取った構成。検知ラグは最低 1 分解像 + 評価ウィンドウ + 配信遅延で合計数分、その間の被害は許容する設計。復旧は手動で `aws ses set-active-receipt-rule-set` を呼ぶか `terraform apply -replace=...aws_ses_active_receipt_rule_set...` で再作成。

### Q16. 03 で使った `modules/ses-inbound` module は再利用できる?
できる。`name` / `domain` / `region` / `allowed_recipients` / `allow_list_domains` / `enable_killswitch` などを変数で渡すだけで同等の構成を別 sandbox / 別環境に展開可能。Lambda ソース (`processor` / `killswitch`) も module 内部 (`lambda/<function_name>/handler.py`) に同梱。本 sandbox 配下に置いてあるので、別 sandbox で再利用したいときは `sandboxes/20260516-ses-inbound-auth-allowlist/modules/ses-inbound/` をその sandbox にコピーして `source = "../../modules/ses-inbound"` で参照する運用 (リポジトリ root 直下の共有 module ディレクトリは作らない方針)。

### Q17. killswitch 発火時の復旧はどうする?
本検証は **手動復旧 + 通知強化** の方針。`slack_webhook_url` を module 変数で渡しておくと、alerts SNS topic 経由の全アラームが Slack に投稿される (notify Lambda)。メッセージ本文に復旧コマンド (`aws ses set-active-receipt-rule-set --rule-set-name <name>`) が含まれるので、Slack を見た人がコピペで CLI 実行 = 数秒で復旧。自動復旧は誤発火時の影響が大きいので本検証では実装せず。pingpong / cooldown 設計が必要な本格運用なら別途検討。

### Q14. 02 アプローチで課金を回避できる仕組みは?
SES の Receipt Rule は `recipients` 条件にマッチしない受信メールを **SMTP RCPT TO の段階で reject** (550) する。reject されたメールは:
- AWS SES の課金対象外 (IP Filter 由来の block と同じ扱い)
- CloudWatch メトリクス `Received` にもカウントされない
- Lambda 起動もしない (Lambda 課金もない)

代償として、不正な宛先 (`bbb@`, `random@`, `attacker@` 等) への送信試行が記録されない。攻撃検知や typo 検知 (誤送信元への通知) ができなくなる。「課金最小化」vs「監査ログ充実」のトレードオフ。

### Q12. Mail Manager (新サービス、2024 GA) は使わないの?
Mail Manager は Receipt Rule のネイティブ条件で From / Subject / DKIM verdict 等で分岐できてもっとリッチだが、**Ingress Endpoint の固定費用 (per hour)** が sandbox にはオーバーキル。本検証は「classic で同等のことをどこまでできるか」のスコープ。本格運用やヘッダ条件 / Address List (10万件) が必要なら Mail Manager 検討。

### Q13. スパム / ウイルス検査は?
Receipt Rule の `scan_enabled=true` で SES が自動評価し、`spamVerdict` / `virusVerdict` を notification に載せる。Lambda で FAIL なら reject (本検証は実装済、Test 1 で PASS を確認)。GRAY / PROCESSING_FAILED は過剰防御を避けて通す方針。
