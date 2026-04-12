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
