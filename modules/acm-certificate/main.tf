/**
 * # acm-certificate
 *
 * Creates a DNS-validated ACM certificate for a CloudFront distribution.
 *
 * CloudFront viewer certificates must live in us-east-1, so pass a us-east-1 provider to
 * this module block. The module does not create DNS records: it emits the validation
 * records to create, so it works whether your zone is in Route 53 or at another provider.
 */

data "aws_region" "current" {}

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = var.validation_method
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      # id, not region or name: the attribute was renamed between provider v5 (name) and
      # v6 (region, with name deprecated), and id holds the region name in both.
      condition     = data.aws_region.current.id == "us-east-1"
      error_message = "CloudFront viewer certificates must be created in us-east-1. Pass a us-east-1 provider to this module, e.g. providers = { aws = aws.us_east_1 }."
    }
  }
}

# Only created when asked for: without the validation records already in DNS this blocks
# for validation_timeout and then fails, leaving a half-built stack.
resource "aws_acm_certificate_validation" "this" {
  count = var.wait_for_validation ? 1 : 0

  certificate_arn = aws_acm_certificate.this.arn

  validation_record_fqdns = coalesce(
    var.validation_record_fqdns,
    [for o in aws_acm_certificate.this.domain_validation_options : o.resource_record_name],
  )

  timeouts {
    create = var.validation_timeout
  }
}
