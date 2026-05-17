provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aws-ecs-practice"
      Sandbox   = var.sandbox_name
      ManagedBy = "terraform"
    }
  }
}

# Route53 Domains は us-east-1 endpoint のみ
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "aws-ecs-practice"
      Sandbox   = var.sandbox_name
      ManagedBy = "terraform"
    }
  }
}
