output "s3_bucket_name" {
  description = "イメージ tar をアップロードする S3 バケット名"
  value       = aws_s3_bucket.images.id
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  value       = aws_ecr_repository.app.repository_url
}

output "lambda_function_name" {
  description = "Lambda 関数名 (ログ確認用)"
  value       = aws_lambda_function.push_to_ecr.function_name
}
