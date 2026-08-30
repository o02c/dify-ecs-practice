output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "spoke_vpc_id" {
  value = aws_vpc.spoke.id
}

output "central_vpc_id" {
  value = aws_vpc.central.id
}

output "central_guardduty_data_endpoint_id" {
  value = aws_vpc_endpoint.guardduty_data.id
}

output "central_endpoint_dns" {
  description = "central endpoint の regional DNS 名(PHZ ALIAS 先)"
  value       = aws_vpc_endpoint.guardduty_data.dns_entry[0].dns_name
}

output "phz_record" {
  value = aws_route53_record.gd.fqdn
}

output "tgw_id" {
  value = aws_ec2_transit_gateway.this.id
}
