# 01-fargate-ecspresso

Terraform で「土台」(VPC / ECS cluster / IAM / SG / ALB / VPC Origin / CloudFront / S3 / ECR / VPC Endpoints / CodeBuild) を作り、
**ビルドはローカル、ECR push・フロント資材の S3 配置・ecspresso deploy(taskdef + service)は CodeBuild(VPC モード)** が担う。
CloudFront は **1 本**で `/*` → S3(OAC)、`/api/*` → VPC Origin → ALB → ECS Fargate に分岐する。

## 概要

```
[ローカル] build only                 [S3]              [CodeBuild(VPC, no internet)]        [AWS]
 docker build ─▶ docker save ─┐
 assets/ (front)              ├─▶ deploy.zip ─▶ source バケット ─▶ CodeBuild:
 ecspresso/ (定義)            │                                     1. docker load ─▶ ECR push
 bin/ecspresso (linux)  ──────┘                                     2. assets ─▶ frontend S3 sync
                                                                    3. ecspresso deploy ─▶ ECS
                                                                    (全て VPC Endpoint 経由)

                    ┌──────────── CloudFront (1 distribution) ────────────┐
 viewer ─HTTPS──▶   │  /*     ─▶ S3 origin (OAC)          … 静的フロント   │
                    │  /api/* ─▶ VPC Origin ─▶ ALB(internal) ─▶ ECS task  │
                    └─────────────────────────────────────────────────────┘
```

- **ビルド = ローカル**(インターネットあり)。ベースイメージ pull もフロント生成もローカルで完結。
- **ECR/ECS 操作・フロント配置 = CodeBuild**。VPC モード(インターネット不通)で、成果物を持ち込んで endpoint 経由のみで実行。
- Terraform は service/taskdef を作らない。ecspresso が tfstate プラグインで **S3 remote backend の state** を参照(ローカルでも CodeBuild でも同じ config)。

## 前提

- `AWS_PROFILE=terraform` (このリポジトリ既定) / リージョン: ap-northeast-1 (VPC Origins サポート)
- ローカルツール: `docker`, `terraform`, `aws` CLI(ecspresso はローカル実行不要。CodeBuild が回す)
- ローカルからインターネットに到達できること(イメージ build・成果物 push 用)
- **state 用 S3 バケットを事前作成**(remote backend の bootstrap)。名前は `backend.tf` /
  `ecspresso.yml` / `codebuild.tf` の IAM とハードコードで揃えている(`ecs-ecspresso-cf-tfstate-example`):

```sh
aws s3api create-bucket --bucket ecs-ecspresso-cf-tfstate-example --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
aws s3api put-bucket-versioning --bucket ecs-ecspresso-cf-tfstate-example \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket ecs-ecspresso-cf-tfstate-example \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

## 手順

### 1. Terraform apply (土台)

```sh
cd terraform
terraform init          # S3 backend を初期化 (state は remote)
terraform apply
```

CloudFront VPC Origin + distribution の作成で **~7-10 分**かかる。完了後 `terraform output` で
`cloudfront_domain` / `ecr_repository_url` / `s3_bucket`(frontend) / `source_bucket` / `codebuild_project` を確認。

### 2. デプロイ成果物 (deploy.zip) をローカルで組む

zip の中身: `image.tar` + `assets/` + `ecspresso/` + `bin/ecspresso`(linux/amd64)。

```sh
STAGE=$(mktemp -d)
mkdir -p "$STAGE/bin" "$STAGE/assets" "$STAGE/ecspresso"

# 2-1. backend image を build (Fargate は X86_64。attestation なし。local tag=app:latest 固定)
docker build --provenance=false --platform linux/amd64 -t app:latest app
docker save app:latest -o "$STAGE/image.tar"

# 2-2. フロント資材と ecspresso 定義
cp assets/index.html            "$STAGE/assets/"
cp ecspresso/ecspresso.yml ecspresso/ecs-service-def.json ecspresso/ecs-task-def.json "$STAGE/ecspresso/"

# 2-3. ecspresso の linux/amd64 バイナリを同梱 (VPC 内は無通信なので持ち込む)
V=2.8.4
curl -sSL -o /tmp/ecspresso.tgz \
  "https://github.com/kayac/ecspresso/releases/download/v$V/ecspresso_${V}_linux_amd64.tar.gz"
tar -xzf /tmp/ecspresso.tgz -C "$STAGE/bin" ecspresso

# 2-4. zip 化して source バケットへ (アップロードはマネコンでも可)
( cd "$STAGE" && zip -qr deploy.zip image.tar assets ecspresso bin )
SRC=$(terraform -chdir=terraform output -raw source_bucket)
aws s3 cp "$STAGE/deploy.zip" "s3://$SRC/deploy.zip"
```

### 3. CodeBuild を実行 (ECR push + フロント S3 配置 + ecspresso deploy)

```sh
PROJECT=$(terraform -chdir=terraform output -raw codebuild_project)
BID=$(aws codebuild start-build --project-name "$PROJECT" --query 'build.id' --output text)
until [ "$(aws codebuild batch-get-builds --ids "$BID" \
  --query 'builds[0].buildStatus' --output text)" != "IN_PROGRESS" ]; do sleep 10; done
aws codebuild batch-get-builds --ids "$BID" --query 'builds[0].buildStatus' --output text
# => SUCCEEDED なら push / front sync / ecspresso deploy まで完了
```

> buildspec は Terraform 側 (`codebuild.tf`) に inline。VPC モードは ENI 作成で PROVISIONING に ~30-40 秒。
> ログは `aws logs tail /codebuild/ecs-ecspresso-cf --follow`。

### 4. 疎通確認

```sh
DOMAIN=$(terraform -chdir=terraform output -raw cloudfront_domain)
curl -s "https://$DOMAIN/"        # S3 のフロント (default /*)
curl -s "https://$DOMAIN/api/"    # ECS backend (VPC Origin 経由)
```

`/` が S3 の index.html、`/api/` が ECS の応答なら「別経路(パス分岐)」成立。

### 5. cleanup

`cleanup.sh` に一括化してある。①ECS service 削除(ecspresso 管理 = state 外)→ ②`terraform destroy`
(CloudFront disable で ~20 分)→ ③state バケット(versioning 有効・terraform 管理外)を全 version
削除して `rb`、の順で実行する。

```sh
AWS_PROFILE=terraform ./cleanup.sh
```

> 手動でやる場合も順序は同じ。service を先に消さないと ECS cluster を destroy できない。
> state バケットは backend の bootstrap で terraform 管理外なので最後に別途削除する。

## メモ / 注意点

- **VPC BPA**: VPC BPA on だと VPC Origin は mode を問わず 504([[cloudfront_vpc_origin_bpa]])。
  `enable_vpc_bpa_exclusion = true` で ALB/task の両 subnet を exclusion して疎通復活。
- **CloudFront は遅い**: apply ~10 分 / destroy ~20 分。
- **VPC Endpoint(最小セット = interface 5 本 + s3 Gateway)**: 下記「必要性の実機切り分け」参照。
  `disable_interface_endpoints` 変数で 1 本ずつ外して検証した結果、`sts` / `elasticloadbalancing`
  は v2.8.4 の deploy では未使用だったため default から除外済み。
- **state は S3 remote backend**: CodeBuild 上の ecspresso が同じ state を参照できるようにするため。
  ローカル state だと CodeBuild から見えない。
- **taskdef の CPU アーキ**: `runtimePlatform=X86_64` なので `docker build --platform linux/amd64`。
  arm64 に寄せるなら taskdef を `ARM64` + `--platform linux/arm64`。

## VPC Endpoint 必要性の実機切り分け (2026-08-02, ecspresso v2.8.4)

`disable_interface_endpoints` で 1 本ずつ外し、CodeBuild deploy の成否と所要時間で判定した結果。
baseline(全部あり)= 157s。

| endpoint | 種別 | 必要性 | 外した時の実測 |
|---|---|---|---|
| `s3` | Gateway | **必須** | ECR layer / deploy.zip / frontend sync / tfstate。未検証だが構造上必須(無料) |
| `ecr_api` | Interface | **必須** | docker login/auth。未破壊検証(pre_build で login 失敗するため自明) |
| `ecr_dkr` | Interface | **必須** | layer pull/push。同上 |
| `logs` | Interface | **必須** | Fargate awslogs + CodeBuild ログ。同上 |
| `ecs` | Interface | **必須** | **外すと即 FAILED**(`DescribeServices ... i/o timeout`、ecspresso 開始直後に停止) |
| `application-autoscaling` | Interface | **任意** | 外しても SUCCEED だが **270s(+113s)**。`DescribeScalableTargets` が 3 回リトライで timeout(WARN)。status 表示用で非致命 |
| `sts` | Interface | **不要** | 外しても 188s(誤差)・エラー無し。deploy 中に `GetCallerIdentity` を呼ばない → **default から除外** |
| `elasticloadbalancing` | Interface | **不要** | 外しても 177s(誤差)・エラー無し。完了待ちは `ecs:ListServiceDeployments` 経由で ELB API 未呼出 → **default から除外** |

- **最小構成の結論**: 必須 = `s3`(gw) + `ecr_api` + `ecr_dkr` + `logs` + `ecs`。`application-autoscaling`
  は「無いと毎回 ~110s 遅くなる」ので実用上は入れる(default 採用)。`sts` / `elasticloadbalancing` は除外。
- **注意**: ecr/s3/logs は破壊検証していない(外せば対応ステップが自明に失敗する)。ecspresso の
  バージョンが上がると `sts` / `elasticloadbalancing` を呼ぶ可能性はあるので、その時は map に戻す。
- 再検証コマンド例: `terraform apply -var='disable_interface_endpoints=["appautoscaling"]'` → CodeBuild 実行 → 復元。

## ecspresso テンプレート / S3 tfstate の落とし穴 (実機で踏んだもの)

1. **`tfstate` 関数は ecspresso.yml 本体では使えない**(plugin ロード順)。`cluster` / `region` は静的に書き、
   tfstate 参照は `ecs-service-def.json` / `ecs-task-def.json` の中だけに置く。
2. **デフォルト値は `{{ env `X` `Y` }}`**。`{{ must_env `X` | default `Y` }}` は `default` 未登録でエラー。
3. **map 要素の tfstate アドレスは `aws_subnet.private["a"].id`**。JSON 内でも `\"a\"` に escape しない
   (ecspresso はテキスト展開 → 後で JSON 解釈するため。escape すると `... is not found in tfstate`)。
4. **S3 remote state は `path:` ではなく `url:`** で渡す。`path: s3://...` だと `s3://` が
   ファイルパス扱いで `s3:/` に潰れ、HeadBucket 405 になる。
5. **CodeBuild で ecspresso を回すなら IAM に新 deployment API が要る**:
   `ecs:ListServiceDeployments` / `DescribeServiceDeployments` / `DescribeServiceRevisions`
   (v2.8 の deploy 完了待ちで使用)。加えて autoscaling 未設定でも `DescribeScalableTargets` を
   叩くので `application-autoscaling` endpoint + `Describe*` 権限が無いと 90s タイムアウトする。
