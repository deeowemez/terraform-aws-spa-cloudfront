/**
 * examples/with-certificate/outputs.tf
 */

output "validation_records_table" {
  description = "Create these records in your DNS provider, then wait for the certificate to reach ISSUED."
  value       = module.certificate.validation_records_table
}

output "certificate_arn" {
  description = "ARN of the certificate, for polling its status with the AWS CLI."
  value       = module.certificate.certificate_arn
}

output "certificate_status" {
  description = "PENDING_VALIDATION until the records above are published and ACM picks them up."
  value       = module.certificate.certificate_status
}

output "bucket_id" {
  description = "Sync your build output here."
  value       = module.site.bucket_id
}

output "distribution_domain_name" {
  description = "Point the site CNAMEs at this."
  value       = module.site.distribution_domain_name
}
