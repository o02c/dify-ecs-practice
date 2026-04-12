"""
S3 にアップロードされた Docker イメージ tar(.tar.gz) を crane で ECR に push する Lambda。

環境変数:
  ECR_REPO_URI: push 先の ECR リポジトリ URI
  AWS_REGION: リージョン (Lambda が自動設定)
"""

import json
import logging
import os
import subprocess
import urllib.parse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CRANE_PATH = "/opt/crane"
ECR_REPO_URI = os.environ["ECR_REPO_URI"]

# Lambda の /home は read-only なので、crane の Docker config を /tmp に向ける
os.environ["DOCKER_CONFIG"] = "/tmp/.docker"


def get_ecr_password():
    """boto3 で ECR 認証トークンを取得する。"""
    import boto3

    client = boto3.client("ecr")
    resp = client.get_authorization_token()
    token = resp["authorizationData"][0]["authorizationToken"]

    import base64

    decoded = base64.b64decode(token).decode("utf-8")
    # "AWS:<password>" 形式
    return decoded.split(":", 1)[1]


def handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    # EventBridge 経由の S3 イベント
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    key = urllib.parse.unquote_plus(detail.get("object", {}).get("key", ""))

    if not bucket or not key:
        logger.error("Could not extract bucket/key from event")
        return {"statusCode": 400, "body": "Invalid event"}

    if not key.endswith((".tar.gz", ".tar")):
        logger.info("Skipping non-tar file: %s", key)
        return {"statusCode": 200, "body": "Skipped"}

    # S3 キーからタグを決定 (例: images/myapp-v1.2.tar.gz → myapp-v1.2)
    basename = os.path.basename(key)
    tag = basename.replace(".tar.gz", "").replace(".tar", "")

    local_path = f"/tmp/{basename}"
    ecr_target = f"{ECR_REPO_URI}:{tag}"

    logger.info("Downloading s3://%s/%s to %s", bucket, key, local_path)

    # S3 からダウンロード
    import boto3

    s3 = boto3.client("s3")
    s3.download_file(bucket, key, local_path)

    file_size = os.path.getsize(local_path)
    logger.info("Downloaded %s (%.1f MB)", local_path, file_size / 1024 / 1024)

    # .tar.gz の場合は gunzip する (crane push は非圧縮 tar を期待)
    if local_path.endswith(".tar.gz"):
        import gzip
        import shutil

        tar_path = local_path.removesuffix(".gz")
        with gzip.open(local_path, "rb") as f_in, open(tar_path, "wb") as f_out:
            shutil.copyfileobj(f_in, f_out)
        os.remove(local_path)
        local_path = tar_path
        logger.info("Decompressed to %s (%.1f MB)", tar_path, os.path.getsize(tar_path) / 1024 / 1024)

    # ECR ログイン (crane 用)
    password = get_ecr_password()
    registry = ECR_REPO_URI.split("/")[0]

    login_result = subprocess.run(
        [CRANE_PATH, "auth", "login", registry, "-u", "AWS", "--password-stdin"],
        input=password,
        capture_output=True,
        text=True,
    )
    if login_result.returncode != 0:
        logger.error("crane auth login failed: %s", login_result.stderr)
        raise RuntimeError(f"crane auth login failed: {login_result.stderr}")

    logger.info("ECR login succeeded")

    # crane push
    logger.info("Pushing %s → %s", local_path, ecr_target)
    push_result = subprocess.run(
        [CRANE_PATH, "push", local_path, ecr_target],
        capture_output=True,
        text=True,
    )

    if push_result.returncode != 0:
        logger.error("crane push failed: %s", push_result.stderr)
        raise RuntimeError(f"crane push failed: {push_result.stderr}")

    logger.info("Push succeeded: %s", push_result.stdout.strip())

    # クリーンアップ
    os.remove(local_path)

    return {
        "statusCode": 200,
        "body": json.dumps({"pushed": ecr_target}),
    }
