# =========================================================================
# CloudFront VPC Origins 最小構成 (EC2 + Python http.server)
#
# Prerequisites (AWS Docs):
#   - VPC に IGW を attach 必須 (routing には使われない)
#   - private subnet + IPv4 1 個以上 (IPv6 only 不可)
#   - EC2 / ALB / NLB のいずれかを origin に
#   - SG ingress を CloudFront managed prefix list から許可
#   - NACL は VPC Origin traffic では評価されない
# =========================================================================

data "aws_availability_zones" "available" {
  state = "available"
  # ap-northeast-1 で VPC Origins 非対応の AZ (apne1-az3) を除外
  filter {
    name   = "zone-id"
    values = ["apne1-az1", "apne1-az2", "apne1-az4"]
  }
}

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# CloudFront が VPC Origin 作成時に自動生成する service-managed SG。
# 命名規則: CloudFront-VPCOrigins-Service-SG-<vpc-id> (account/region 内で
# VPC ごとに 1 個)。VPC Origin 作成後でないと存在しないので depends_on で
# 順序を保証する。
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

# ---- VPC ---------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.sandbox_name }
}

# IGW は attach するだけで route table には載せない (= 実質 private)。
# AWS Docs prerequisite: "Internet gateway ... is not used for routing
# traffic to origins inside the subnet"
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.sandbox_name }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "${var.sandbox_name}-private" }
}

# ---- (Optional) custom NACL ------------------------------------------
# use_custom_nacl = true で subnet に custom NACL を関連付ける。
# rule は別 toggle (custom_nacl_allow_*) で個別に on/off できる設計。
# subnet_ids は明示せず、aws_network_acl_association で分離して
# association 切替時の replace を回避する。
resource "aws_network_acl" "custom" {
  count = var.use_custom_nacl ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-custom" }
}

resource "aws_network_acl_association" "custom" {
  count = var.use_custom_nacl ? 1 : 0

  network_acl_id = aws_network_acl.custom[0].id
  subnet_id      = aws_subnet.private.id
}

resource "aws_network_acl_rule" "ingress_origin_port" {
  count = var.use_custom_nacl && var.custom_nacl_allow_ingress_origin_port ? 1 : 0

  network_acl_id = aws_network_acl.custom[0].id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "egress_ephemeral" {
  count = var.use_custom_nacl && var.custom_nacl_allow_egress_ephemeral ? 1 : 0

  network_acl_id = aws_network_acl.custom[0].id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "ingress_ephemeral" {
  count = var.use_custom_nacl && var.custom_nacl_allow_ingress_ephemeral ? 1 : 0

  network_acl_id = aws_network_acl.custom[0].id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "egress_origin_port" {
  count = var.use_custom_nacl && var.custom_nacl_allow_egress_origin_port ? 1 : 0

  network_acl_id = aws_network_acl.custom[0].id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

# ---- Security Group ----------------------------------------------------
resource "aws_security_group" "origin" {
  name        = "${var.sandbox_name}-origin"
  description = "CloudFront to EC2 origin (HTTP 80)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-origin" }
}

resource "aws_vpc_security_group_ingress_rule" "origin_http" {
  security_group_id            = aws_security_group.origin.id
  description                  = "HTTP from CloudFront service-managed SG"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origin_service.id
}

# ---- EC2 (origin) ------------------------------------------------------
resource "aws_instance" "origin" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.origin.id]
  associate_public_ip_address = false

  # AL2023 同梱の python3 で 80 番に listen (user_data は root 実行)。
  # systemd unit で永続化 + 自動再起動。
  user_data = <<-EOT
    #!/bin/bash
    set -eu
    mkdir -p /var/www
    echo "Hello from VPC Origin (private) at $(hostname -I)" > /var/www/index.html
    cat >/etc/systemd/system/http.service <<'UNIT'
    [Unit]
    Description=Minimal Python HTTP for CloudFront VPC Origin verification
    After=network.target
    [Service]
    WorkingDirectory=/var/www
    ExecStart=/usr/bin/python3 -m http.server 80
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now http.service
  EOT

  tags = { Name = "${var.sandbox_name}-origin" }
}

# ---- CloudFront VPC Origin --------------------------------------------
resource "aws_cloudfront_vpc_origin" "this" {
  vpc_origin_endpoint_config {
    name                   = var.sandbox_name
    arn                    = aws_instance.origin.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    # http-only でも API 上は origin_ssl_protocols 必須
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# ---- CloudFront Distribution ------------------------------------------
resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = var.sandbox_name
  price_class     = "PriceClass_100"

  origin {
    origin_id = "vpc-origin-ec2"
    # vpc_origin_config 利用時も domain_name は API 必須 (CloudFront は無視)
    domain_name = "placeholder.invalid"

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.this.id
    }
  }

  default_cache_behavior {
    target_origin_id       = "vpc-origin-ec2"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
    compress               = true
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

# ---- (Optional) VPC Block Public Access -------------------------------
# アカウント + region 単位のグローバル設定。enable_vpc_bpa = true の時のみ作成。
# destroy 時は internet_gateway_block_mode が "off" に戻る (provider 仕様)。
resource "aws_vpc_block_public_access_options" "this" {
  count = var.vpc_bpa_mode == "off" ? 0 : 1

  internet_gateway_block_mode = var.vpc_bpa_mode
}

# BPA on の状態で subnet 単位の exclusion を当てる。
# AWS サポート公式回答: CF -> VPC Origin の実トラフィックは IGW 経由しないが、
# 内部処理のため origin を置く subnet で BPA 許可 (exclusion) が必要。
# subnet 単位で当てて疎通成立するか検証する。
resource "aws_vpc_block_public_access_exclusion" "this" {
  count = var.enable_vpc_bpa_exclusion ? 1 : 0

  subnet_id                       = aws_subnet.private.id
  internet_gateway_exclusion_mode = "allow-bidirectional"

  tags = { Name = var.sandbox_name }
}
