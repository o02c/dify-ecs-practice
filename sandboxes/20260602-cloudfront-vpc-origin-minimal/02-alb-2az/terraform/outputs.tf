output "distribution_url" {
  value = "https://${aws_cloudfront_distribution.this.domain_name}/"
}

output "alb_dns" {
  value = aws_lb.this.dns_name
}

output "ec2_instance_id" {
  value = aws_instance.origin.id
}

output "vpc_origin_id" {
  value = aws_cloudfront_vpc_origin.this.id
}

output "subnet_ids" {
  value = { for k, s in aws_subnet.private : k => s.id }
}

output "az_ids" {
  value = { for k, s in aws_subnet.private : k => s.availability_zone_id }
}
