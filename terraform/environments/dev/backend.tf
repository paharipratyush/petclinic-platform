terraform {
  backend "s3" {
    bucket         = "petclinic-terraform-state-568521409121"
    key            = "petclinic/dev/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "petclinic-terraform-locks"
    encrypt        = true
  }
}
