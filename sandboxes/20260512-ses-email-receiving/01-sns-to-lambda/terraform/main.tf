data "aws_caller_identity" "current" {}

locals {
  name             = var.sandbox_name
  inbound_endpoint = "inbound-smtp.${var.region}.amazonaws.com"
}

############################################################
# Route53 Hosted Zone + Route53 Domains NS 委任
############################################################

resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "SES email receiving sandbox"
}

# Route53 Domains に登録された name_server を Hosted Zone の NS に同期 (= 委任)
resource "aws_route53domains_registered_domain" "main" {
  provider    = aws.us_east_1
  domain_name = var.domain

  dynamic "name_server" {
    for_each = aws_route53_zone.main.name_servers
    content {
      name = name_server.value
    }
  }
}

############################################################
# SES Domain Identity + Easy DKIM + DNS records
############################################################

resource "aws_ses_domain_identity" "main" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

# Identity verification 用 TXT
resource "aws_route53_record" "amazonses_verification" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "_amazonses.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.main.verification_token]
}

# DKIM CNAME ×3
resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = aws_route53_zone.main.zone_id
  name    = "${aws_ses_domain_dkim.main.dkim_tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.main.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# 受信用 MX
resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 600
  records = ["10 ${local.inbound_endpoint}"]
}

############################################################
# SNS topic (SES Receipt Rule の publish 先)
############################################################

resource "aws_sns_topic" "mail" {
  name = "${local.name}-mail"
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowSESPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.mail.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "mail" {
  arn    = aws_sns_topic.mail.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

############################################################
# Lambda (SNS subscriber)
############################################################

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/.build/handler.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "processor" {
  function_name    = "${local.name}-processor"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 256
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.mail.arn
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.mail.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.processor.arn

  depends_on = [aws_lambda_permission.sns_invoke]
}

############################################################
# SES Receipt Rule Set / Rule
############################################################

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "${local.name}-ruleset"
}

# 注意: アカウント singleton。既存のアクティブ rule set を上書きする
resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "main" {
  name          = "${local.name}-rule"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = [var.domain]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Optional"

  sns_action {
    position  = 1
    topic_arn = aws_sns_topic.mail.arn
    encoding  = "UTF-8"
  }

  depends_on = [
    aws_sns_topic_policy.mail,
    aws_ses_domain_identity.main,
  ]
}
