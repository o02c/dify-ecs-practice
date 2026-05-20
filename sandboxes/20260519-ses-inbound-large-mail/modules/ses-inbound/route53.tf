data "aws_caller_identity" "current" {}

locals {
  inbound_endpoint    = "inbound-smtp.${var.region}.amazonaws.com"
  effective_recipients = length(var.allowed_recipients) > 0 ? var.allowed_recipients : [var.domain]
}

resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "Managed by ses-inbound module: ${var.name}"
}

resource "aws_route53domains_registered_domain" "main" {
  count    = var.manage_registered_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name = var.domain

  dynamic "name_server" {
    for_each = aws_route53_zone.main.name_servers
    content {
      name = name_server.value
    }
  }
}

resource "aws_route53_record" "amazonses_verification" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "_amazonses.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.main.verification_token]
}

resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = aws_route53_zone.main.zone_id
  name    = "${aws_ses_domain_dkim.main.dkim_tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.main.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 600
  records = ["10 ${local.inbound_endpoint}"]
}
