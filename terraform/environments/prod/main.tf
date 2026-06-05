module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  vpc_cidr = "10.1.0.0/16"

  public_subnet_cidrs = [
    "10.1.1.0/24",
    "10.1.2.0/24",
  ]

  availability_zones = [
    "eu-central-1a",
    "eu-central-1b",
  ]
}
