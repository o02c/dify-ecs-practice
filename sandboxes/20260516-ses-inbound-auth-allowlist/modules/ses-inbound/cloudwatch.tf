resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name}-lambda-errors"
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
  alarm_name          = "${var.name}-dlq-depth"
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
  alarm_name          = "${var.name}-sns-failed"
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

# Killswitch 用アラーム (受信レート / Lambda 起動レート)
# 発火先は alerts ではなく killswitch SNS topic = killswitch Lambda が応答する
resource "aws_cloudwatch_metric_alarm" "received_rate" {
  count = var.enable_killswitch ? 1 : 0

  alarm_name = "${var.name}-received-rate"
  alarm_description = <<-EOT
    SES 受信レートが ${var.killswitch_received_threshold}/${var.killswitch_period_seconds}s を超えた = killswitch 発火、active rule set 解除済。
    Recovery: ${local.recovery_command}
  EOT
  namespace           = "AWS/SES"
  metric_name         = "Received"
  statistic           = "Sum"
  period              = var.killswitch_period_seconds
  evaluation_periods  = 1
  threshold           = var.killswitch_received_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleSetName = aws_ses_receipt_rule_set.main.rule_set_name
  }

  alarm_actions = [aws_sns_topic.killswitch[0].arn, aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "invocation_rate" {
  count = var.enable_killswitch ? 1 : 0

  alarm_name = "${var.name}-invocation-rate"
  alarm_description = <<-EOT
    Lambda 起動レートが ${var.killswitch_invocation_threshold}/${var.killswitch_period_seconds}s を超えた = killswitch 発火、active rule set 解除済。
    Recovery: ${local.recovery_command}
  EOT
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  statistic           = "Sum"
  period              = var.killswitch_period_seconds
  evaluation_periods  = 1
  threshold           = var.killswitch_invocation_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }

  alarm_actions = [aws_sns_topic.killswitch[0].arn, aws_sns_topic.alerts.arn]
}
