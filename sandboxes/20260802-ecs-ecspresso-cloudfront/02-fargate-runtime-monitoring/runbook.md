# 02 GuardDuty ECS Fargate Runtime Monitoring — 条件 / 挙動 / 確認方法

> 検証日: 2026-08-27
> Region: ap-northeast-1 / Account: 654654512164(スタンドアロン)
> 目的: 別アカウント(管理アカウントから組織自動有効)で「Fargate のランタイム
> モニタリングが有効になっていない」と指摘を受けた。**必須条件**・**有効化時の挙動**・
> **本番向けの充足確認方法**を、単一アカウントで再現して確定する。

## 課題 / 前提

- GuardDuty Runtime Monitoring の ECS Fargate 対応は、**AWS 管理のサイドカーコンテナ**を
  タスクへ自動注入する方式(手動 agent は無い)。EC2/EKS と違い DaemonSet 等は不要。
- 指摘のアカウントは **private subnet + NAT なし**寄りの構成。ここで「有効にならない」
  典型原因は、サイドカーがテレメトリを送る **`guardduty-data` VPC endpoint** の欠如。
- 検証土台は 01(ecspresso + CloudFront)から監視観測に不要な層(CloudFront / ALB /
  VPC Origin / S3 frontend / OAC / CodeBuild / ecspresso)を全て削った最小版:
  **private VPC(NAT なし)+ VPC endpoint + Fargate service(LB なし・1 本)**。

## 必須条件チェックリスト(AWS 公式 doc 根拠)

1. **detector で feature を有効化**
   - `RUNTIME_MONITORING` = ENABLED、追加設定 **`ECS_FARGATE_AGENT_MANAGEMENT`** = ENABLED。
   - 有効化した「後に起動」した Fargate タスクにのみサイドカーが自動注入される。
2. **Fargate platform version >= 1.4.0(または LATEST)**。Windows 非対応。
   CPU は x86_64 / ARM64 どちらも対応。
3. **`guardduty-data` interface VPC endpoint**(`com.amazonaws.<region>.guardduty-data`)
   - **重要**: automated agent 有効時、この endpoint + 専用 SG + endpoint policy は
     **GuardDuty が自動作成する**(顧客が作らなくてよい。詳細は末尾「追加調査」節)。
   - 自動作成には VPC の `enableDnsSupport` / `enableDnsHostnames` が**両方 true**必須
     (でないと `VPC Endpoint Creation Failed` → coverage UNHEALTHY)。
   - 自動 SG は 443 ingress(VPC CIDR)。
   - 本 sandbox は挙動を確定的に観測するため endpoint を**あえて Terraform で明示管理**した
     (自動作成に依存しない。IaC 管理との関係も「追加調査」節参照)。
4. **サイドカー image の pull 経路**
   - image は AWS 管理 ECR にある。private VPC では `ecr.api` / `ecr.dkr` interface endpoint +
     `s3` gateway endpoint(レイヤ blob)への到達が必要。無いと `CannotPullContainerError`。
   - **task execution role** が必須(この role で pull する)。無いと
     `TaskExecutionRole missing from TaskDefinition`。
5. **有効化後に relaunch**:Fargate タスクはイミュータブル。有効化前から動いているタスク/
   サービスは覆われない。`aws ecs update-service --force-new-deployment` で入れ替える。
6. **クラスタ選択**:既定は「全クラスタ監視」。除外は cluster タグ `GuardDutyManaged=false`、
   選択監視は `GuardDutyManaged=true`。**除外タグは有効化前に付ける**(後付けだと一旦全タスクに
   付く)。
7. fail-open:サイドカーが起動できなくてもタスク自体は動く(coverage が UNHEALTHY + Issue に
   理由が出るだけ)。

## この sandbox の構成(最小版)

- `terraform/` … VPC(10.0.0.0/16, 2AZ private, NAT/IGW なし)/ route table /
  endpoints(`ecr.api` `ecr.dkr` `s3(gw)` `logs`)/ ECS cluster / exec・task role /
  ECR / taskdef(FARGATE, X86_64, cpu256/mem512, platformVersion=LATEST)/ service(LB なし, desired 1)。
- `terraform/modules/guardduty-runtime-monitoring/` … **監視の別モジュール**:
  detector(import)+ `RUNTIME_MONITORING`/`ECS_FARGATE_AGENT_MANAGEMENT` feature +
  `guardduty-data` endpoint + SG。
- `push-image.sh` … ローカルで nginx:alpine を build → 私有 ECR へ push(pull は Fargate が
  endpoint 経由)。`verify-coverage.sh` … 本番メンバー向け充足診断(read-only)。

### トグル(挙動の切り分け用)

- `enable_guardduty`(既定 true):false で監視モジュールごと作らない=「有効化前」状態。
- `create_guardduty_data_endpoint`(既定 true):false で **endpoint だけ欠かせて UNHEALTHY を再現**。

## 手順

```sh
export AWS_PROFILE=terraform AWS_REGION=ap-northeast-1
cd terraform
terraform init
# detector は account/region singleton。既存(disabled)を import してから apply する。
terraform import 'module.guardduty[0].aws_guardduty_detector.this' <detector-id>
terraform apply         # GuardDuty 有効化 + guardduty-data endpoint + ECS service
cd ..
./push-image.sh         # image push → force-new-deployment で新タスク起動
./verify-coverage.sh    # 充足診断(全 ✓ を確認)
# 後片付け(detector は削除せず DISABLED に戻す)
./cleanup.sh
```

## 有効化時の挙動(実観測 2026-08-27〜28)

### サイドカー自動注入(= エージェント導入)

feature 有効化(`UpdatedAt=2026-08-27T23:39:40`)後に起動したタスクの
`describe-tasks` で、コンテナが **`app` と `aws-guardduty-agent-XXXX` の 2 つ**になる:

```
$ aws ecs describe-tasks ... --query 'tasks[].containers[].name'
["app", "aws-guardduty-agent-T6VH2i"]   # platformVersion=1.4.0, ManagementType=AUTO_MANAGED
```

- タスク定義は書き換わらない(`ecs-gd-runtime:1` のまま)。GuardDuty が起動時に注入する。
- サイドカーは `RUNNING`(healthStatus=UNKNOWN はヘルスチェック未定義のため正常)。
- **per-task 操作は一切不要**。「有効化 → 条件を満たす新規タスク起動」だけで自動導入される。

### coverage の遷移(UNHEALTHY → HEALTHY)

`list-coverage` の `CoverageStatus` / `FargateDetails.Issues` は次の順で遷移した:

| 時刻 | status | Issue |
|------|--------|-------|
| 23:52 | UNHEALTHY | `Agent not provisioned : Service requires a new deployment to fix/troubleshoot ... 'ecs-gd-runtime'` |
| 〜00:07 | UNHEALTHY | `Agent not reporting : Agent not reporting, for task(s) in TaskDefinition ...` |
| **00:07:59** | **HEALTHY** | (Issues 空) |

- **coverage レコードは初回 UNHEALTHY で登場する**(有効化直後は "Agent not provisioned")。
- doc 通り **`force-new-deployment` で入れ替え** → その後テレメトリが安定するまで
  "Agent not reporting"(過渡) → **HEALTHY**。redeploy から HEALTHY まで **約14分**。
- 反映は速くない(サイドカー起動から HEALTHY まで数分〜十数分のラグ)。coverage が
  UNHEALTHY でも、`describe-tasks` にサイドカーが居れば「導入は成功・評価待ち」と切り分けられる。

### 別原因の切り分け(UNHEALTHY が続いたときに確認したこと)

redeploy 後も暫く UNHEALTHY だったため、ネットワーク/設定要因を全て確認 → **全て正常**、
残りは GuardDuty 評価ラグ、と切り分けられた(この順が本番でも有効):

- guardduty-data endpoint policy = full access(テレメトリ Deny 無し)
- endpoint State=available / PrivateDnsEnabled=true / SG 443 ingress 許可
- サイドカー注入継続・platformVersion 1.4.0・execution role あり・redeploy COMPLETED

### verify-coverage.sh を HEALTHY 状態で実行(スクリプトの裏取り)

```
$ ./verify-coverage.sh --cluster ecs-gd-runtime
  ✓ detector ENABLED / RUNTIME_MONITORING / ECS_FARGATE_AGENT_MANAGEMENT ENABLED
  ✓ 全リソース HEALTHY
  ✓ platformVersion / execution role / relaunch / サイドカー検出
  ✓ guardduty-data endpoint available / PrivateDns / SG443 / VPC DNS 属性
  PASS=12  FAIL=0  WARN=0  → 充足
```

同スクリプトを本番メンバーアカウントで流せば、同じ観点で「条件を満たしているか」を切り分けられる。

> 注: macOS 標準 bash 3.2 は連想配列非対応。verify-coverage.sh は 3.2 互換で書いた(VPC は
> スペース区切りリストで重複除去)。

### UNHEALTHY 再現(guardduty-data endpoint 欠如)— 実観測

```sh
terraform apply -var 'create_guardduty_data_endpoint=false'   # endpoint 削除
aws ecs update-service --cluster ecs-gd-runtime --service ecs-gd-runtime --force-new-deployment
```

- endpoint 削除 + relaunch(00:23:46)後、**約12分 HEALTHY のまま**(前の評価が残る)→
  **00:35:20 に UNHEALTHY へ遷移**。
- Issue: **`Agent not reporting : Agent not reporting, for task(s) in TaskDefinition -
  'ecs-gd-runtime:1'. Refer documentation`**
  = サイドカーは注入されるが、guardduty-data endpoint が無くテレメトリを送れない状態。
  private/NAT なし構成での典型症状。
- この状態で `verify-coverage.sh` は **FAIL=2**(coverage UNHEALTHY + endpoint 欠如)を出し、
  最終行が **「最有力候補: guardduty-data endpoint 欠如」** を正しく指した。診断の ✗ パスも裏取り済み。

> 反映ラグは HEALTHY→UNHEALTHY も同様に十数分。coverage status だけを見て即断せず、
> `describe-tasks`(サイドカー有無)と endpoint の実在を併せて見るのが確実。

## 単一アカウント(A=この sandbox) vs 管理アカウント一括自動有効(B=指摘案件)の仕様差

**ランタイム挙動(サイドカー自動注入・注入条件・タグ選択)は A/B で同一。**
B が違うのは「有効化の経路・スコープ・ロック」だけ。

| 観点 | A: 単一アカウント | B: 組織 / 委任管理者 |
|------|-------------------|----------------------|
| 誰が `ECS_FARGATE_AGENT_MANAGEMENT` を有効化 | アカウント自身 | **委任管理者のみ**(メンバーは変更不可) |
| 自動有効スコープ | — | `AutoEnable` = `NEW` / `ALL` / `NONE`(feature/追加設定ごと) |
| 既存 vs 新規メンバー | — | `NEW` は新規のみ(既存は非適用)。既存も覆うには `ALL` / 「既存メンバー一括有効」 |
| サイドカー注入の仕組み | 新規タスクへ自動 | **同一** |
| 注入の条件(上のチェックリスト) | 同じ | **同一** |
| `GuardDutyManaged` タグ選択 | 同じ | **同一**(+ タグ改変を SCP で保護推奨) |
| メンバーが無効化できるか | できる(自分の detector) | **不可(委任管理者がロック)** |
| `guardduty-data` endpoint | アカウント内 VPC ごとに自動 or 手動 | 同左。**shared VPC** は同一 Organization 必須 + `aws:PrincipalOrgID` の endpoint policy |
| coverage 確認 | `list-coverage`/`get-detector` | **メンバーからも同じコマンドで可** |

→ **この sandbox の単一有効化は、本番組織ケースの挙動をそのまま再現する有効な代理**。
`verify-coverage.sh` はメンバーアカウントで実行して「条件を満たしているか」を切り分けられる。

### 本番(B)で「有効になっていない」ときの切り分け順(verify-coverage.sh の観点)

1. detector / RUNTIME_MONITORING / ECS_FARGATE_AGENT_MANAGEMENT が ENABLED か。
2. 組織 `AutoEnable=NEW` で既存メンバーに未適用ではないか(→「既存メンバー一括有効」)。
3. `list-coverage` の UNHEALTHY と `Issue` 文言。
4. タスク VPC に `guardduty-data` endpoint があり available / PrivateDnsEnabled=true か。
5. VPC の DNS 属性(support/hostnames)両方 true か。
6. endpoint SG が 443 ingress を許可しているか。
7. Fargate platformVersion >= 1.4.0 / LATEST か。
8. task execution role があるか。
9. running task が**有効化より前**に起動していないか(→ relaunch)。
10. cluster が `GuardDutyManaged=false` で除外されていないか。
11. （メンバーから不可)SCP で `guardduty:SendSecurityTelemetry` が Deny されていないか等は
    管理アカウントで確認。

## 結論 / 学び

- **成立**(2026-08-27〜28 実機)。private VPC(NAT なし)+ guardduty-data endpoint で、
  有効化後に起動した Fargate タスクへ **サイドカー(`aws-guardduty-agent-*`)が自動注入**され、
  coverage が **HEALTHY** になるまでを確認。
- **「有効になっていない」の第一容疑は 2 つ**:
  1. **有効化を跨いだ既存サービス**:サイドカーは新規タスクにしか付かない。coverage は
     `Agent not provisioned : Service requires a new deployment` を出す。**対処は
     `aws ecs update-service --force-new-deployment`**(本番でまず打つ手)。
  2. **private/NAT なしで guardduty-data endpoint 欠如**:テレメトリを送れず UNHEALTHY。
- **サイドカー注入 ≠ coverage HEALTHY**:注入されていても、テレメトリ安定まで数分〜十数分
  UNHEALTHY(`Agent not reporting`)が続く。`describe-tasks` にサイドカーが居るかで
  「導入済み・評価待ち」か「本当に未導入」かを切り分けられる。
- **単一アカウント(A)と組織自動有効(B)の挙動は同一**。B の差は有効化経路・ロック・
  `AutoEnable` スコープ・shared VPC の endpoint policy のみ(下表)。よってこの sandbox は
  本番組織ケースの有効な代理で、`verify-coverage.sh` はメンバーアカウントでそのまま使える。
- **detector は account/region singleton**:Terraform 管理は既存を import。destroy で消すと
  GuardDuty ごと消えるため、cleanup は state rm + CLI で **DISABLED に戻す**(`cleanup.sh`)。

## 追加調査(2026-08-28): 自動リソース作成 と メンバー/管理アカウントの競合

「VPC endpoint 等が無い状態でマネコンから有効化すると自動で諸々設定される」「その手動
有効化で管理アカウントの自動設定が効かなくなる」「環境が整っていない状態で手動有効化 →
設定反映後に解除したら自動設定が適用されるか」という3点を doc で確認した(実機再検証なし)。

### ① 自動リソース作成 — **本当(TRUE)**

- `ECS_FARGATE_AGENT_MANAGEMENT` を ENABLED にすると、GuardDuty が **サービスリンクロール
  `AWSServiceRoleForAmazonGuardDuty`** 経由で、クラスタを持つ VPC ごとに次を**自動作成**する:
  - `com.amazonaws.<region>.guardduty-data` interface endpoint(VPC あたり 1 本)
  - その endpoint 専用の **security group**(VPC CIDR からの inbound)
  - endpoint policy(shared-VPC 時は `aws:PrincipalOrgID` scoped)
  - タスクへの **サイドカー**注入
- **console / API どちらでも同じ**(自動作成は「feature が有効」であることの性質)。
- private/NAT なしでも作成を**試みる**が、VPC の `enableDnsSupport`/`enableDnsHostnames` が
  両方 true でないと **作成失敗 → UNHEALTHY**(`VPC Endpoint Creation Failed`)。
- 作成トリガーは「agent 配置(= 新規タスク / 新規デプロイ)」に紐づく。既存サービスは
  `force-new-deployment` が要る。
- **ただし ECR pull 経路(ecr.api/ecr.dkr endpoint + s3 gw、または NAT)は自動作成されず
  顧客責任**のまま。ここが未整備だとサイドカー image を pull できず "Agent not reporting"。

> 本 sandbox との関係: 上記のとおり `guardduty-data` endpoint は本来 GuardDuty が自動作成する。
> 本 sandbox は挙動を確定させるため Terraform で明示管理した(自動作成に依存させない)。
> IaC で automated agent を扱う場合、GuardDuty が作る endpoint/SG と IaC の**ドリフト**に注意
> (AWS は IaC 併用の注意ページを用意している。関連リンク参照)。

### ② 手動有効化で管理アカウント設定が効かなくなる — **文書上 FALSE / 記載なし**

- 組織(委任管理者)配下では **メンバーはランタイムモニタリング/automated agent を自分で
  変更できない(ロック)**。docs 明記: *"A GuardDuty member account can't modify this
  configuration."* よって「メンバーの手動操作で管理アカウント設定がドリフト/無効化」は
  **前提が成立しない**(メンバーはそもそもトグルできない)。
- メンバーが触れるのは **クラスタ単位の除外タグ `GuardDutyManaged=false`** のみ(opt-out)。
- ※ スタンドアロン(組織外)アカウントなら「手動有効化」は通常の self-service。その場合は
  そもそも管理アカウント設定が存在しない。上記の心配は組織配下の話としては当たらない。

### ③ bootstrap→解除→自動適用 — **一部 TRUE だが実質不可/不要**

- endpoint の後始末には**非対称**がある:
  - **automated-agent サブ機能だけ無効化** → GuardDuty は endpoint/SG を**削除しない(残る)**。
    必要なら手動削除。
  - **Runtime Monitoring 全体を無効化** → endpoint/SG は**削除される**。
- ただし組織配下では ② のとおりメンバーがトグルできないので、「メンバーが bootstrap して
  解除し、あとは自動」という手順自体を**実行できない**。
- private VPC の正しい対処は「**VPC DNS 属性を両方 true にして自動作成を成功させる + ECR 経路を
  用意**」で、手動 endpoint bootstrap は文書化されていない(顧客が endpoint を作る唯一の
  正式パターンは **shared-VPC** の共有 endpoint フローのみ)。

### 実務の結論(本番の「有効になっていない」への当て方)

1. 対象 VPC の `enableDnsSupport`/`enableDnsHostnames` を**両方 true**にする(自動作成の前提)。
2. private/NAT なしなら **ECR endpoint(+ s3 gw)** を用意(自動作成されない・顧客責任)。
3. 有効化を跨いだ既存サービスは **`force-new-deployment`**。
4. これらが揃えば、管理アカウントの自動有効設定のまま `guardduty-data` endpoint は
   GuardDuty が自動作成し、coverage が HEALTHY になる。メンバー側で手動有効化する必要はない
   (そもそも組織配下では不可)。

## 未検証メモ(実機で未確認・要注意)

- **GuardDuty の guardduty-data endpoint 自動作成の実挙動**: 「先に作った顧客 endpoint を再利用」は
  DOCUMENTED(IaC ページ)で本 sandbox の 1 本観測とも整合。ただし**顧客が作らない場合に GuardDuty が
  新規自動作成する挙動**(private/NAT なし + DNS 属性 true で成功するか、作成タイミング= idle クラスタ
  / 最初のタスク起動時)は本 sandbox では未検証(常に先に自作したため)。
  併せて**顧客自作 endpoint が実際に課金されるか**(無料は GuardDuty 管理限定の読み)も実請求では未確認。
- **endpoint 削除後の自動再作成**: UNHEALTHY 再現で endpoint を Terraform で削除 → relaunch
  したが、観測した約12分の範囲では GuardDuty による自動再作成は起きず UNHEALTHY のままだった。
  自動再作成のトリガー/遅延は未確定(顧客が管理していた endpoint を消した扱いの可能性)。
- **具体 IAM action**: 自動作成は SLR `AWSServiceRoleForAmazonGuardDuty` 経由だが、
  `ec2:CreateVpcEndpoint` 等の個別 action は doc で明示確認できておらず推定。
- **Transit Gateway 集約構成**: 下記「TGW 集約構成での考察」を参照(doc 調査ベース・実機未検証)。

## TGW 集約構成での考察(interface endpoint を中央 VPC に集約する構成)

> doc 調査ベース(実機未検証)。結論: **`guardduty-data` は中央集約できない**が実害は小さい。

### 結論: guardduty-data の中央集約は非サポート(DOCUMENTED・明記あり)

GuardDuty Fargate の公式ページに直接の記述がある:

> "GuardDuty will create a VPC endpoint on your behalf **for all the VPCs. This includes the
> centralized VPC and spoke VPCs. GuardDuty doesn't support creating a VPC endpoint only for
> the centralized VPC.**"

- Fargate は automated agent が唯一のモードなので、GuardDuty が**各 spoke(ワークロード)VPC に
  `guardduty-data` endpoint を自動作成**する。中央 VPC 集約に寄せる・抑制する toggle は無い。
- PHZ + TGW の一般的な集約パターン(private DNS を切って自前 PHZ を spoke に関連付け、中央 ENI へ
  向ける)は S3/SSM/ECR 等では**有効(DOCUMENTED)**だが、**`guardduty-data` については doc silent
  = 非サポート扱い**。サイドカーが foreign VPC の endpoint 名を解決する正式手段は無い。

### ただし実害は小さい(コストの正確な整理)

- 無料は **GuardDuty が自動作成/管理する場合に限定**。Fargate ページは *"There is no additional
  cost for the usage of the VPC endpoint."*、**EKS ページはより明示的**に
  *"...no additional cost for the creation of the Amazon VPC endpoint **when you manage the security
  agent through GuardDuty.**"* と限定している。料金は Runtime Monitoring の vCPU 時間課金
  (`MonitoredVcpuHours`)側。
  - ⚠️ **顧客が自作した guardduty-data endpoint は無料の対象外と読むのが妥当**: 顧客所有の
    interface 型は通常の PrivateLink 課金(時間/AZ + データ処理)。自作課金の明示は **doc SILENT**
    だが反証記述なし・論理的に高信頼の推定。→ **無料にしたいなら GuardDuty 自動作成に任せる**。
  - ⚠️ 無料対象は guardduty-data のみ。ECR/S3/logs 等の顧客 endpoint は通常課金(集約動機は残る)。
- **GuardDuty は「先に作られた顧客 endpoint を再利用」する(DOCUMENTED)**: IaC ページに
  *"GuardDuty will not create its own VPC endpoint and will **reuse the one that you created** by
  using the IaC tool."*。条件は**順序**: endpoint を作ってから automated agent config を有効化する。
  → IaC 自前管理は可能(重複しない)だが、その endpoint は課金対象になりうる。本 sandbox で
  guardduty-data が **1 本だけ**だった観測とも整合(= 本 sandbox の自作 endpoint は無料対象外だった
  可能性が高い)。
- GuardDuty の自動 SG は各 VPC の**ローカル CIDR**に inbound を張る(CIDR 変化に追従)。外部 spoke
  CIDR からの流入は想定しない = そもそも集約前提の設計ではない。

### RAM 共有 VPC とは別物(混同しない)

- **RAM 共有 subnet の VPC**(同一 Organization)なら **単一の共有 endpoint** を持てる
  (owner が automated 有効化、org-scoped `aws:PrincipalOrgID` policy を GuardDuty が付与)。
  ただしこれは「ワークロードが共有 VPC 内で動く」ケースで、endpoint は**ワークロードと同一 VPC に
  ローカル**。TGW ハブ&スポーク(spoke は別 VPC・中央 VPC の endpoint を TGW 越しに使う)とは
  根本的に異なる。GuardDuty がサポートするのは前者のみ。

### 実運用ガイダンス(TGW 集約 landing zone で Fargate + GuardDuty)

1. `guardduty-data` は集約しない。**各ワークロード VPC に GuardDuty 自動作成させる**
   (前提: その VPC の `enableDnsSupport`/`enableDnsHostnames` が両方 true。追加コストなし)。
2. **ECR / S3 / logs 等はこれまで通り TGW 集約可**。GuardDuty サイドカー image は AWS 管理 ECR
   から pull されるので、集約 endpoint 経由でも「ECR への到達性」さえ担保すればよい
   (= 顧客責任の pull 経路。ここは集約設計に載せられる)。
3. IaC(Terraform/CDK)併用時: GuardDuty が作る endpoint/SG が subnet の依存になり、
   subnet/VPC 削除が `DependencyViolation` になる。**Runtime Monitoring を無効化してから**
   teardown する順序にする。
4. どうしても単一共有 endpoint にしたいなら、TGW ではなく **RAM 共有 VPC** 設計を選ぶ
   (ワークロードを共有 VPC で動かす)。

### documented / inferred / silent の別

- **DOCUMENTED**: 中央 VPC 単独 endpoint は非サポート・全 VPC に自動作成 / RAM 共有 VPC は別で
  サポート / GuardDuty SG はローカル CIDR / **GuardDuty 管理 endpoint は無料**(EKS ページが
  "when you manage the security agent through GuardDuty" と限定明示) / **先に作った顧客 endpoint は
  GuardDuty が再利用**(順序: 作成→有効化) / IaC 依存の teardown 注意。
- **INFERRED/SILENT**: **顧客自作 endpoint の課金は明示なし**(通常 PrivateLink 課金と推定・高信頼) /
  「無料」が PrivateLink 時間/データ課金の waive を指すかの分解は SILENT。
- **INFERRED**: この単純な request/response フローに TGW appliance-mode は不要(一般挙動からの推定)。
- **SILENT(前提にしない)**: `guardduty-data` を PHZ で中央 endpoint に向ける手段 / GuardDuty 固有の
  MTU 制約。

## 関連リンク

- [How Runtime Monitoring works — ECS Fargate](https://docs.aws.amazon.com/guardduty/latest/ug/how-runtime-monitoring-works-ecs-fargate.html)
- [Prerequisites — ECS Fargate](https://docs.aws.amazon.com/guardduty/latest/ug/prereq-runtime-monitoring-ecs-support.html)
- [Managing the automated agent for ECS Fargate](https://docs.aws.amazon.com/guardduty/latest/ug/managing-gdu-agent-ecs-automated.html)
- [Assess coverage / troubleshoot — ECS](https://docs.aws.amazon.com/guardduty/latest/ug/gdu-assess-coverage-ecs.html)
- [Validate VPC endpoint config](https://docs.aws.amazon.com/guardduty/latest/ug/validate-vpc-endpoint-config-runtime-monitoring.html)
- [Runtime Monitoring with shared VPC](https://docs.aws.amazon.com/guardduty/latest/ug/runtime-monitoring-shared-vpc.html)
- [How it works — ECS Fargate(endpoint/SG 自動作成)](https://docs.aws.amazon.com/guardduty/latest/ug/how-runtime-monitoring-works-ecs-fargate.html)
- [IaC と automated agent の併用(endpoint 自動作成 と ドリフト)](https://docs.aws.amazon.com/guardduty/latest/ug/using-iac-with-gdu-automated-agents-runtime-monitoring.html)
- [agent リソースの後始末(無効化時の endpoint 削除有無)](https://docs.aws.amazon.com/guardduty/latest/ug/runtime-monitoring-agent-resource-clean-up.html)
- [複数アカウント環境で有効化(メンバーは変更不可)](https://docs.aws.amazon.com/guardduty/latest/ug/enable-runtime-monitoring-multiple-acc-env.html)
- [Centralized access to VPC private endpoints(PHZ + TGW 集約パターン; guardduty-data は対象外)](https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/centralized-access-to-vpc-private-endpoints.html)
