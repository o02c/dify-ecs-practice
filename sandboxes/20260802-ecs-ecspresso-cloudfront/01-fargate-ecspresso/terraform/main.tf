# =========================================================================
# ECS(ecspresso) + CloudFront 配信の「土台」を Terraform で作る
#
# 責務分離:
#   - Terraform: VPC / ECS cluster / IAM / SG / ALB / VPC Origin / CloudFront
#                / S3(フロント) / ECR / VPC Endpoints まで
#   - ecspresso: task definition と ECS service(= サービス以下)。ここでは作らない。
#     ecspresso は tfstate プラグインで本 state の値(cluster 名 / subnet / SG /
#     TG ARN / ECR URL / log group)を参照する。
#
# 配信経路(1 CloudFront distribution / 2 origin / 2 behavior):
#   - default /*   -> S3 origin (OAC)            … 静的フロント
#   - /api/*       -> VPC Origin -> ALB(internal) -> ECS Fargate task
# =========================================================================

data "aws_availability_zones" "available" {
  state = "available"
  # ap-northeast-1 で VPC Origins 非対応の AZ (apne1-az3) を除外
  filter {
    name   = "zone-id"
    values = ["apne1-az1", "apne1-az2", "apne1-az4"]
  }
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# VPC Origin (ALB) に Host / クエリ等を素通しするための managed policy
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# ---- VPC / subnet / route --------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.sandbox_name }
}

# VPC Origins の prerequisite。attach のみで route table には載せない (= 実質 private)。
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.sandbox_name }
}

# ALB の HA 要件 + Fargate 配置で 2 AZ private subnet
resource "aws_subnet" "private" {
  for_each = toset(["a", "b"])

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.key == "a" ? "10.0.1.0/24" : "10.0.2.0/24"
  availability_zone = each.key == "a" ? data.aws_availability_zones.available.names[0] : data.aws_availability_zones.available.names[1]

  tags = { Name = "${var.sandbox_name}-private-${each.key}" }
}

# S3 Gateway Endpoint の route 注入先。NAT は張らない (local route のみ)。
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.sandbox_name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# VPC Endpoints (Gateway s3 + Interface 一式) は endpoints.tf に集約。
# route table (aws_route_table.private) は s3 Gateway endpoint の注入先として
# endpoints.tf から参照される。

# ---- Security Groups (2 段: ALB / task) -------------------------------
# ALB SG: CloudFront service-managed SG からの ingress のみ
resource "aws_security_group" "alb" {
  name        = "${var.sandbox_name}-alb"
  description = "CloudFront to ALB (HTTP 80)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cf" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP from CloudFront service-managed SG"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origin_service.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_task" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to Fargate task"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.task.id
}

# task SG: ALB SG からの ingress。egress は ECR/logs endpoint (443) + S3 用に全許可。
resource "aws_security_group" "task" {
  name        = "${var.sandbox_name}-task"
  description = "ALB to Fargate task (HTTP 80)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-task" }
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "HTTP from ALB SG"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "task_egress_all" {
  security_group_id = aws_security_group.task.id
  description       = "to VPC endpoints (ECR/logs 443) and S3"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- ECS cluster (土台。service/taskdef は ecspresso) ------------------
resource "aws_ecs_cluster" "this" {
  name = var.sandbox_name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Name = var.sandbox_name }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.sandbox_name}"
  retention_in_days = 7

  tags = { Name = var.sandbox_name }
}

# ---- IAM (task execution role / task role) ----------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 実行ロール: ECR pull + CloudWatch Logs 書き込み (AWS managed policy で充足)
resource "aws_iam_role" "task_execution" {
  name               = "${var.sandbox_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${var.sandbox_name}-exec" }
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# タスクロール: アプリ用。今回は最小 (追加権限なし)。
resource "aws_iam_role" "task" {
  name               = "${var.sandbox_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${var.sandbox_name}-task" }
}

# ---- ALB (internal, 2 AZ) + Target Group (ip) -------------------------
resource "aws_lb" "this" {
  name               = var.sandbox_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.private : s.id]

  tags = { Name = var.sandbox_name }
}

# Fargate(awsvpc) は target_type = "ip"。登録は ecspresso の service が担う。
resource "aws_lb_target_group" "this" {
  name        = var.sandbox_name
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = var.sandbox_name }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# ---- CloudFront VPC Origin (ALB ARN を指す) ---------------------------
resource "aws_cloudfront_vpc_origin" "this" {
  vpc_origin_endpoint_config {
    name                   = var.sandbox_name
    arn                    = aws_lb.this.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# CloudFront service-managed SG (VPC scoped, 1 per VPC)。ALB SG ingress の参照元。
data "aws_security_group" "cloudfront_vpc_origin_service" {
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG"]
  }

  filter {
    name   = "vpc-id"
    values = [aws_vpc.this.id]
  }

  depends_on = [aws_cloudfront_vpc_origin.this]
}

# ---- ECR (アプリイメージ置き場) ---------------------------------------
resource "aws_ecr_repository" "app" {
  name         = "${var.sandbox_name}-app"
  force_delete = true

  tags = { Name = "${var.sandbox_name}-app" }
}

# ---- S3 (静的フロント) + OAC ------------------------------------------
resource "aws_s3_bucket" "frontend" {
  bucket_prefix = "${var.sandbox_name}-front-"
  force_destroy = true

  tags = { Name = "${var.sandbox_name}-front" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.sandbox_name}-front"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront distribution からのみ GetObject を許可 (SourceArn で自分の dist に限定)
data "aws_iam_policy_document" "frontend" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}

# ---- CloudFront Distribution (1 本 / S3 + VPC Origin) ------------------
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = var.sandbox_name
  price_class         = "PriceClass_100"
  default_root_object = "index.html"

  # origin 1: S3 静的フロント (OAC)
  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # origin 2: ECS backend (VPC Origin -> ALB)
  origin {
    origin_id   = "vpc-origin-alb"
    domain_name = "placeholder.invalid"

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.this.id
    }
  }

  # default /* -> S3
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true
  }

  # /api/* -> ECS (VPC Origin)。動的なので caching 無効 + AllViewer で素通し。
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "vpc-origin-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = true
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = { Name = var.sandbox_name }
}

# ---- (任意) VPC BPA ---------------------------------------------------
resource "aws_vpc_block_public_access_options" "this" {
  count = var.vpc_bpa_mode == "off" ? 0 : 1

  internet_gateway_block_mode = var.vpc_bpa_mode
}

resource "aws_vpc_block_public_access_exclusion" "private" {
  for_each = var.enable_vpc_bpa_exclusion ? aws_subnet.private : {}

  subnet_id                       = each.value.id
  internet_gateway_exclusion_mode = "allow-bidirectional"

  tags = { Name = "${var.sandbox_name}-${each.key}" }
}
