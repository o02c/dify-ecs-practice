# =========================================================================
# デプロイ用 CodeBuild (VPC モード) — ECR push / フロント S3 配置 / ecspresso deploy
#
# 方針: ビルド (backend image / front 資材) はローカルで済ませ、成果物一式を
#       deploy.zip で S3 に置く。CodeBuild(VPC モード, インターネット不通)が取り、
#         1. docker load → ECR push
#         2. assets/ を frontend S3 バケットへ sync
#         3. ecspresso deploy (taskdef 登録 + service 更新)
#       を全て VPC Endpoint 経由で実行する (buildspec.yml 参照)。
#
# deploy.zip の中身 (runbook 参照):
#   image.tar               … docker save した backend image (local tag app:latest)
#   assets/                 … S3 に置くフロント資材
#   ecspresso/*.yml,*.json  … tfstate は S3 remote backend を url: で参照
#   bin/ecspresso           … linux/amd64 バイナリ (VPC 内無通信のため同梱)
#
# VPC Endpoint は endpoints.tf に集約。ecspresso 用の ecs/elb/sts/appautoscaling も含む。
# =========================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # state を置く remote backend バケット。backend.tf / ecspresso.yml と同一 (backend 設定は
  # 変数を取れないためハードコードで揃える)。IAM の tfstate 読取権限で参照する。
  tfstate_bucket_arn = "arn:aws:s3:::ecs-ecspresso-cf-tfstate-example"

  # CodeBuild が書く CloudWatch Logs グループ (logs_config と一致)。
  codebuild_log_group_arn = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/codebuild/${var.sandbox_name}"
}

# ---- ビルド成果物 (deploy.zip) 置き場 ---------------------------------
resource "aws_s3_bucket" "source" {
  bucket_prefix = "${var.sandbox_name}-source-"
  force_destroy = true

  tags = { Name = "${var.sandbox_name}-source" }
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket = aws_s3_bucket.source.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---- CodeBuild SG (VPC モード。egress で各 Endpoint へ) ----------------
resource "aws_security_group" "codebuild" {
  name        = "${var.sandbox_name}-codebuild"
  description = "CodeBuild VPC mode egress to VPC endpoints"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-codebuild" }
}

resource "aws_vpc_security_group_egress_rule" "codebuild_all" {
  security_group_id = aws_security_group.codebuild.id
  description       = "to VPC endpoints (ECR/S3/logs/ECS/autoscaling)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# CodeBuild からの 443 は endpoints SG の "VPC CIDR ingress" で既に許可済み。

# ---- IAM (CodeBuild service role) -------------------------------------
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.sandbox_name}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json

  tags = { Name = "${var.sandbox_name}-codebuild" }
}

data "aws_iam_policy_document" "codebuild" {
  # deploy.zip (source バケット) の取得
  statement {
    sid       = "SourceRead"
    actions   = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]
  }

  # ecspresso が読む tfstate (S3 remote backend)
  statement {
    sid       = "TfstateRead"
    actions   = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = [local.tfstate_bucket_arn, "${local.tfstate_bucket_arn}/*"]
  }

  # フロント資材の S3 配置
  statement {
    sid       = "FrontendWrite"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
  }

  # ECR: 認証トークン取得は resource 指定不可のため * 固定
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR: layer/push 操作は対象 repo に限定
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload"
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # ecspresso deploy (taskdef 登録 + service 更新 + v2.8 の deploy 完了待ち API)
  statement {
    sid = "EcsDeploy"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:DescribeClusters",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:TagResource",
      "ecs:ListServiceDeployments",
      "ecs:DescribeServiceDeployments",
      "ecs:DescribeServiceRevisions"
    ]
    resources = ["*"] # RegisterTaskDefinition 等は resource 指定不可
  }

  # ecspresso が status 表示で叩く Describe (autoscaling 未設定でも呼ぶ)。
  # elasticloadbalancing / sts は v2.8.4 の deploy では未使用と実機確認済みのため付与しない。
  statement {
    sid       = "AutoscalingDescribe"
    actions   = ["application-autoscaling:Describe*"]
    resources = ["*"]
  }

  # RegisterTaskDefinition / CreateService で task role を渡す
  statement {
    sid       = "PassEcsRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task_execution.arn, aws_iam_role.task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.codebuild_log_group_arn, "${local.codebuild_log_group_arn}:*"]
  }

  # VPC モードの ENI 作成に必要
  statement {
    sid = "VpcEni"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      "ec2:CreateNetworkInterfacePermission"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.sandbox_name}-codebuild"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

# ---- CodeBuild project (VPC モード, deploy 一式) -----------------------
resource "aws_codebuild_project" "deploy" {
  name         = "${var.sandbox_name}-deploy"
  service_role = aws_iam_role.codebuild.arn

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.source.id}/deploy.zip"
    buildspec = file("${path.module}/buildspec.yml")
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "FRONTEND_BUCKET"
      value = aws_s3_bucket.frontend.bucket
    }
  }

  vpc_config {
    vpc_id             = aws_vpc.this.id
    subnets            = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.codebuild.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/codebuild/${var.sandbox_name}"
    }
  }
}
