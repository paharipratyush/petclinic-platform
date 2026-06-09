provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "cloudflare" {
  # Token read from CLOUDFLARE_API_TOKEN environment variable.
  # Required permissions: Zone:Read + DNS:Edit scoped to the domain's zone.
  # Store in a password manager — never commit to code or .tfvars.
}
