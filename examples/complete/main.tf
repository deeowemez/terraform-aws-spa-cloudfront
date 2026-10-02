/**
 * examples/complete/main.tf
 *
 * Exercises most of the module's surface: an explicit bucket name, a WAF-less but
 * geo-restricted distribution, a tightened cache behaviour for hashed assets, honest 404s
 * from the origin, and a CI role wired to the module's own deploy policy.
 */

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "example"
      Environment = "sandbox"
    }
  }
}

module "site" {
  source = "../../"

  name          = "example-complete"
  bucket_prefix = "example-complete-"

  # --- bucket ---
  bucket_versioning_enabled                 = true
  bucket_noncurrent_version_expiration_days = 14
  bucket_force_destroy                      = true # sandbox only
  enforce_tls_bucket_policy                 = true

  # Honest 404s from the origin, so a genuine permission failure is not masked as a 200.
  # Safe here only because nothing forwards query strings to the origin.
  origin_list_bucket_permission = true

  # --- SPA routing ---
  spa_routing_mode         = "both"
  spa_fallback_error_codes = [404] # narrowed, because ListBucket is granted above

  # --- distribution ---
  price_class  = "PriceClass_200"
  http_version = "http2and3"

  geo_restriction = {
    restriction_type = "blacklist"
    locations        = ["CU", "IR", "KP", "SY"]
  }

  # Hashed asset filenames are immutable, so they can be cached hard and need no SPA
  # fallback behaviour of their own.
  ordered_cache_behaviors = [
    {
      path_pattern           = "/assets/*"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      viewer_protocol_policy = "https-only"
      compress               = true
    },
  ]

  tags = {
    Component = "frontend"
  }
}

# --- a CI role built from the module's own deploy policy ---

data "aws_iam_policy_document" "ci_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "example-complete-deploy"
  assume_role_policy = data.aws_iam_policy_document.ci_assume.json
}

resource "aws_iam_role_policy" "ci" {
  name = "example-complete-deploy"
  role = aws_iam_role.ci.id

  # Sync + invalidate, scoped to exactly this bucket and this distribution. Nothing to
  # keep in sync by hand, and it cannot drift from what the module actually created.
  policy = module.site.deploy_policy_json
}
