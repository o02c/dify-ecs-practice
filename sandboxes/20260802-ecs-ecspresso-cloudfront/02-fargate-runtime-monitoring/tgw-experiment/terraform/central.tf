# =========================================================================
# central VPC: guardduty-data endpoint を「集約先」として置く VPC
#
# spoke の Fargate タスクはここの endpoint を TGW + PHZ 経由で使う想定。
# endpoint は private_dns_enabled=false(PHZ で名前解決させるため)。
# =========================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "central" {
  cidr_block           = var.central_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-central" }
}

resource "aws_subnet" "central" {
  for_each = toset(["a", "b"])

  vpc_id            = aws_vpc.central.id
  cidr_block        = each.key == "a" ? cidrsubnet(var.central_cidr, 8, 1) : cidrsubnet(var.central_cidr, 8, 2)
  availability_zone = each.key == "a" ? data.aws_availability_zones.available.names[0] : data.aws_availability_zones.available.names[1]

  tags = { Name = "${var.name}-central-${each.key}" }
}

resource "aws_route_table" "central" {
  vpc_id = aws_vpc.central.id
  tags   = { Name = "${var.name}-central" }
}

resource "aws_route_table_association" "central" {
  for_each = toset(["a", "b"])

  subnet_id      = aws_subnet.central[each.key].id
  route_table_id = aws_route_table.central.id
}

# spoke -> central への戻り経路 (TGW)
resource "aws_route" "central_to_spoke" {
  route_table_id         = aws_route_table.central.id
  destination_cidr_block = var.spoke_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.central]
}

# ---- guardduty-data endpoint (集約先。private DNS off) ------------------
resource "aws_security_group" "gd_endpoint" {
  name        = "${var.name}-gd-endpoint"
  description = "guardduty-data endpoint: 443 from spoke CIDR via TGW"
  vpc_id      = aws_vpc.central.id

  tags = { Name = "${var.name}-gd-endpoint" }
}

# spoke VPC CIDR から 443 を許可 (TGW 経由の source は spoke の task ENI IP = spoke CIDR)
resource "aws_vpc_security_group_ingress_rule" "gd_from_spoke" {
  security_group_id = aws_security_group.gd_endpoint.id
  description       = "HTTPS from spoke VPC CIDR (via TGW)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.spoke_cidr
}

# central VPC 内からも一応許可 (疎通確認用)
resource "aws_vpc_security_group_ingress_rule" "gd_from_central" {
  security_group_id = aws_security_group.gd_endpoint.id
  description       = "HTTPS from central VPC CIDR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.central_cidr
}

resource "aws_vpc_security_group_egress_rule" "gd_all" {
  security_group_id = aws_security_group.gd_endpoint.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# private_dns_enabled=false: 標準名の解決は PHZ (dns.tf) で spoke/central に配る。
resource "aws_vpc_endpoint" "guardduty_data" {
  vpc_id              = aws_vpc.central.id
  service_name        = "com.amazonaws.${var.region}.guardduty-data"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.central : s.id]
  security_group_ids  = [aws_security_group.gd_endpoint.id]
  private_dns_enabled = false

  tags = { Name = "${var.name}-guardduty-data" }
}
