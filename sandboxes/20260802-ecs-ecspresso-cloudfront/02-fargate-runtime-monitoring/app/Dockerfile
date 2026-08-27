# 常駐すれば何でもよい。GuardDuty のサイドカーはこのコンテナと並んで注入される。
# ベースは public ECR(ローカルは push 時のみインターネットを使う。Fargate 側の pull は
# 私有 ECR + VPC endpoint 経由で完結する)。
FROM public.ecr.aws/nginx/nginx:alpine
