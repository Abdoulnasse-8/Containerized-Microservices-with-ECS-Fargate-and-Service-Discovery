terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { Project = "ecs-microservices", ManagedBy = "terraform" } }
}

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "me" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  # Un seul endroit pour décrire les 3 microservices
  services = {
    auth          = { path = "/api/auth/*", priority = 10 }
    notifications = { path = "/api/notifications/*", priority = 20 }
    orders        = { path = "/api/orders/*", priority = 30 }
  }
}
