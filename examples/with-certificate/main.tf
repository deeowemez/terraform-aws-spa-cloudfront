/**
 * examples/with-certificate/main.tf
 *
 * A custom domain, with the certificate created by the bundled acm-certificate submodule.
 * DNS is assumed to live outside Terraform, so this needs the two-phase apply described in
 * the README.
 */

variable "domain_name" {
  description = "Apex domain to serve the site under."
  type        = string
  default     = "example.com"
}

provider "aws" {
  region = "eu-west-1"
}

# CloudFront viewer certificates must be in us-east-1 even when nothing else is.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "certificate" {
  source = "../../modules/acm-certificate"

  providers = { aws = aws.us_east_1 }

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]

  # DNS is managed by hand here, so do not block the apply waiting for ISSUED.
  wait_for_validation = false
}

module "site" {
  source = "../../"

  name    = "example-with-certificate"
  aliases = [var.domain_name, "www.${var.domain_name}"]

  # The certificate must already be ISSUED when this applies, or CloudFront rejects it
  # with InvalidViewerCertificate. See the README for the two-phase sequence.
  certificate_arn = module.certificate.certificate_arn
}
