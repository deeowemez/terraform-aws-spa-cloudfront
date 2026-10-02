# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the module is at `0.x`, minor releases may contain breaking changes to the variable
interface. Pin with `~> 0.1.0` (patch-only) until `1.0.0`.

## [Unreleased]

## [0.1.0]

Initial release.

### Added

- S3 origin bucket, private by default: all four public access blocks on,
  `BucketOwnerEnforced` ownership, SSE, optional versioning with a noncurrent-version
  expiry rule, and an optional TLS-only Deny in the bucket policy.
- CloudFront Origin Access Control named after the bucket, so multiple instances in one
  account cannot collide.
- Bucket policy granting the CloudFront service principal `s3:GetObject` only, conditioned
  on the distribution ARN, with `s3:ListBucket` available behind
  `origin_list_bucket_permission`.
- CloudFront distribution driven by managed cache and response headers policies, with
  `ordered_cache_behaviors`, `geo_restriction`, `logging` and `web_acl_id` inputs.
- SPA routing via `spa_routing_mode`: a viewer-request CloudFront Function that rewrites
  extensionless paths, custom error responses, or both.
- `deploy_policy_json` output: a least-privilege sync-and-invalidate policy scoped to the
  created bucket and distribution.
- `modules/acm-certificate` submodule for DNS-validated us-east-1 certificates, with a
  `validation_records_table` output for zones managed outside Terraform.

[Unreleased]: https://github.com/deeowemez/terraform-aws-spa-cloudfront/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/deeowemez/terraform-aws-spa-cloudfront/releases/tag/v0.1.0
