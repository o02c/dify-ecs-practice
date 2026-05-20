locals {
  chatbot_enabled = length(var.slack_team_id) > 0 && length(var.slack_channel_id) > 0
  recovery_command = format(
    "aws ses set-active-receipt-rule-set --region %s --rule-set-name %s",
    var.region,
    aws_ses_receipt_rule_set.main.rule_set_name,
  )
}

# Chatbot は notification-only 用途。Slack 側からのコマンド実行はしないので role は空で良い
data "aws_iam_policy_document" "chatbot_trust" {
  count = local.chatbot_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot" {
  count = local.chatbot_enabled ? 1 : 0

  name               = "${var.name}-chatbot"
  assume_role_policy = data.aws_iam_policy_document.chatbot_trust[0].json
}

# Chatbot API は us-east-2 専用なので provider alias を使う
resource "aws_chatbot_slack_channel_configuration" "main" {
  count    = local.chatbot_enabled ? 1 : 0
  provider = aws.us_east_2

  configuration_name = "${var.name}-slack"
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_team_id      = var.slack_team_id
  slack_channel_id   = var.slack_channel_id
  sns_topic_arns     = [aws_sns_topic.alerts.arn]
}
