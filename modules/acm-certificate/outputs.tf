/**
 * modules/acm-certificate/outputs.tf
 */

output "certificate_arn" {
  description = "ARN of the certificate. When wait_for_validation is true this is only known once the certificate is ISSUED, which usefully orders any dependent CloudFront distribution after validation."
  value       = var.wait_for_validation ? aws_acm_certificate_validation.this[0].certificate_arn : aws_acm_certificate.this.arn
}

output "certificate_status" {
  description = "Certificate status: PENDING_VALIDATION, ISSUED, FAILED and so on."
  value       = aws_acm_certificate.this.status
}

output "domain_validation_options" {
  description = "Validation records ACM expects. Create these in whatever manages your DNS. Each entry has domain_name, resource_record_name, resource_record_type and resource_record_value."
  value       = aws_acm_certificate.this.domain_validation_options
}

output "validation_records_table" {
  description = "domain_validation_options rendered as a tab-separated table for manual entry in a DNS provider's zone editor. Read it with `terraform output -raw`."
  value = join("\n", concat(
    ["NAME\tTYPE\tVALUE"],
    distinct([
      for o in aws_acm_certificate.this.domain_validation_options :
      "${o.resource_record_name}\t${o.resource_record_type}\t${o.resource_record_value}"
    ]),
  ))
}
