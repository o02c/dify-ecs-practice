# =========================================================================
# spoke VPC: Fargate タスクが動く VPC
#
# ポイント:
#   - enable_dns_hostnames = FALSE:
#       GuardDuty の guardduty-data endpoint 自動作成(private DNS 付き)を失敗させ、
#       spoke にローカル endpoint を作らせない = サイドカーを PHZ 経由で central に向ける。
#       (enable_dns_support=true は残すので PHZ 解決と public 名解決は可能)
#   - public subnet + IGW + assign_public_ip:
#       enable_dns_hostnames=false は ECR interface endpoint の private DNS も壊すため、
#       image / ECS API は public 経由で pull。guardduty-data だけ TGW 経由に焦点を絞る。
# =========================================================================

resource "aws_vpc" "spoke" {
  cidr_block           = var.spoke_cidr
  enable_dns_support   = true
  enable_dns_hostnames = false # ← GuardDuty のローカル自動作成を抑止する肝

  tags = { Name = "${var.name}-spoke" }
}

resource "aws_subnet" "spoke" {
  for_each = toset(["a", "b"])

  vpc_id            = aws_vpc.spoke.id
  cidr_block        = each.key == "a" ? cidrsubnet(var.spoke_cidr, 8, 1) : cidrsubnet(var.spoke_cidr, 8, 2)
  availability_zone = each.key == "a" ? data.aws_availability_zones.available.names[0] : data.aws_availability_zones.available.names[1]

  tags = { Name = "${var.name}-spoke-${each.key}" }
}

resource "aws_internet_gateway" "spoke" {
  vpc_id = aws_vpc.spoke.id
  tags   = { Name = "${var.name}-spoke" }
}

resource "aws_route_table" "spoke" {
  vpc_id = aws_vpc.spoke.id
  tags   = { Name = "${var.name}-spoke" }
}

resource "aws_route" "spoke_default" {
  route_table_id         = aws_route_table.spoke.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.spoke.id
}

# guardduty-data の集約先 central VPC へは TGW 経由
resource "aws_route" "spoke_to_central" {
  route_table_id         = aws_route_table.spoke.id
  destination_cidr_block = var.central_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

resource "aws_route_table_association" "spoke" {
  for_each = toset(["a", "b"])

  subnet_id      = aws_subnet.spoke[each.key].id
  route_table_id = aws_route_table.spoke.id
}

# ---- ECS (spoke) ------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = var.name
  tags = { Name = var.name }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = 1
  tags              = { Name = var.name }
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = { Name = "${var.name}-exec" }
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = { Name = "${var.name}-task" }
}

resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "Fargate task egress all (public pull + guardduty-data via TGW)"
  vpc_id      = aws_vpc.spoke.id
  tags        = { Name = "${var.name}-task" }
}

resource "aws_vpc_security_group_egress_rule" "task_all" {
  security_group_id = aws_security_group.task.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.app_image
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])

  tags = { Name = var.name }
}

resource "aws_ecs_service" "app" {
  name             = var.name
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = [for s in aws_subnet.spoke : s.id]
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # public 経由で image / ECS API を pull
  }

  wait_for_steady_state = false
  tags                  = { Name = var.name }
}
