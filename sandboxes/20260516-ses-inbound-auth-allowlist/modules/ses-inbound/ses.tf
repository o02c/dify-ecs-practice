resource "aws_ses_domain_identity" "main" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "${var.name}-ruleset"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "process" {
  name          = "process"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = local.effective_recipients
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Optional"

  s3_action {
    position          = 1
    bucket_name       = aws_s3_bucket.archive.id
    object_key_prefix = "inbox/"
  }

  sns_action {
    position  = 2
    topic_arn = aws_sns_topic.mail.arn
    encoding  = "UTF-8"
  }

  depends_on = [
    aws_s3_bucket_policy.archive,
    aws_sns_topic_policy.mail,
    aws_ses_domain_identity.main,
  ]
}

resource "aws_ses_receipt_filter" "block" {
  for_each = var.ip_block_list

  name   = "${var.name}-block-${replace(replace(each.value, "/", "-"), ".", "-")}"
  cidr   = each.value
  policy = "Block"
}

resource "aws_ses_receipt_filter" "allow" {
  for_each = var.ip_allow_list

  name   = "${var.name}-allow-${replace(replace(each.value, "/", "-"), ".", "-")}"
  cidr   = each.value
  policy = "Allow"
}
