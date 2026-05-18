resource "aws_sns_topic" "mail" {
  name = "${var.name}-mail"
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid     = "AllowSESPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

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

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

# killswitch 専用トピック (alerts とは分離して、誤発火を防ぐ)
resource "aws_sns_topic" "killswitch" {
  count = var.enable_killswitch ? 1 : 0
  name  = "${var.name}-killswitch"
}

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.name}-lambda-dlq"
  message_retention_seconds = 1209600
}

data "aws_iam_policy_document" "dlq_policy" {
  statement {
    sid     = "AllowSNSSendMessage"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

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
