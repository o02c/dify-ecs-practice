# =========================================================================
# Route53 PHZ: guardduty-data.<region>.amazonaws.com を central endpoint に向ける
#
# spoke は enable_dns_hostnames=false でローカル endpoint の private DNS が使えないので、
# 標準名 guardduty-data.<region>.amazonaws.com をこの PHZ で central endpoint の ENI に解決させ、
# TGW 経由で到達させる。これが「centralized VPC endpoints」パターン(whitepaper)の適用。
# =========================================================================

resource "aws_route53_zone" "gd" {
  name = "guardduty-data.${var.region}.amazonaws.com"

  # spoke(サイドカーが解決する)+ central(疎通確認用)の両方に association
  vpc {
    vpc_id = aws_vpc.spoke.id
  }
  vpc {
    vpc_id = aws_vpc.central.id
  }

  comment = "${var.name}: point guardduty-data to central endpoint over TGW"
}

# apex(guardduty-data.<region>.amazonaws.com)を central の interface endpoint に ALIAS
resource "aws_route53_record" "gd" {
  zone_id = aws_route53_zone.gd.zone_id
  name    = "guardduty-data.${var.region}.amazonaws.com"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.guardduty_data.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.guardduty_data.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}
