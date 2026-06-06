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

# Reads CLOUDFLARE_API_TOKEN from the environment.
# Create a token at https://dash.cloudflare.com/profile/api-tokens using the
# "Edit zone DNS" template, scoped to your domain's zone.
provider "cloudflare" {}
