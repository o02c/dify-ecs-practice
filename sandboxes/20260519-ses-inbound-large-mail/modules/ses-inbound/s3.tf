resource "aws_s3_bucket" "archive" {
  bucket        = "${var.name}-archive-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "archive-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = var.archive_lifecycle_ia_days
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.archive_lifecycle_expiration_days
    }
  }
}

data "aws_iam_policy_document" "archive_bucket_policy" {
  statement {
    sid     = "AllowSESPutObject"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.archive.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id
  policy = data.aws_iam_policy_document.archive_bucket_policy.json
}

# inbox/ prefix の S3 オブジェクト作成イベントを SNS topic に publish
# (= SES が S3 に書き込んだ瞬間に Lambda 処理がトリガされる)
resource "aws_s3_bucket_notification" "archive" {
  bucket = aws_s3_bucket.archive.id

  topic {
    topic_arn     = aws_sns_topic.mail.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "inbox/"
  }

  depends_on = [aws_sns_topic_policy.mail]
}
