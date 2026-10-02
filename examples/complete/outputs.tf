/**
 * examples/complete/outputs.tf
 */

output "bucket_id" {
  description = "Generated bucket name — read it from here rather than guessing, since bucket_prefix lets AWS pick the suffix."
  value       = module.site.bucket_id
}

output "distribution_id" {
  description = "Use this to invalidate the cache after a deploy."
  value       = module.site.distribution_id
}

output "distribution_domain_name" {
  description = "The distribution's own domain name."
  value       = module.site.distribution_domain_name
}

output "spa_function_arn" {
  description = "ARN of the CloudFront Function rewriting extensionless paths."
  value       = module.site.spa_function_arn
}

output "ci_role_arn" {
  description = "Role a CI job assumes to sync content and invalidate the cache."
  value       = aws_iam_role.ci.arn
}
