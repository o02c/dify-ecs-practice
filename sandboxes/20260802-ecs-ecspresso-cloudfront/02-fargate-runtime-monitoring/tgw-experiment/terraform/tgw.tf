# =========================================================================
# Transit Gateway: spoke <-> central を接続(guardduty-data を集約するハブ)
# default route table に auto associate/propagate させ、両 VPC 間を疎通させる。
# =========================================================================

resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.name} hub"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = { Name = var.name }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "central" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.central.id
  subnet_ids         = [for s in aws_subnet.central : s.id]

  tags = { Name = "${var.name}-central" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.spoke.id
  subnet_ids         = [for s in aws_subnet.spoke : s.id]

  tags = { Name = "${var.name}-spoke" }
}
