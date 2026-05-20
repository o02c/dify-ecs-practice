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

output "processor_log_group" {
  value = module.ses_inbound.processor_log_group
}

output "killswitch_function_name" {
  value = module.ses_inbound.killswitch_function_name
}

output "chatbot_configuration_arn" {
  value = module.ses_inbound.chatbot_configuration_arn
}

output "recovery_command" {
  value = module.ses_inbound.recovery_command
}

output "test_commands" {
  value = <<-EOT
    # Lambda ログ tail (S3 GetObject + ACCEPTED が見える)
    aws logs tail ${module.ses_inbound.processor_log_group} --region ${var.region} --follow

    # S3 archive 確認
    aws s3 ls s3://${module.ses_inbound.archive_bucket}/inbox/ --region ${var.region}

    # 大きめメールテストには gmail からの送信が必要 (長文 / HTML / 画像付き)
  EOT
}
