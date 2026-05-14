output "hosted_zone_name_servers" {
  description = "Route53 Hosted Zone の NS。Route53 Domains に同期済みのはず。"
  value       = aws_route53_zone.main.name_servers
}

output "ses_domain_identity" {
  value = aws_ses_domain_identity.main.domain
}

output "dkim_tokens" {
  value = aws_ses_domain_dkim.main.dkim_tokens
}

output "sns_topic_arn" {
  value = aws_sns_topic.mail.arn
}

output "lambda_log_group" {
  description = "テストメール送信後、ここを tail で監視する"
  value       = "/aws/lambda/${aws_lambda_function.processor.function_name}"
}

output "test_command" {
  description = "Verification と DNS 状態を確認するコマンド集"
  value       = <<-EOT
    # DNS 反映確認
    dig +short NS ${var.domain} @8.8.8.8
    dig +short MX ${var.domain} @8.8.8.8

    # SES Identity 検証状態
    aws sesv2 get-email-identity --email-identity ${var.domain} --region ${var.region} \
      --query '{Verified:VerifiedForSendingStatus, DkimStatus:DkimAttributes.Status}'

    # Lambda ログ tail
    aws logs tail /aws/lambda/${aws_lambda_function.processor.function_name} \
      --region ${var.region} --follow
  EOT
}
