/**
 * examples/simple/outputs.tf
 */

output "bucket_id" {
  description = "Sync your build output here."
  value       = module.site.bucket_id
}

output "distribution_domain_name" {
  description = "Open this once the distribution reaches Deployed."
  value       = module.site.distribution_domain_name
}

output "distribution_id" {
  description = "Use this to invalidate the cache after a deploy."
  value       = module.site.distribution_id
}
