output "distribution_domain_name" {
  description = "curl で叩く URL の host 部分"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_url" {
  description = "そのまま curl で叩ける URL"
  value       = "https://${aws_cloudfront_distribution.this.domain_name}/"
}

output "ec2_private_ip" {
  description = "EC2 private IP (疎通失敗時の切り分け用)"
  value       = aws_instance.origin.private_ip
}

output "ec2_instance_id" {
  description = "EC2 instance id (SSM や console 確認用)"
  value       = aws_instance.origin.id
}

output "vpc_origin_id" {
  description = "CloudFront VPC Origin の id"
  value       = aws_cloudfront_vpc_origin.this.id
}
