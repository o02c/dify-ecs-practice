data "archive_file" "processor" {
  type        = "zip"
  source_file = "${path.module}/lambda/processor/handler.py"
  output_path = "${path.module}/.build/processor.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "processor" {
  name               = "${var.name}-processor"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "processor_basic" {
  role       = aws_iam_role.processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# archived raw MIME を S3 から読むため inline policy で s3:GetObject を許可
data "aws_iam_policy_document" "processor_read_archive" {
  statement {
    sid       = "ReadArchivedEmails"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.archive.arn}/*"]
  }
}

resource "aws_iam_role_policy" "processor_read_archive" {
  name   = "read-archive"
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor_read_archive.json
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${var.name}-processor"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "processor" {
  function_name    = "${var.name}-processor"
  role             = aws_iam_role.processor.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      ALLOW_LIST_DOMAINS = join(",", var.allow_list_domains)
    }
  }

  # Lambda 関数自体の失敗 (async invoke 3 attempts 全失敗) を SQS DLQ にキャプチャする。
  # SNS subscription の redrive_policy は SNS->Lambda invoke 自体の失敗のみ拾うので、
  # 「Lambda が起動して関数内で例外」を拾うにはこちらの設定が必要。
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  depends_on = [aws_cloudwatch_log_group.processor]
}

# Lambda 実行ロールに DLQ への SendMessage 権限を付与
data "aws_iam_policy_document" "processor_dlq_write" {
  statement {
    sid       = "WriteFailedInvocationsToDLQ"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda_dlq.arn]
  }
}

resource "aws_iam_role_policy" "processor_dlq_write" {
  name   = "dlq-write"
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor_dlq_write.json
}

resource "aws_lambda_permission" "sns_invoke_processor" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.mail.arn
}

resource "aws_sns_topic_subscription" "processor" {
  topic_arn = aws_sns_topic.mail.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.processor.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.lambda_dlq.arn
  })

  depends_on = [aws_lambda_permission.sns_invoke_processor]
}
