/**
 * variables.tf
 */

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name used to derive names for the created resources. Lowercase alphanumerics and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,36}$", var.name))
    error_message = "name must start with a lowercase alphanumeric and contain only lowercase alphanumerics and hyphens (max 37 characters)."
  }
}

variable "bucket_name" {
  description = "Exact name of the origin bucket. Must be globally unique. Mutually exclusive with bucket_prefix. When both are null the bucket is named \"<name>-origin\"."
  type        = string
  default     = null
}

variable "bucket_prefix" {
  description = "Create the origin bucket with an AWS-generated unique name starting with this prefix (max 37 characters). Mutually exclusive with bucket_name. Use this when you do not want to own global-namespace collisions; read the resulting name from the bucket_id output."
  type        = string
  default     = null

  validation {
    condition     = var.bucket_prefix == null || var.bucket_name == null
    error_message = "Set at most one of bucket_name or bucket_prefix."
  }
}

# ---------------------------------------------------------------------------
# Origin bucket
# ---------------------------------------------------------------------------

variable "bucket_force_destroy" {
  description = "Delete all objects in the origin bucket when the bucket is destroyed. Enable only for ephemeral environments; without it a destroy fails on a non-empty bucket."
  type        = bool
  default     = false
}

variable "bucket_versioning_enabled" {
  description = "Enable versioning on the origin bucket. Recommended: a mistaken `aws s3 sync --delete` is otherwise unrecoverable."
  type        = bool
  default     = true
}

variable "bucket_noncurrent_version_expiration_days" {
  description = "Expire noncurrent object versions after this many days. Null disables the lifecycle rule. Ignored when bucket_versioning_enabled is false."
  type        = number
  default     = 30
}

variable "bucket_sse_algorithm" {
  description = "Server-side encryption algorithm for the origin bucket: AES256 or aws:kms."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "aws:kms"], var.bucket_sse_algorithm)
    error_message = "bucket_sse_algorithm must be AES256 or aws:kms."
  }
}

variable "bucket_kms_key_arn" {
  description = "Customer managed KMS key for the origin bucket. Requires bucket_sse_algorithm = \"aws:kms\". The key's own policy must grant kms:Decrypt to the CloudFront service principal and to your deploy role; a bucket policy cannot do that for you."
  type        = string
  default     = null

  validation {
    condition     = var.bucket_kms_key_arn == null || var.bucket_sse_algorithm == "aws:kms"
    error_message = "bucket_kms_key_arn requires bucket_sse_algorithm = \"aws:kms\"."
  }
}

variable "enforce_tls_bucket_policy" {
  description = "Add a Deny statement to the bucket policy rejecting requests where aws:SecureTransport is false."
  type        = bool
  default     = true
}

variable "origin_list_bucket_permission" {
  description = "Grant s3:ListBucket to the CloudFront service principal. S3 then returns 404 rather than 403 for a missing key, letting you narrow spa_fallback_error_codes to [404] so genuine permission failures surface instead of being masked as a 200. Do NOT enable alongside query-string forwarding: a signed ?list-type=2 request would return every object key in the bucket."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

variable "aliases" {
  description = "Alternate domain names (CNAMEs) served by the distribution. Every alias must be covered by the viewer certificate. Empty serves only the *.cloudfront.net domain."
  type        = list(string)
  default     = []
}

variable "default_root_object" {
  description = "Object returned when a viewer requests the distribution root."
  type        = string
  default     = "index.html"
}

variable "comment" {
  description = "Comment shown on the distribution in the console. Defaults to \"<name> static site\"."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether the distribution accepts end user requests."
  type        = bool
  default     = true
}

variable "is_ipv6_enabled" {
  description = "Enable IPv6 for the distribution."
  type        = bool
  default     = true
}

variable "http_version" {
  description = "Maximum HTTP version supported: http1.1, http2, http2and3 or http3."
  type        = string
  default     = "http2and3"

  validation {
    condition     = contains(["http1.1", "http2", "http2and3", "http3"], var.http_version)
    error_message = "http_version must be http1.1, http2, http2and3 or http3."
  }
}

variable "price_class" {
  description = "Edge location footprint: PriceClass_100 (NA + EU), PriceClass_200 (adds Asia, ME, Africa) or PriceClass_All."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "minimum_protocol_version" {
  description = "Minimum TLS version for viewer connections. Ignored when the default CloudFront certificate is used."
  type        = string
  default     = "TLSv1.2_2021"
}

variable "web_acl_id" {
  description = "WAFv2 web ACL ARN (scope CLOUDFRONT, therefore created in us-east-1) or a WAF Classic web ACL id. Null attaches no web ACL."
  type        = string
  default     = null
}

variable "geo_restriction" {
  description = "Geographic restriction. restriction_type is none, whitelist or blacklist; locations is a list of ISO 3166-1 alpha-2 codes."
  type = object({
    restriction_type = string
    locations        = optional(list(string), [])
  })
  default = {
    restriction_type = "none"
  }

  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction.restriction_type)
    error_message = "geo_restriction.restriction_type must be none, whitelist or blacklist."
  }
}

variable "logging" {
  description = "CloudFront standard (legacy) access logging. `bucket` must be the target bucket's DOMAIN NAME (e.g. logs.s3.amazonaws.com), and that bucket must have ACLs enabled with object ownership BucketOwnerPreferred — which conflicts with the BucketOwnerEnforced default AWS applies to new buckets. Null disables logging."
  type = object({
    bucket          = string
    prefix          = optional(string, "")
    include_cookies = optional(bool, false)
  })
  default = null
}

# ---------------------------------------------------------------------------
# Default cache behaviour
# ---------------------------------------------------------------------------

variable "allowed_methods" {
  description = "HTTP methods CloudFront forwards to the origin. An S3 REST origin only answers reads, so the default is read-only."
  type        = list(string)
  default     = ["GET", "HEAD", "OPTIONS"]
}

variable "cached_methods" {
  description = "HTTP methods for which CloudFront caches responses."
  type        = list(string)
  default     = ["GET", "HEAD"]
}

variable "viewer_protocol_policy" {
  description = "How CloudFront handles HTTP viewer requests: allow-all, https-only or redirect-to-https."
  type        = string
  default     = "redirect-to-https"

  validation {
    condition     = contains(["allow-all", "https-only", "redirect-to-https"], var.viewer_protocol_policy)
    error_message = "viewer_protocol_policy must be allow-all, https-only or redirect-to-https."
  }
}

variable "compress" {
  description = "Automatically compress objects for viewers that support it."
  type        = bool
  default     = true
}

variable "cache_policy_id" {
  description = "Cache policy id for the default behaviour. Takes precedence over cache_policy_name."
  type        = string
  default     = null
}

variable "cache_policy_name" {
  description = "Name of the cache policy to look up when cache_policy_id is null, e.g. Managed-CachingOptimized. Note its default TTL is 24 hours: upload your entrypoint with Cache-Control: no-cache and invalidate on deploy."
  type        = string
  default     = "Managed-CachingOptimized"

  validation {
    condition     = var.cache_policy_id != null || var.cache_policy_name != null
    error_message = "Set cache_policy_id or cache_policy_name. A cache behaviour without a cache policy would require legacy forwarded_values, which this module does not emit."
  }
}

variable "origin_request_policy_id" {
  description = "Origin request policy id for the default behaviour. Null attaches none, which is correct for a plain S3 origin."
  type        = string
  default     = null
}

variable "response_headers_policy_id" {
  description = "Response headers policy id for the default behaviour. Takes precedence over response_headers_policy_name."
  type        = string
  default     = null
}

variable "response_headers_policy_name" {
  description = "Name of the response headers policy to look up when response_headers_policy_id is null, e.g. Managed-SecurityHeadersPolicy. That policy sets X-Frame-Options: DENY, which breaks iframe embedding — set both this and response_headers_policy_id to null to attach no policy."
  type        = string
  default     = "Managed-SecurityHeadersPolicy"
}

variable "ordered_cache_behaviors" {
  description = "Additional path-pattern behaviours, evaluated in list order before the default behaviour. cache_policy_id falls back to the default behaviour's policy when null."
  type = list(object({
    path_pattern               = string
    allowed_methods            = optional(list(string), ["GET", "HEAD", "OPTIONS"])
    cached_methods             = optional(list(string), ["GET", "HEAD"])
    viewer_protocol_policy     = optional(string, "redirect-to-https")
    compress                   = optional(bool, true)
    cache_policy_id            = optional(string)
    origin_request_policy_id   = optional(string)
    response_headers_policy_id = optional(string)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# SPA routing
# ---------------------------------------------------------------------------

variable "spa_routing_mode" {
  description = "How client-side routes are served. `cloudfront_function` rewrites extensionless request paths to the entrypoint at the edge, so real routes return a genuine 200 and missing assets still fail honestly. `error_response` rewrites origin 403/404 responses instead, which is simpler but cannot tell a route from a deleted asset. `both` (default) uses the function and keeps the error responses as a safety net. `none` disables SPA handling entirely."
  type        = string
  default     = "both"

  validation {
    condition     = contains(["none", "error_response", "cloudfront_function", "both"], var.spa_routing_mode)
    error_message = "spa_routing_mode must be none, error_response, cloudfront_function or both."
  }
}

variable "spa_fallback_path" {
  description = "Object served for SPA routes. Defaults to \"/<default_root_object>\"."
  type        = string
  default     = null
}

variable "spa_fallback_response_code" {
  description = "Status returned with the SPA fallback. 200 is standard SPA behaviour; 404 is honest for crawlers and uptime monitors while still rendering the app."
  type        = number
  default     = 200
}

variable "spa_fallback_error_codes" {
  description = "Origin error codes rewritten to the SPA fallback. Under OAC without s3:ListBucket, S3 returns 403 rather than 404 for a missing key, so both are handled by default. Narrow this to [404] if you enable origin_list_bucket_permission."
  type        = list(number)
  default     = [403, 404]
}

variable "spa_fallback_caching_min_ttl" {
  description = "Seconds CloudFront caches a SPA fallback response."
  type        = number
  default     = 10
}

variable "custom_error_responses" {
  description = "Additional custom error responses. Entries whose error_code is already covered by spa_fallback_error_codes are ignored."
  type = list(object({
    error_code            = number
    response_code         = optional(number)
    response_page_path    = optional(string)
    error_caching_min_ttl = optional(number)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Origin access control
# ---------------------------------------------------------------------------

variable "origin_access_control_name" {
  description = "Name of the created OAC. Must be unique per AWS account. Defaults to \"<bucket name>-oac\", which is unique because bucket names are globally unique."
  type        = string
  default     = null
}

variable "origin_access_control_id" {
  description = "Use an existing OAC instead of creating one."
  type        = string
  default     = null
}

variable "origin_path" {
  description = "Directory inside the bucket that CloudFront treats as the origin root, e.g. \"/dist\". Leading slash, no trailing slash."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Certificate
# ---------------------------------------------------------------------------

variable "certificate_arn" {
  description = "ACM certificate ARN for the viewer certificate. Must be in us-east-1 and must already be ISSUED, otherwise CloudFront rejects it with InvalidViewerCertificate. Null uses the default *.cloudfront.net certificate, which requires aliases to be empty. See modules/acm-certificate to create one."
  type        = string
  default     = null

  validation {
    condition     = var.certificate_arn != null || length(var.aliases) == 0
    error_message = "aliases require certificate_arn: the default CloudFront certificate cannot serve alternate domain names."
  }
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags applied to every taggable resource created by this module, merged over the provider's default_tags."
  type        = map(string)
  default     = {}
}
