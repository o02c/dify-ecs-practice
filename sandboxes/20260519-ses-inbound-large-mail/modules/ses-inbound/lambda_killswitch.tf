data "archive_file" "killswitch" {
  count = var.enable_killswitch ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/killswitch/handler.py"
  output_path = "${path.module}/.build/killswitch.zip"
}

data "aws_iam_policy_document" "killswitch_inline" {
  count = var.enable_killswitch ? 1 : 0

  statement {
    sid       = "AllowSetActiveReceiptRuleSet"
    effect    = "Allow"
    actions   = ["ses:SetActiveReceiptRuleSet"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "killswitch" {
  count = var.enable_killswitch ? 1 : 0

  name               = "${var.name}-killswitch"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy" "killswitch" {
  count = var.enable_killswitch ? 1 : 0

  name   = "ses-deactivate"
  role   = aws_iam_role.killswitch[0].id
  policy = data.aws_iam_policy_document.killswitch_inline[0].json
}

resource "aws_iam_role_policy_attachment" "killswitch_basic" {
  count = var.enable_killswitch ? 1 : 0

  role       = aws_iam_role.killswitch[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "killswitch" {
  count = var.enable_killswitch ? 1 : 0

  name              = "/aws/lambda/${var.name}-killswitch"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "killswitch" {
  count = var.enable_killswitch ? 1 : 0

  function_name    = "${var.name}-killswitch"
  role             = aws_iam_role.killswitch[0].arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.killswitch[0].output_path
  source_code_hash = data.archive_file.killswitch[0].output_base64sha256
  timeout          = 30
  memory_size      = 128

  depends_on = [aws_cloudwatch_log_group.killswitch]
}

resource "aws_lambda_permission" "sns_invoke_killswitch" {
  count = var.enable_killswitch ? 1 : 0

  statement_id  = "AllowSNSInvokeKillswitch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.killswitch[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.killswitch[0].arn
}

resource "aws_sns_topic_subscription" "killswitch" {
  count = var.enable_killswitch ? 1 : 0

  topic_arn = aws_sns_topic.killswitch[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.killswitch[0].arn

  depends_on = [aws_lambda_permission.sns_invoke_killswitch]
}
