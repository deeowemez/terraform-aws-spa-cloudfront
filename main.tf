/**
 * Serves a single-page application from a private S3 bucket through CloudFront, with
 * origin access control and deep-link routing.
 *
 * The origin is the S3 **REST** endpoint fronted by an Origin Access Control, not the S3
 * website endpoint. That is what keeps the bucket private, but it also means S3's
 * `error_document` never runs — so SPA deep links are handled at the edge instead, by a
 * CloudFront Function that rewrites extensionless paths and a set of custom error
 * responses as a safety net.
 */

locals {
  # `bucket` and `bucket_prefix` are mutually exclusive on aws_s3_bucket; exactly one is
  # non-null here. Validation on var.bucket_prefix guarantees both are never set.
  bucket_name = (
    var.bucket_name != null ? var.bucket_name :
    var.bucket_prefix != null ? null :
    "${var.name}-origin"
  )

  origin_id = "s3-${aws_s3_bucket.this.id}"

  create_oac = var.origin_access_control_id == null
  origin_access_control_id = (
    var.origin_access_control_id != null
    ? var.origin_access_control_id
    : aws_cloudfront_origin_access_control.this[0].id
  )

  cache_policy_id = (
    var.cache_policy_id != null
    ? var.cache_policy_id
    : data.aws_cloudfront_cache_policy.this[0].id
  )

  response_headers_policy_id = (
    var.response_headers_policy_id != null ? var.response_headers_policy_id :
    var.response_headers_policy_name != null ? data.aws_cloudfront_response_headers_policy.this[0].id :
    null
  )

  comment           = coalesce(var.comment, "${var.name} static site")
  spa_fallback_path = coalesce(var.spa_fallback_path, "/${var.default_root_object}")

  use_function       = contains(["cloudfront_function", "both"], var.spa_routing_mode)
  use_error_response = contains(["error_response", "both"], var.spa_routing_mode)

  # Keyed by error_code so the SPA entries deterministically win over any caller-supplied
  # entry for the same code. Both maps are built with identical attribute sets so that
  # merge() can unify their types.
  spa_error_responses = local.use_error_response ? {
    for code in var.spa_fallback_error_codes : tostring(code) => {
      error_code            = code
      response_code         = var.spa_fallback_response_code
      response_page_path    = local.spa_fallback_path
      error_caching_min_ttl = var.spa_fallback_caching_min_ttl
    }
  } : {}

  extra_error_responses = {
    for e in var.custom_error_responses : tostring(e.error_code) => {
      error_code            = e.error_code
      response_code         = e.response_code
      response_page_path    = e.response_page_path
      error_caching_min_ttl = e.error_caching_min_ttl
    }
  }

  error_responses = merge(local.extra_error_responses, local.spa_error_responses)
}

data "aws_cloudfront_cache_policy" "this" {
  count = var.cache_policy_id == null ? 1 : 0
  name  = var.cache_policy_name
}

data "aws_cloudfront_response_headers_policy" "this" {
  count = var.response_headers_policy_id == null && var.response_headers_policy_name != null ? 1 : 0
  name  = var.response_headers_policy_name
}

# ---------------------------------------------------------------------------
# Origin bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  bucket_prefix = var.bucket_prefix
  force_destroy = var.bucket_force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  count = var.bucket_versioning_enabled ? 1 : 0

  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.bucket_sse_algorithm
      kms_master_key_id = var.bucket_kms_key_arn
    }

    bucket_key_enabled = var.bucket_sse_algorithm == "aws:kms"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count = var.bucket_versioning_enabled && var.bucket_noncurrent_version_expiration_days != null ? 1 : 0

  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.bucket_noncurrent_version_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  # s3:ListBucket is a BUCKET-level action: its resource is the bucket ARN with no "/*".
  # Granting it makes S3 return 404 rather than 403 for a missing key.
  dynamic "statement" {
    for_each = var.origin_list_bucket_permission ? [1] : []

    content {
      sid       = "AllowCloudFrontServicePrincipalList"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.this.arn]

      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.this.arn]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enforce_tls_bucket_policy ? [1] : []

    content {
      sid       = "DenyInsecureTransport"
      effect    = "Deny"
      actions   = ["s3:*"]
      resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "Bool"
        variable = "aws:SecureTransport"
        values   = ["false"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "this" {
  count = local.create_oac ? 1 : 0

  # Derived from the bucket id, which is globally unique, so the OAC name cannot collide
  # with another instance of this module in the same account.
  name                              = coalesce(var.origin_access_control_name, substr("${aws_s3_bucket.this.id}-oac", 0, 64))
  description                       = "Origin access control for ${aws_s3_bucket.this.id}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "spa" {
  count = local.use_function ? 1 : 0

  name    = "${var.name}-spa-router"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrites extensionless paths to ${local.spa_fallback_path} for client-side routing"
  publish = true

  code = <<-EOT
    function handler(event) {
        var request = event.request;
        var segments = request.uri.split('/');
        var last = segments[segments.length - 1];

        // A final segment with no dot is a client-side route, not a file. Rewrite it so
        // S3 serves the SPA entrypoint with a genuine 200 and the router takes over.
        // Anything that looks like a file falls through and fails honestly, rather than
        // being handed HTML and producing "Unexpected token '<'".
        if (last.indexOf('.') === -1) {
            request.uri = '${local.spa_fallback_path}';
        }

        return request;
    }
  EOT
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = var.enabled
  is_ipv6_enabled     = var.is_ipv6_enabled
  http_version        = var.http_version
  comment             = local.comment
  default_root_object = var.default_root_object
  price_class         = var.price_class
  aliases             = var.aliases
  web_acl_id          = var.web_acl_id
  tags                = var.tags

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = local.origin_id
    origin_access_control_id = local.origin_access_control_id
    origin_path              = var.origin_path
  }

  default_cache_behavior {
    target_origin_id           = local.origin_id
    allowed_methods            = var.allowed_methods
    cached_methods             = var.cached_methods
    viewer_protocol_policy     = var.viewer_protocol_policy
    compress                   = var.compress
    cache_policy_id            = local.cache_policy_id
    origin_request_policy_id   = var.origin_request_policy_id
    response_headers_policy_id = local.response_headers_policy_id

    dynamic "function_association" {
      for_each = local.use_function ? [1] : []

      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.spa[0].arn
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.ordered_cache_behaviors

    content {
      path_pattern               = ordered_cache_behavior.value.path_pattern
      target_origin_id           = local.origin_id
      allowed_methods            = ordered_cache_behavior.value.allowed_methods
      cached_methods             = ordered_cache_behavior.value.cached_methods
      viewer_protocol_policy     = ordered_cache_behavior.value.viewer_protocol_policy
      compress                   = ordered_cache_behavior.value.compress
      cache_policy_id            = coalesce(ordered_cache_behavior.value.cache_policy_id, local.cache_policy_id)
      origin_request_policy_id   = ordered_cache_behavior.value.origin_request_policy_id
      response_headers_policy_id = ordered_cache_behavior.value.response_headers_policy_id
    }
  }

  # custom_error_response is distribution-level and cannot be scoped to a cache behaviour,
  # which is why the CloudFront Function above exists alongside it.
  dynamic "custom_error_response" {
    for_each = local.error_responses

    content {
      error_code            = custom_error_response.value.error_code
      response_code         = custom_error_response.value.response_code
      response_page_path    = custom_error_response.value.response_page_path
      error_caching_min_ttl = custom_error_response.value.error_caching_min_ttl
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction.restriction_type
      locations        = var.geo_restriction.locations
    }
  }

  dynamic "logging_config" {
    for_each = var.logging != null ? [var.logging] : []

    content {
      bucket          = logging_config.value.bucket
      prefix          = logging_config.value.prefix
      include_cookies = logging_config.value.include_cookies
    }
  }

  # acm_certificate_arn and cloudfront_default_certificate are mutually exclusive, and
  # minimum_protocol_version is rejected alongside the default certificate.
  dynamic "viewer_certificate" {
    for_each = var.certificate_arn == null ? [1] : []

    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.certificate_arn == null ? [] : [1]

    content {
      acm_certificate_arn      = var.certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = var.minimum_protocol_version
    }
  }

  lifecycle {
    precondition {
      condition     = var.certificate_arn != null || length(var.aliases) == 0
      error_message = "aliases require certificate_arn: the default CloudFront certificate cannot serve alternate domain names."
    }
  }
}

# ---------------------------------------------------------------------------
# Deploy policy, for a CI role that syncs content and invalidates the cache
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy" {
  statement {
    sid    = "SyncSiteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid       = "ListSiteBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid    = "InvalidateDistribution"
    effect = "Allow"
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
      "cloudfront:ListInvalidations",
    ]
    resources = [aws_cloudfront_distribution.this.arn]
  }

  # Uploading into a bucket encrypted with a customer managed key needs key permissions on
  # the IAM side too. The key policy must also allow this principal.
  dynamic "statement" {
    for_each = var.bucket_kms_key_arn != null ? [1] : []

    content {
      sid    = "UseBucketKmsKey"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = [var.bucket_kms_key_arn]
    }
  }
}
