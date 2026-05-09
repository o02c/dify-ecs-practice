output "instance_id" {
  description = "SSM Session Manager で接続する EC2 インスタンス ID"
  value       = aws_instance.worker.id
}

output "registry_uri" {
  description = "PTC 経由で pull する際のレジストリ URI"
  value       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "ptc_prefix" {
  description = "PTC の repository prefix (上流: public.ecr.aws)"
  value       = aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix
}

output "sample_pull_uri" {
  description = "動作確認用に最初に試す pull URI (alpine)"
  value       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${var.ptc_prefix}/docker/library/alpine:latest"
}
