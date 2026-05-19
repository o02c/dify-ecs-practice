output "hosted_zone_name_servers" {
  value = module.ses_inbound.hosted_zone_name_servers
}

output "rule_set_name" {
  value = module.ses_inbound.rule_set_name
}

output "archive_bucket" {
  value = module.ses_inbound.archive_bucket
}

output "processor_function_name" {
  value = module.ses_inbound.processor_function_name
}

output "killswitch_function_name" {
  value = module.ses_inbound.killswitch_function_name
}

output "sns_killswitch_topic_arn" {
  value = module.ses_inbound.sns_killswitch_topic_arn
}

output "chatbot_configuration_arn" {
  value = module.ses_inbound.chatbot_configuration_arn
}

output "recovery_command" {
  value = module.ses_inbound.recovery_command
}

output "test_commands" {
  value = <<-EOT
    # 動作確認
    aws logs tail ${module.ses_inbound.processor_log_group} --region ${var.region} --follow

    # killswitch 動作確認 (アラームを手動 ALARM 状態にして発火)
    aws cloudwatch set-alarm-state --region ${var.region} \
      --alarm-name ${var.sandbox_name}-received-rate \
      --state-value ALARM --state-reason "manual test"

    aws logs tail ${module.ses_inbound.killswitch_log_group} --region ${var.region} --since 1m

    aws ses describe-active-receipt-rule-set --region ${var.region} --query 'Metadata.Name'

    # 復旧
    aws ses set-active-receipt-rule-set --region ${var.region} \
      --rule-set-name ${module.ses_inbound.rule_set_name}
  EOT
}
