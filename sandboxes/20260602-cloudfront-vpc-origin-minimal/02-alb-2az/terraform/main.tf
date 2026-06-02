# =========================================================================
# CloudFront VPC Origins 最小構成 (ALB + 2 AZ private subnet)
#
# 01-ec2-minimal との差分:
#   - origin が ALB (internal application LB)。HA 要件で 2 AZ subnet 必須
#   - ALB の target は EC2 (Python http.server) 1 台
#   - SG が 2 段: ALB SG (CF service SG から ingress) / EC2 SG (ALB SG から ingress)
#   - VPC Origin は ALB ARN を指す
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

# ---- VPC ---------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.sandbox_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.sandbox_name }
}

# ALB の HA 要件で 2 AZ subnet 必須
resource "aws_subnet" "private" {
  for_each = toset(["a", "b"])

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.key == "a" ? "10.0.1.0/24" : "10.0.2.0/24"
  availability_zone = each.key == "a" ? data.aws_availability_zones.available.names[0] : data.aws_availability_zones.available.names[1]

  tags = { Name = "${var.sandbox_name}-private-${each.key}" }
}

# ---- Security Groups (2 段) -------------------------------------------
# ALB SG: CloudFront service SG からの ingress
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

# ALB は target group health check / forward に egress 必要
resource "aws_vpc_security_group_egress_rule" "alb_to_ec2" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to EC2 target"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.ec2.id
}

# EC2 SG: ALB SG からの ingress のみ
resource "aws_security_group" "ec2" {
  name        = "${var.sandbox_name}-ec2"
  description = "ALB to EC2 (HTTP 80)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-ec2" }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "HTTP from ALB SG"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

# ---- EC2 (origin target, 1 台 in subnet a) ----------------------------
resource "aws_instance" "origin" {
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.private["a"].id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = false

  user_data = <<-EOT
    #!/bin/bash
    set -eu
    mkdir -p /var/www
    echo "Hello from VPC Origin via ALB at $(hostname -I)" > /var/www/index.html
    cat >/etc/systemd/system/http.service <<'UNIT'
    [Unit]
    Description=Minimal Python HTTP for CloudFront VPC Origin (ALB) verification
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

  tags = { Name = "${var.sandbox_name}-ec2" }
}

# ---- ALB (internal, 2 AZ) ---------------------------------------------
resource "aws_lb" "this" {
  name               = var.sandbox_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.private : s.id]

  tags = { Name = var.sandbox_name }
}

resource "aws_lb_target_group" "this" {
  name     = var.sandbox_name
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    enabled             = true
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = var.sandbox_name }
}

resource "aws_lb_target_group_attachment" "ec2" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.origin.id
  port             = 80
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

# CloudFront service-managed SG (VPC scoped, 1 per VPC)
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

# ---- CloudFront Distribution ------------------------------------------
resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = var.sandbox_name
  price_class     = "PriceClass_100"

  origin {
    origin_id   = "vpc-origin-alb"
    domain_name = "placeholder.invalid"

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.this.id
    }
  }

  default_cache_behavior {
    target_origin_id       = "vpc-origin-alb"
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

# ---- (Optional) VPC BPA -----------------------------------------------
resource "aws_vpc_block_public_access_options" "this" {
  count = var.vpc_bpa_mode == "off" ? 0 : 1

  internet_gateway_block_mode = var.vpc_bpa_mode
}

# subnet 単位 exclusion を 2 AZ subnet それぞれに当てるか
resource "aws_vpc_block_public_access_exclusion" "subnet_a" {
  count = var.enable_vpc_bpa_exclusion_subnet_a ? 1 : 0

  subnet_id                       = aws_subnet.private["a"].id
  internet_gateway_exclusion_mode = "allow-bidirectional"

  tags = { Name = "${var.sandbox_name}-a" }
}

resource "aws_vpc_block_public_access_exclusion" "subnet_b" {
  count = var.enable_vpc_bpa_exclusion_subnet_b ? 1 : 0

  subnet_id                       = aws_subnet.private["b"].id
  internet_gateway_exclusion_mode = "allow-bidirectional"

  tags = { Name = "${var.sandbox_name}-b" }
}

# ---- (Optional) custom NACL ------------------------------------------
# 両 subnet に同一 NACL を associate
resource "aws_network_acl" "custom" {
  count = var.use_custom_nacl ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.sandbox_name}-custom" }
}

resource "aws_network_acl_association" "custom" {
  for_each = var.use_custom_nacl ? toset(["a", "b"]) : []

  network_acl_id = aws_network_acl.custom[0].id
  subnet_id      = aws_subnet.private[each.key].id
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
