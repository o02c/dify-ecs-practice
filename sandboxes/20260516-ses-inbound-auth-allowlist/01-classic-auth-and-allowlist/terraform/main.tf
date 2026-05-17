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
  comment = "SES inbound auth & allowlist sandbox"
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
# S3 archive (全受信メール永続化)
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
# SNS topic (Receipt Rule の SNS action → Lambda)
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
# SQS DLQ (SNS → Lambda の redrive 先)
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
# Lambda (3 段判定: DMARC PASS + spam/virus + allow list)
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

# Lambda 実行時に自動作成される log group を terraform で先回り管理しておくと
# destroy 時にも一緒に消える。retention も terraform で制御できる。
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
# CloudWatch アラーム (Lambda Errors / DLQ depth / SNS Failed)
############################################################

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  alarm_description   = "Lambda processor が 1 件以上失敗 (retry 込み)"
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
  alarm_description   = "DLQ に 1 件以上滞留 = Lambda が retry 後も失敗した"
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
  alarm_description   = "SNS から Lambda への配信が失敗 (DLQ への退避でも 1 カウント)"
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
# SES Receipt Rule Set + 2 Rules
############################################################

resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "${local.name}-ruleset"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

# Rule 1: 全メールを S3 archive (catchall)
resource "aws_ses_receipt_rule" "archive_all" {
  name          = "archive-all"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = [var.domain]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Optional"

  s3_action {
    position          = 1
    bucket_name       = aws_s3_bucket.archive.id
    object_key_prefix = "inbox/"
  }

  depends_on = [
    aws_s3_bucket_policy.archive,
    aws_ses_domain_identity.main,
  ]
}

# Rule 2: inbox 宛のメールを SNS → Lambda
resource "aws_ses_receipt_rule" "process_inbox" {
  name          = "process-inbox"
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = [var.process_recipient]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Optional"
  after         = aws_ses_receipt_rule.archive_all.name

  sns_action {
    position  = 1
    topic_arn = aws_sns_topic.mail.arn
    encoding  = "UTF-8"
  }

  depends_on = [
    aws_sns_topic_policy.mail,
  ]
}

############################################################
# IP Address Filter (サンプル、デフォルト no-op)
#
# 完全ホワイトリスト化の例:
#   ip_block_list = ["0.0.0.0/0"]
#   ip_allow_list = ["xxx.xxx.xxx.xxx/32"]   # 信頼する SMTP 中継サーバー
#
# 既知の悪意 IP だけ block する例:
#   ip_block_list = ["198.51.100.0/24"]
############################################################

resource "aws_ses_receipt_filter" "block" {
  for_each = var.ip_block_list

  name   = "${local.name}-block-${replace(replace(each.value, "/", "-"), ".", "-")}"
  cidr   = each.value
  policy = "Block"
}

resource "aws_ses_receipt_filter" "allow" {
  for_each = var.ip_allow_list

  name   = "${local.name}-allow-${replace(replace(each.value, "/", "-"), ".", "-")}"
  cidr   = each.value
  policy = "Allow"
}
