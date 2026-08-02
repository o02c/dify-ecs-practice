# 検証・runbook で使う値。ecspresso は tfstate プラグインで state の
# resource 属性を直接読むため、これらの output には依存しない。

output "cloudfront_domain" {
  description = "配信ドメイン。/ は S3、/api/* は ECS。"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "s3_bucket" {
  description = "フロント静的ファイルのアップロード先バケット。"
  value       = aws_s3_bucket.frontend.bucket
}

output "ecr_repository_url" {
  description = "アプリイメージの push 先。"
  value       = aws_ecr_repository.app.repository_url
}

output "cluster_name" {
  description = "ecspresso が deploy する ECS cluster。"
  value       = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  description = "internal ALB の DNS (VPC 内からの疎通確認用)。"
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "ecspresso service が task を登録する Target Group。"
  value       = aws_lb_target_group.this.arn
}

output "source_bucket" {
  description = "CodeBuild が読む deploy.zip (image.tar + assets + ecspresso + bin) の置き場。"
  value       = aws_s3_bucket.source.bucket
}

output "codebuild_project" {
  description = "ECR push + フロント S3 配置 + ecspresso deploy を行う CodeBuild プロジェクト名。"
  value       = aws_codebuild_project.deploy.name
}
