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
  comment = "SES inbound strict allowlist sandbox"
}

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

############################################################
# S3 archive (許可アドレスにマッチした分のみ保存される)
############################################################

resource "aws_s3_bucket" "archive" {
  bucket        = "${local.name}-archive-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "archive-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }
}

data "aws_iam_policy_document" "archive_bucket_policy" {
  statement {
    sid    = "AllowSESPutObject"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.archive.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id
  policy = data.aws_iam_policy_document.archive_bucket_policy.json
}

############################################################
# SNS topic
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
# SQS DLQ
############################################################

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${local.name}-lambda-dlq"
  message_retention_seconds = 1209600 # 14 days
}

data "aws_iam_policy_document" "dlq_policy" {
  statement {
    sid    = "AllowSNSSendMessage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda_dlq.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.mail.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "lambda_dlq" {
  queue_url = aws_sqs_queue.lambda_dlq.id
  policy    = data.aws_iam_policy_document.dlq_policy.json
}

############################################################
# Lambda (01 と同じ実装、env var ALLOW_LIST_DOMAINS で sender ドメイン allow list)
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

  environment {
    variables = {
      ALLOW_LIST_DOMAINS = join(",", var.allow_list_domains)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-processor"
  retention_in_days = var.log_retention_days
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

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.lambda_dlq.arn
  })

  depends_on = [aws_lambda_permission.sns_invoke]
}

############################################################
# CloudWatch アラーム
############################################################

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  alarm_description   = "Lambda processor が 1 件以上失敗"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name}-dlq-depth"
  alarm_description   = "DLQ に 1 件以上滞留"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.lambda_dlq.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "sns_failed" {
  alarm_name          = "${local.name}-sns-failed"
  alarm_description   = "SNS から Lambda への配信が失敗"
  namespace           = "AWS/SNS"
  metric_name         = "NumberOfNotificationsFailed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TopicName = aws_sns_topic.mail.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

############################################################
# SES Receipt Rule Set + 単一 rule (strict allowlist)
#
# 01 との重要な違い:
#   - archive-all (catchall recipients=[var.domain]) を撤廃
#   - 単一 rule の recipients に許可アドレスを明示列挙
#   - 列挙外のアドレス宛は SES SMTP 中 reject → 課金されない / Lambda 起動もしない
############################################################

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "${local.name}-ruleset"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "process_allowed" {
  name          = "process-allowed"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = var.allowed_recipients
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
