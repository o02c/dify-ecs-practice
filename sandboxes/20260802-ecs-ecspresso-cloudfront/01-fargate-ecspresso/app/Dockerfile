# ECS(Fargate) の backend アプリ。/ は health check 用、/api/ は動作確認用。
# ローカルから直接 ECR に push する前提 (VPC 内は private + VPC Endpoint で pull)。
#   docker build --platform linux/amd64 -t <ecr_url>:latest .
FROM public.ecr.aws/nginx/nginx:alpine

COPY index.html /usr/share/nginx/html/index.html
COPY api/index.html /usr/share/nginx/html/api/index.html
