/**
 * outputs.tf
 */

output "bucket_id" {
  description = "Name of the origin S3 bucket. Use this as the aws s3 sync target."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the origin S3 bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional REST endpoint of the origin bucket, used as the CloudFront origin domain."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "distribution_id" {
  description = "Identifier of the CloudFront distribution. Pass this to `aws cloudfront create-invalidation --distribution-id`."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "ARN of the CloudFront distribution."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The d111111abcdef8.cloudfront.net domain name. Point your DNS records here."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "Route 53 hosted zone id for CloudFront, for use in an alias record."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "distribution_status" {
  description = "Current status of the distribution, e.g. Deployed."
  value       = aws_cloudfront_distribution.this.status
}

output "origin_access_control_id" {
  description = "Identifier of the origin access control used by the distribution."
  value       = local.origin_access_control_id
}

output "spa_function_arn" {
  description = "ARN of the CloudFront Function handling SPA routing, or null when spa_routing_mode does not create one."
  value       = local.use_function ? aws_cloudfront_function.spa[0].arn : null
}

output "certificate_arn" {
  description = "Viewer certificate ARN in use, or null when the default CloudFront certificate is used."
  value       = var.certificate_arn
}

output "deploy_policy_json" {
  description = "IAM policy document granting exactly what a CI deploy job needs: object sync into the origin bucket plus invalidation of this distribution. Attach it to your CI role."
  value       = data.aws_iam_policy_document.deploy.json
}
