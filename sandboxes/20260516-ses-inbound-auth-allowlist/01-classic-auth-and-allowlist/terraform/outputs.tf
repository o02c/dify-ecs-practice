output "hosted_zone_name_servers" {
  value = aws_route53_zone.main.name_servers
}

output "archive_bucket" {
  value = aws_s3_bucket.archive.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.mail.arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "lambda_log_group" {
  value = "/aws/lambda/${aws_lambda_function.processor.function_name}"
}

output "dlq_url" {
  value = aws_sqs_queue.lambda_dlq.url
}

output "allow_list_domains" {
  value = var.allow_list_domains
}

output "test_commands" {
  value = <<-EOT
    # DNS 伝播確認
    dig +short NS ${var.domain} @8.8.8.8
    dig +short MX ${var.domain} @8.8.8.8

    # SES Identity 検証状態
    aws sesv2 get-email-identity --email-identity ${var.domain} --region ${var.region} \
      --query '{V:VerifiedForSendingStatus,D:DkimAttributes.Status}'

    # Gmail から ${var.process_recipient} 宛にテスト送信 (ユーザー操作)

    # Lambda ログ tail (WARN auth: / WARN allowlist: / ACCEPTED を期待)
    aws logs tail /aws/lambda/${aws_lambda_function.processor.function_name} \
      --region ${var.region} --follow

    # archive 確認 (全受信メール)
    aws s3 ls s3://${aws_s3_bucket.archive.id}/inbox/ --region ${var.region}

    # DLQ 残量
    aws sqs get-queue-attributes --queue-url ${aws_sqs_queue.lambda_dlq.url} \
      --attribute-names ApproximateNumberOfMessages --region ${var.region}
  EOT
}
