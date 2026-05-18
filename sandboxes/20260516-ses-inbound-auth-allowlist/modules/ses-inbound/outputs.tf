output "hosted_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "hosted_zone_name_servers" {
  value = aws_route53_zone.main.name_servers
}

output "rule_set_name" {
  value = aws_ses_receipt_rule_set.main.rule_set_name
}

output "archive_bucket" {
  value = aws_s3_bucket.archive.id
}

output "sns_mail_topic_arn" {
  value = aws_sns_topic.mail.arn
}

output "sns_alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "sns_killswitch_topic_arn" {
  value = var.enable_killswitch ? aws_sns_topic.killswitch[0].arn : null
}

output "processor_function_name" {
  value = aws_lambda_function.processor.function_name
}

output "processor_log_group" {
  value = aws_cloudwatch_log_group.processor.name
}

output "killswitch_function_name" {
  value = var.enable_killswitch ? aws_lambda_function.killswitch[0].function_name : null
}

output "killswitch_log_group" {
  value = var.enable_killswitch ? aws_cloudwatch_log_group.killswitch[0].name : null
}

output "dlq_url" {
  value = aws_sqs_queue.lambda_dlq.url
}

output "effective_recipients" {
  value = local.effective_recipients
}

output "chatbot_configuration_arn" {
  value = local.chatbot_enabled ? aws_chatbot_slack_channel_configuration.main[0].chat_configuration_arn : null
}

output "recovery_command" {
  description = "killswitch 発火時に rule set を再有効化するコマンド (アラームの description にも埋め込まれる)"
  value       = local.recovery_command
}
