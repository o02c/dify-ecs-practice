output "cluster_name" {
  description = "GuardDuty coverage を見る ECS cluster 名。"
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "常駐 Fargate service 名。"
  value       = aws_ecs_service.app.name
}

output "ecr_repository_url" {
  description = "アプリ image の push 先(push-image.sh で使う)。"
  value       = aws_ecr_repository.app.repository_url
}

output "vpc_id" {
  description = "タスク VPC id。"
  value       = aws_vpc.this.id
}

output "guardduty_detector_id" {
  description = "有効化した GuardDuty detector id(enable_guardduty=false なら null)。"
  value       = var.enable_guardduty ? module.guardduty[0].detector_id : null
}

output "guardduty_data_endpoint_id" {
  description = "guardduty-data endpoint id(未作成なら null)。"
  value       = var.enable_guardduty ? module.guardduty[0].guardduty_data_endpoint_id : null
}
