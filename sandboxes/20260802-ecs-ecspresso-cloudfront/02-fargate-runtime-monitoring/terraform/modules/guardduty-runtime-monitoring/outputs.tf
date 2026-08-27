output "detector_id" {
  description = "GuardDuty detector id。"
  value       = aws_guardduty_detector.this.id
}

output "guardduty_data_endpoint_id" {
  description = "guardduty-data interface VPC endpoint id(作らない設定なら null)。"
  value       = var.create_data_endpoint ? aws_vpc_endpoint.guardduty_data[0].id : null
}
