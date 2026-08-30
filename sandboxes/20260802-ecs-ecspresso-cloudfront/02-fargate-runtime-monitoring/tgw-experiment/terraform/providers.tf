provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "aws-ecs-practice"
      Sandbox   = var.name
      ManagedBy = "terraform"
    }
  }
}
