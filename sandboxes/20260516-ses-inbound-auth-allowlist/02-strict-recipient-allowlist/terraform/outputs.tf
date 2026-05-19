output "hosted_zone_name_servers" {
  value = aws_route53_zone.main.name_servers
}

output "archive_bucket" {
  value = aws_s3_bucket.archive.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.mail.arn
}

output "lambda_log_group" {
  value = "/aws/lambda/${aws_lambda_function.processor.function_name}"
}

output "dlq_url" {
  value = aws_sqs_queue.lambda_dlq.url
}

output "allowed_recipients" {
  value = var.allowed_recipients
}

output "rule_set_name" {
  value = aws_ses_receipt_rule_set.main.rule_set_name
}

output "test_commands" {
  value = <<-EOT
    # DNS 伝播確認
    dig +short MX ${var.domain} @8.8.8.8

    # SES Identity 検証状態
    aws sesv2 get-email-identity --email-identity ${var.domain} --region ${var.region} \
      --query '{V:VerifiedForSendingStatus,D:DkimAttributes.Status}'

    # Gmail から allowed 宛 (例: ${var.allowed_recipients[0]}) と 非 allowed 宛 (例: random@${var.domain}) を送信して比較

    # Lambda ログ tail
    aws logs tail /aws/lambda/${aws_lambda_function.processor.function_name} \
      --region ${var.region} --follow

    # S3 archive 確認 (allowed 宛だけが入っているはず)
    aws s3 ls s3://${aws_s3_bucket.archive.id}/inbox/ --region ${var.region}

    # CloudWatch SES Received メトリクス (rule にマッチしたメールのみ +1、課金対象と一致するはず)
    NOW=$(date -u +"%%Y-%%m-%%dT%%H:%%M:%%SZ")
    START=$(date -u -v-30M +"%%Y-%%m-%%dT%%H:%%M:%%SZ")
    aws cloudwatch get-metric-statistics --region ${var.region} \
      --namespace AWS/SES --metric-name Received \
      --dimensions Name=RuleSetName,Value=${aws_ses_receipt_rule_set.main.rule_set_name} \
      --start-time "$START" --end-time "$NOW" --period 300 --statistics Sum
  EOT
}
