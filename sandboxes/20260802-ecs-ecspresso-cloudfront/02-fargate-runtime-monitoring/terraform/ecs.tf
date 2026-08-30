# =========================================================================
# ECS cluster + Fargate service(LB なし・desiredCount=1)
#
# 監視観測が目的なので ecspresso は使わず、taskdef / service を Terraform で直接定義する
# (01 は「TF=土台 / ecspresso=service」だったが、ここでは air-gapped deploy を再現しないため
#  素朴に TF 一本にまとめる)。
# =========================================================================

resource "aws_ecs_cluster" "this" {
  name = var.sandbox_name

  # ここでは触らない(GuardDuty の GuardDutyManaged タグは runbook で手動検証する)。
  tags = { Name = var.sandbox_name }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.sandbox_name}"
  retention_in_days = 7

  tags = { Name = var.sandbox_name }
}

# ---- ECR(アプリイメージ置き場)---------------------------------------
resource "aws_ecr_repository" "app" {
  name         = "${var.sandbox_name}-app"
  force_delete = true

  tags = { Name = "${var.sandbox_name}-app" }
}

# ---- IAM --------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 実行ロール: ECR pull + Logs 書き込み。
# GuardDuty サイドカー image の pull もこの実行ロールで行われるため必須。
# (未設定だと coverage Issue "TaskExecutionRole missing from TaskDefinition")
resource "aws_iam_role" "task_execution" {
  name               = "${var.sandbox_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${var.sandbox_name}-exec" }
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# タスクロール: アプリ用。GuardDuty のテレメトリ送信は endpoint 経由なので
# タスクロールに GuardDuty 権限は不要(最小のまま)。
resource "aws_iam_role" "task" {
  name               = "${var.sandbox_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${var.sandbox_name}-task" }
}

# ---- task definition --------------------------------------------------
# platformVersion は LATEST(>= 1.4.0 が GuardDuty の要件)。X86_64 / LINUX。
resource "aws_ecs_task_definition" "app" {
  family                   = var.sandbox_name
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
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      # nginx:alpine を私有 ECR に push したもの(push-image.sh)。常駐すれば何でもよい。
      portMappings = [{ containerPort = 80, protocol = "tcp" }]
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

  tags = { Name = var.sandbox_name }
}

# ---- service(LB なし・常駐 1 本)--------------------------------------
resource "aws_ecs_service" "app" {
  name             = var.sandbox_name
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  # image をまだ push していない初回 apply でも service 作成を通すため、
  # タスク起動失敗で apply を止めない(image push 後に自然収束する)。
  wait_for_steady_state = false

  tags = { Name = var.sandbox_name }
}
