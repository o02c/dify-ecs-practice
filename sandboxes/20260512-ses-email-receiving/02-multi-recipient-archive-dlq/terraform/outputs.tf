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

output "test_commands" {
  value = <<-EOT
    # 各 recipient に送って動作を比較
    # 1) inbox: 全メール archive + Lambda 処理
    aws sesv2 send-email --region ${var.region} \
      --from-email-address "test@${var.domain}" \
      --destination "ToAddresses=${var.process_recipient}" \
      --content 'Simple={Subject={Data="inbox test",Charset="UTF-8"},Body={Text={Data="hello",Charset="UTF-8"}}}'

    # 2) catchall: archive のみ、Lambda 起動しない
    aws sesv2 send-email --region ${var.region} \
      --from-email-address "test@${var.domain}" \
      --destination "ToAddresses=random@${var.domain}" \
      --content 'Simple={Subject={Data="catchall test",Charset="UTF-8"},Body={Text={Data="hello",Charset="UTF-8"}}}'

    # 3) noreply: archive 後にバウンス
    aws sesv2 send-email --region ${var.region} \
      --from-email-address "test@${var.domain}" \
      --destination "ToAddresses=${var.drop_recipient}" \
      --content 'Simple={Subject={Data="noreply test",Charset="UTF-8"},Body={Text={Data="hello",Charset="UTF-8"}}}'

    # S3 archive 確認
    aws s3 ls s3://${aws_s3_bucket.archive.id}/inbox/ --region ${var.region}

    # Lambda ログ
    aws logs tail /aws/lambda/${aws_lambda_function.processor.function_name} \
      --region ${var.region} --since 5m

    # DLQ 残量
    aws sqs get-queue-attributes --queue-url ${aws_sqs_queue.lambda_dlq.url} \
      --attribute-names ApproximateNumberOfMessages --region ${var.region}
  EOT
}
