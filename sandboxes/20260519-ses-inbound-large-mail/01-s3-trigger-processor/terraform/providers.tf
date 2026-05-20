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

# AWS Chatbot は us-east-2 専用 API
provider "aws" {
  alias  = "us_east_2"
  region = "us-east-2"

  default_tags {
    tags = {
      Project   = "aws-ecs-practice"
      Sandbox   = var.sandbox_name
      ManagedBy = "terraform"
    }
  }
}
