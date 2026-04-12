data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  prefix     = var.sandbox_name
}

# --------------------------------------------------------------------------
# VPC (private subnet only)
# --------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.prefix}-vpc" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${local.region}a"

  tags = { Name = "${local.prefix}-private-a" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${local.region}c"

  tags = { Name = "${local.prefix}-private-c" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-private-rt" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

# --------------------------------------------------------------------------
# VPC Endpoints
# --------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${local.prefix}-s3-endpoint" }
}

resource "aws_security_group" "endpoints" {
  name_prefix = "${local.prefix}-endpoints-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-endpoints-sg" }
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.prefix}-ecr-api" }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.prefix}-ecr-dkr" }
}

# --------------------------------------------------------------------------
# S3 bucket (イメージ受け渡し用、EventBridge 通知有効)
# --------------------------------------------------------------------------
resource "aws_s3_bucket" "images" {
  bucket_prefix = "${local.prefix}-images-"
  force_destroy = true

  tags = { Name = "${local.prefix}-images" }
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_notification" "images" {
  bucket      = aws_s3_bucket.images.id
  eventbridge = true
}

# --------------------------------------------------------------------------
# ECR repository
# --------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name         = "${local.prefix}-app"
  force_delete = true

  tags = { Name = "${local.prefix}-app" }
}

# --------------------------------------------------------------------------
# crane バイナリのダウンロード & Lambda zip ビルド
# --------------------------------------------------------------------------
resource "null_resource" "build_lambda" {
  triggers = {
    handler_hash = filesha256("${path.module}/lambda/handler.py")
    crane_ver    = var.crane_version
  }

  provisioner "local-exec" {
    working_dir = path.module
    command     = <<-EOT
      set -e
      mkdir -p build/layer/bin build/function

      # Lambda 実行環境用に Linux x86_64 バイナリを取得
      if [ ! -f build/layer/bin/crane-linux ]; then
        curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${var.crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
          | tar xz -C build/layer/bin crane
        mv build/layer/bin/crane build/layer/bin/crane-linux
      fi

      # レイヤー zip 作成 (Lambda は /opt/crane で参照)
      cd build/layer
      mkdir -p bin_final
      cp bin/crane-linux bin_final/crane
      chmod +x bin_final/crane
      cd bin_final && zip -r ../../crane-layer.zip crane && cd ..

      # Lambda 関数 zip 作成
      cd ../function
      cp ../../lambda/handler.py .
      zip -r ../function.zip handler.py
    EOT
  }
}

data "local_file" "crane_layer_zip" {
  filename   = "${path.module}/build/crane-layer.zip"
  depends_on = [null_resource.build_lambda]
}

data "local_file" "function_zip" {
  filename   = "${path.module}/build/function.zip"
  depends_on = [null_resource.build_lambda]
}

# --------------------------------------------------------------------------
# Lambda Layer (crane binary)
# --------------------------------------------------------------------------
resource "aws_lambda_layer_version" "crane" {
  layer_name          = "${local.prefix}-crane"
  filename            = "${path.module}/build/crane-layer.zip"
  compatible_runtimes = ["python3.12"]
  source_code_hash    = data.local_file.crane_layer_zip.content_base64sha256

  depends_on = [null_resource.build_lambda]
}

# --------------------------------------------------------------------------
# IAM role for Lambda
# --------------------------------------------------------------------------
resource "aws_iam_role" "lambda" {
  name_prefix = "${local.prefix}-lambda-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3_ecr" {
  name_prefix = "${local.prefix}-s3-ecr-"
  role        = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.images.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      }
    ]
  })
}

# --------------------------------------------------------------------------
# Lambda function
# --------------------------------------------------------------------------
resource "aws_security_group" "lambda" {
  name_prefix = "${local.prefix}-lambda-"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-lambda-sg" }
}

resource "aws_lambda_function" "push_to_ecr" {
  function_name    = "${local.prefix}-push-to-ecr"
  filename         = "${path.module}/build/function.zip"
  source_code_hash = data.local_file.function_zip.content_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 512
  role             = aws_iam_role.lambda.arn

  ephemeral_storage {
    size = 2048
  }

  layers = [aws_lambda_layer_version.crane.arn]

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      ECR_REPO_URI = aws_ecr_repository.app.repository_url
    }
  }

  depends_on = [null_resource.build_lambda]
}

# --------------------------------------------------------------------------
# EventBridge rule (S3 PutObject → Lambda)
# --------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "s3_put" {
  name_prefix = "${local.prefix}-s3-put-"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.images.id] }
      object = { key = [{ suffix = ".tar.gz" }, { suffix = ".tar" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.s3_put.name
  arn  = aws_lambda_function.push_to_ecr.arn
}

resource "aws_lambda_permission" "eventbridge" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.push_to_ecr.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_put.arn
}
