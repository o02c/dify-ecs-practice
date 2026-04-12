output "source_bucket_name" {
  description = "source.zip をアップロードする S3 バケット名"
  value       = aws_s3_bucket.source.id
}

output "ecr_repository_url" {
  description = "ECR リポジトリ URL"
  value       = aws_ecr_repository.app.repository_url
}

output "codebuild_project_name" {
  description = "CodeBuild プロジェクト名 (マネコンから実行)"
  value       = aws_codebuild_project.build_and_push.name
}
