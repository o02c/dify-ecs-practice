output "s3_bucket_name" {
  description = "イメージ tar をアップロードする S3 バケット名"
  value       = aws_s3_bucket.images.id
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  value       = aws_ecr_repository.app.repository_url
}

output "instance_id" {
  description = "SSM Session Manager で接続する EC2 インスタンス ID"
  value       = aws_instance.worker.id
}
