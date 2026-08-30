# ECS(ecspresso) + CloudFront — フロント S3 / バックエンド VPC Origin をパスで別経路配信

> 検証日: 2026-08-02
> Obsidian: [[TODO]]

## 背景 / 課題

これまでのリポジトリには「S3 zip → CodeBuild → ECR push」([`20260412-ecr-push-without-internet`](../20260412-ecr-push-without-internet))
と「CloudFront VPC Origin 最小構成」([`20260602-cloudfront-vpc-origin-minimal`](../20260602-cloudfront-vpc-origin-minimal))
の資産がある。これらを踏まえ、**運用に近い ECS 配信の型**を1つ確立したい。狙いは3点:

1. **Terraform と ecspresso の責務分離** — Terraform は土台(cluster / IAM / SG / ネットワーク /
   ALB / CloudFront / S3 / ECR)まで、ECS の **task definition と service(サービス以下)は ecspresso**。
2. **フロントとバックエンドを 1 本の CloudFront で「別経路(パス)」に分ける** —
   `/*` は S3(静的フロント / OAC)、`/api/*` は VPC Origin → private ALB → ECS Fargate。
3. 既存の VPC Origin / ECR / VPC Endpoint パターンを流用し作法を揃える。

## 仮説

- ecspresso の **tfstate プラグイン**で `terraform.tfstate` を直接参照すれば、cluster 名 / subnet /
  SG / TG ARN / ECR URL / log group を二重定義せずに taskdef・service に注入できる
- **1 CloudFront に S3 origin(OAC)と VPC Origin(ALB)の 2 origin** を持たせ、`ordered_cache_behavior`
  で `/api/*` だけ VPC Origin に振れば、フロントとバックエンドを別経路で配信できる
- Fargate は private subnet + VPC Endpoints(ecr.api / ecr.dkr / s3 gw / logs)で NAT なしに image pull できる

## 検証環境

- Region: `ap-northeast-1`(VPC Origins サポート、`apne1-az3` を除外)
- AWS Profile: `terraform`
- backend: Fargate(X86_64, cpu 256 / mem 512)+ nginx:alpine(`/` health, `/api/` 応答)
- frontend: S3 静的 index.html(OAC 経由)
- 想定コスト: ALB 常駐 + CloudFront + VPC Interface Endpoint × 3。検証 1 セット(~1h)で $0.2 未満程度

## Approach

| #  | Approach            | 概要                                                                                              | 結果    |
|----|---------------------|---------------------------------------------------------------------------------------------------|---------|
| 01 | fargate-ecspresso   | TF=土台 / ecspresso=taskdef+service。1 CloudFront で `/*`→S3(OAC)、`/api/*`→VPC Origin→ALB→Fargate。イメージは CodeBuild(VPC)で S3 zip → load → ECR push | 成功 |
| 02 | fargate-runtime-monitoring | GuardDuty ECS Fargate ランタイムモニタリングの必須条件・有効化時の挙動・充足確認方法を、01 から監視観測に不要な層を削った最小版(private Fargate)で実機検証。監視は別モジュール + `verify-coverage.sh` 診断。 | 成功 |

詳細は [`01-fargate-ecspresso/runbook.md`](01-fargate-ecspresso/runbook.md) /
[`02-fargate-runtime-monitoring/runbook.md`](02-fargate-runtime-monitoring/runbook.md) を参照。

## 結論 / 学び

- **成立**(2026-08-02 実機)。1 CloudFront distribution で `/` → S3(OAC, HTTP 200)、`/api/` → VPC Origin → ALB → Fargate(HTTP 200)を確認。フロント/バックエンドの「別経路(パス分岐)」が同一 distribution で成り立つ。
- **責務分離は tfstate プラグインで綺麗に決まる**: Terraform(34 リソース)が土台、ecspresso が taskdef+service。subnet/SG/TG ARN/ECR URL/log group/role をすべて `terraform.tfstate` 参照で注入でき、二重定義ゼロ。
- **apply は CloudFront がボトルネック**: 全体で ~7 分(distribution 単体で 4m35s、VPC Origin 含む)。Fargate は private + VPC Endpoint で image pull 成功(NAT 不要)。
- **デプロイ操作(ECR push / フロント S3 配置 / ecspresso deploy)を CodeBuild(VPC モード)に集約**: ローカルは build のみ。成果物(`image.tar` + `assets/` + `ecspresso/` + `bin/ecspresso`)を `deploy.zip` にして S3 に置くと、CodeBuild が ①`docker load`+ECR push ②`assets/` を frontend S3 へ sync ③`ecspresso deploy` を **全て VPC Endpoint 経由(インターネット不通)** で実行。ベースイメージ pull はローカルで完結するので VPC 内は無通信で成立。CodeBuild SUCCEEDED → `/` `/api/` とも HTTP 200 まで確認。`docker build`(Dockerfile ビルド)ではなく **持ち込み(load+push)方式**なので、ベースイメージの private 事前登録(20260412 の課題)が不要。
- **CodeBuild で ecspresso を air-gapped に回すには追加ピースが要る**: ①ecspresso が読む state を **S3 remote backend** 化(ローカル state は CodeBuild から見えない)、ecspresso は `url: s3://...` で参照。②VPC 内無通信なので ecspresso の linux バイナリを zip に**同梱**。③ecspresso が叩く API 用に interface endpoint を追加。④IAM に v2.8 の `ecs:ListServiceDeployments` 系と `application-autoscaling:Describe*`、`iam:PassRole`。
- **VPC Endpoint は実機で必要性を切り分けて最小化**(`disable_interface_endpoints` で 1 本ずつ外して検証): 必須は **`s3`(gw) + `ecr_api` + `ecr_dkr` + `logs` + `ecs`**。`ecs` を外すと即 FAILED(`DescribeServices` timeout)。`application-autoscaling` は外しても成功するが毎回 ~110s 遅くなる(status 表示の `DescribeScalableTargets` retry)ので採用。**`sts` / `elasticloadbalancing` は v2.8.4 の deploy では未使用と実証したので除外**(interface 7 → 5 本に削減)。詳細表は runbook 参照。
- **ecspresso テンプレートの落とし穴**(runbook 参照):
  1. `tfstate` 関数は **ecspresso.yml 本体では使えない**(plugin ロード順)。cluster/region は静的に書き、tfstate 参照は service/task definition の JSON 側だけにする。
  2. デフォルト値は `{{ must_env `X` | default `Y` }}` ではなく **`{{ env `X` `Y` }}`**(sprig `default` は未登録)。
  3. map 要素の tfstate アドレスは **`aws_subnet.private["a"].id`**(JSON 内でもバックスラッシュ escape 不要。ecspresso はテキストとしてテンプレート展開してから JSON 解釈するため)。

## 関連リンク

- [ecspresso](https://github.com/kayac/ecspresso) / [tfstate plugin](https://github.com/kayac/ecspresso#tfstate)
- [Restrict access with VPC origins (CloudFront Dev Guide)](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
- [Restricting access to an S3 origin with OAC](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)
- 関連 sandbox: [`20260602-cloudfront-vpc-origin-minimal`](../20260602-cloudfront-vpc-origin-minimal) / [`20260412-ecr-push-without-internet`](../20260412-ecr-push-without-internet)
