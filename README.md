# terraform-aws-spa-cloudfront

Serves a single-page application from a private S3 bucket through CloudFront, with origin
access control and deep-link routing.

[![Terraform Registry](https://img.shields.io/badge/terraform-registry-7B42BC?logo=terraform)](https://registry.terraform.io/modules/deeowemez/spa-cloudfront/aws/latest)
[![CI](https://github.com/deeowemez/terraform-aws-spa-cloudfront/actions/workflows/ci.yml/badge.svg)](https://github.com/deeowemez/terraform-aws-spa-cloudfront/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

## What it creates

- A **private** S3 origin bucket — all four public access blocks on, `BucketOwnerEnforced`,
  encrypted, versioned by default with a noncurrent-version expiry rule.
- A **CloudFront Origin Access Control** named after the bucket, so two instances in one
  account cannot collide.
- A **bucket policy** granting the CloudFront service principal `s3:GetObject` and nothing
  else, conditioned on the distribution ARN, plus an optional TLS-only Deny.
- A **CloudFront distribution** using a managed cache policy and, by default, the managed
  security headers policy.
- **SPA routing**: a CloudFront Function that rewrites extensionless paths, plus custom
  error responses as a safety net.
- A **deploy policy document** (`deploy_policy_json`) scoped to exactly this bucket and
  this distribution, ready to attach to a CI role.

The origin is the S3 **REST** endpoint fronted by OAC — *not* the S3 website endpoint. That
is what keeps the bucket private, and it is the reason SPA routing is handled at the edge.

## Usage

```hcl
module "site" {
  source  = "deeowemez/spa-cloudfront/aws"
  version = "~> 0.1.0"

  name = "my-app"
}
```

That serves the site on the distribution's own `*.cloudfront.net` domain. With a custom
domain, supply an already-issued us-east-1 certificate:

```hcl
module "site" {
  source  = "deeowemez/spa-cloudfront/aws"
  version = "~> 0.1.0"

  name            = "my-app"
  aliases         = ["app.example.com", "www.app.example.com"]
  certificate_arn = module.certificate.certificate_arn
}
```

## Examples

| Example | What it shows |
|---|---|
| [simple](examples/simple) | The smallest thing that works, no custom domain |
| [with-certificate](examples/with-certificate) | Custom domain via the bundled `acm-certificate` submodule, two-phase apply |
| [complete](examples/complete) | Most of the surface: `bucket_prefix`, `origin_list_bucket_permission`, ordered behaviours, geo restriction, CI role |

## Why SPA routing needs edge handling

A SPA's routes — `/admin/reports`, `/products/abc` — exist only in the client-side router.
There is no such object in S3. S3 can serve an `error_document` fallback, but **only from
its website endpoint**, which requires a public bucket and cannot sit behind OAC. This
module uses the REST endpoint, so `aws_s3_bucket_website_configuration` would be dead
config; the fallback has to happen in CloudFront instead.

Worse, under OAC the bucket policy grants `s3:GetObject` and not `s3:ListBucket`, so S3
masks key existence: a missing key returns **403 AccessDenied**, not 404. A real route and
a deleted JavaScript bundle are indistinguishable at the error layer.

`spa_routing_mode` controls how that is handled:

| Mode | Behaviour |
|---|---|
| `cloudfront_function` | A viewer-request function rewrites any path whose last segment has no dot to the entrypoint. Real routes return a genuine **200**; a missing `/assets/main-a1b2c3.js` falls through and fails honestly instead of returning HTML and producing `Unexpected token '<'`. |
| `error_response` | Origin 403/404 responses are rewritten to the entrypoint. Simpler, no function, but cannot tell a route from a missing asset. Note `custom_error_response` is **distribution-level** and cannot be scoped per cache behaviour. |
| `both` *(default)* | The function handles routing; the error responses catch extensionless paths that genuinely do not exist. |
| `none` | No SPA handling. |

Set `spa_fallback_response_code = 404` if you would rather crawlers and uptime monitors see
an honest status — the browser renders the app identically either way.

## Certificates and DNS

CloudFront viewer certificates **must be in us-east-1**, whatever region the bucket is in.
Rather than force a `configuration_aliases` on every consumer, certificate creation lives in
the [`acm-certificate`](modules/acm-certificate) submodule, which you pass a us-east-1
provider to.

**CloudFront rejects a certificate that is not `ISSUED`**, failing with
`InvalidViewerCertificate`. If your DNS is not managed in the same apply, that means a
two-phase first apply — create the certificate, publish the validation records, wait for
ISSUED, then apply everything. The submodule's README has the exact sequence, and its
`validation_records_table` output prints a copy-pasteable table for a zone editor.

## Defaults you may want to change

| Default | Why you might change it |
|---|---|
| `price_class = "PriceClass_100"` | North America and Europe only. Use `PriceClass_200`/`All` for global reach. |
| `response_headers_policy_name = "Managed-SecurityHeadersPolicy"` | Sets **`X-Frame-Options: DENY`**, which breaks embedding the site in an iframe. Set both this and `response_headers_policy_id` to `null` to attach no policy. |
| `cache_policy_name = "Managed-CachingOptimized"` | Its **default TTL is 24 hours**. Upload your entrypoint with `Cache-Control: no-cache` *and* invalidate on deploy, or users can get yesterday's HTML pointing at deleted bundles. |
| `bucket_force_destroy = false` | A `terraform destroy` fails on a non-empty bucket. Enable only for ephemeral environments. |
| `origin_list_bucket_permission = false` | Enabling it gives honest 404s, but **never enable it alongside query-string forwarding** — a signed `?list-type=2` request would return every object key in the bucket. |
| `allowed_methods = ["GET","HEAD","OPTIONS"]` | An S3 REST origin only answers reads. Widen only if you add a non-S3 origin. |

## Deploying content

```bash
BUCKET=$(terraform output -raw bucket_id)
DIST=$(terraform output -raw distribution_id)

# Hashed assets are immutable — cache them for a year.
aws s3 sync ./dist "s3://$BUCKET" --delete \
  --exclude "index.html" \
  --cache-control "public, max-age=31536000, immutable"

# The entrypoint must never be cached, at the edge or in the browser.
aws s3 cp ./dist/index.html "s3://$BUCKET/index.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html; charset=utf-8"

aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

The `deploy_policy_json` output is exactly the IAM policy that sequence needs — bucket
object access, bucket listing, and `cloudfront:CreateInvalidation` scoped to this
distribution. Attach it to your CI role and it can never drift from the real resources:

```hcl
resource "aws_iam_role_policy" "deploy" {
  role   = aws_iam_role.ci.id
  policy = module.site.deploy_policy_json
}
```

<!-- BEGIN_TF_DOCS -->
Serves a single-page application from a private S3 bucket through CloudFront, with
origin access control and deep-link routing.

The origin is the S3 **REST** endpoint fronted by an Origin Access Control, not the S3
website endpoint. That is what keeps the bucket private, but it also means S3's
`error_document` never runs — so SPA deep links are handled at the edge instead, by a
CloudFront Function that rewrites extensionless paths and a set of custom error
responses as a safety net.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.40, < 7.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.40, < 7.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudfront_distribution.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_function.spa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_function) | resource |
| [aws_cloudfront_origin_access_control.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_cloudfront_cache_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy) | data source |
| [aws_cloudfront_response_headers_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_response_headers_policy) | data source |
| [aws_iam_policy_document.bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | Name used to derive names for the created resources. Lowercase alphanumerics and hyphens. | `string` | n/a | yes |
| <a name="input_aliases"></a> [aliases](#input\_aliases) | Alternate domain names (CNAMEs) served by the distribution. Every alias must be covered by the viewer certificate. Empty serves only the *.cloudfront.net domain. | `list(string)` | `[]` | no |
| <a name="input_allowed_methods"></a> [allowed\_methods](#input\_allowed\_methods) | HTTP methods CloudFront forwards to the origin. An S3 REST origin only answers reads, so the default is read-only. | `list(string)` | <pre>[<br/>  "GET",<br/>  "HEAD",<br/>  "OPTIONS"<br/>]</pre> | no |
| <a name="input_bucket_force_destroy"></a> [bucket\_force\_destroy](#input\_bucket\_force\_destroy) | Delete all objects in the origin bucket when the bucket is destroyed. Enable only for ephemeral environments; without it a destroy fails on a non-empty bucket. | `bool` | `false` | no |
| <a name="input_bucket_kms_key_arn"></a> [bucket\_kms\_key\_arn](#input\_bucket\_kms\_key\_arn) | Customer managed KMS key for the origin bucket. Requires bucket\_sse\_algorithm = "aws:kms". The key's own policy must grant kms:Decrypt to the CloudFront service principal and to your deploy role; a bucket policy cannot do that for you. | `string` | `null` | no |
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Exact name of the origin bucket. Must be globally unique. Mutually exclusive with bucket\_prefix. When both are null the bucket is named "<name>-origin". | `string` | `null` | no |
| <a name="input_bucket_noncurrent_version_expiration_days"></a> [bucket\_noncurrent\_version\_expiration\_days](#input\_bucket\_noncurrent\_version\_expiration\_days) | Expire noncurrent object versions after this many days. Null disables the lifecycle rule. Ignored when bucket\_versioning\_enabled is false. | `number` | `30` | no |
| <a name="input_bucket_prefix"></a> [bucket\_prefix](#input\_bucket\_prefix) | Create the origin bucket with an AWS-generated unique name starting with this prefix (max 37 characters). Mutually exclusive with bucket\_name. Use this when you do not want to own global-namespace collisions; read the resulting name from the bucket\_id output. | `string` | `null` | no |
| <a name="input_bucket_sse_algorithm"></a> [bucket\_sse\_algorithm](#input\_bucket\_sse\_algorithm) | Server-side encryption algorithm for the origin bucket: AES256 or aws:kms. | `string` | `"AES256"` | no |
| <a name="input_bucket_versioning_enabled"></a> [bucket\_versioning\_enabled](#input\_bucket\_versioning\_enabled) | Enable versioning on the origin bucket. Recommended: a mistaken `aws s3 sync --delete` is otherwise unrecoverable. | `bool` | `true` | no |
| <a name="input_cache_policy_id"></a> [cache\_policy\_id](#input\_cache\_policy\_id) | Cache policy id for the default behaviour. Takes precedence over cache\_policy\_name. | `string` | `null` | no |
| <a name="input_cache_policy_name"></a> [cache\_policy\_name](#input\_cache\_policy\_name) | Name of the cache policy to look up when cache\_policy\_id is null, e.g. Managed-CachingOptimized. Note its default TTL is 24 hours: upload your entrypoint with Cache-Control: no-cache and invalidate on deploy. | `string` | `"Managed-CachingOptimized"` | no |
| <a name="input_cached_methods"></a> [cached\_methods](#input\_cached\_methods) | HTTP methods for which CloudFront caches responses. | `list(string)` | <pre>[<br/>  "GET",<br/>  "HEAD"<br/>]</pre> | no |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ACM certificate ARN for the viewer certificate. Must be in us-east-1 and must already be ISSUED, otherwise CloudFront rejects it with InvalidViewerCertificate. Null uses the default *.cloudfront.net certificate, which requires aliases to be empty. See modules/acm-certificate to create one. | `string` | `null` | no |
| <a name="input_comment"></a> [comment](#input\_comment) | Comment shown on the distribution in the console. Defaults to "<name> static site". | `string` | `null` | no |
| <a name="input_compress"></a> [compress](#input\_compress) | Automatically compress objects for viewers that support it. | `bool` | `true` | no |
| <a name="input_custom_error_responses"></a> [custom\_error\_responses](#input\_custom\_error\_responses) | Additional custom error responses. Entries whose error\_code is already covered by spa\_fallback\_error\_codes are ignored. | <pre>list(object({<br/>    error_code            = number<br/>    response_code         = optional(number)<br/>    response_page_path    = optional(string)<br/>    error_caching_min_ttl = optional(number)<br/>  }))</pre> | `[]` | no |
| <a name="input_default_root_object"></a> [default\_root\_object](#input\_default\_root\_object) | Object returned when a viewer requests the distribution root. | `string` | `"index.html"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether the distribution accepts end user requests. | `bool` | `true` | no |
| <a name="input_enforce_tls_bucket_policy"></a> [enforce\_tls\_bucket\_policy](#input\_enforce\_tls\_bucket\_policy) | Add a Deny statement to the bucket policy rejecting requests where aws:SecureTransport is false. | `bool` | `true` | no |
| <a name="input_geo_restriction"></a> [geo\_restriction](#input\_geo\_restriction) | Geographic restriction. restriction\_type is none, whitelist or blacklist; locations is a list of ISO 3166-1 alpha-2 codes. | <pre>object({<br/>    restriction_type = string<br/>    locations        = optional(list(string), [])<br/>  })</pre> | <pre>{<br/>  "restriction_type": "none"<br/>}</pre> | no |
| <a name="input_http_version"></a> [http\_version](#input\_http\_version) | Maximum HTTP version supported: http1.1, http2, http2and3 or http3. | `string` | `"http2and3"` | no |
| <a name="input_is_ipv6_enabled"></a> [is\_ipv6\_enabled](#input\_is\_ipv6\_enabled) | Enable IPv6 for the distribution. | `bool` | `true` | no |
| <a name="input_logging"></a> [logging](#input\_logging) | CloudFront standard (legacy) access logging. `bucket` must be the target bucket's DOMAIN NAME (e.g. logs.s3.amazonaws.com), and that bucket must have ACLs enabled with object ownership BucketOwnerPreferred — which conflicts with the BucketOwnerEnforced default AWS applies to new buckets. Null disables logging. | <pre>object({<br/>    bucket          = string<br/>    prefix          = optional(string, "")<br/>    include_cookies = optional(bool, false)<br/>  })</pre> | `null` | no |
| <a name="input_minimum_protocol_version"></a> [minimum\_protocol\_version](#input\_minimum\_protocol\_version) | Minimum TLS version for viewer connections. Ignored when the default CloudFront certificate is used. | `string` | `"TLSv1.2_2021"` | no |
| <a name="input_ordered_cache_behaviors"></a> [ordered\_cache\_behaviors](#input\_ordered\_cache\_behaviors) | Additional path-pattern behaviours, evaluated in list order before the default behaviour. cache\_policy\_id falls back to the default behaviour's policy when null. | <pre>list(object({<br/>    path_pattern               = string<br/>    allowed_methods            = optional(list(string), ["GET", "HEAD", "OPTIONS"])<br/>    cached_methods             = optional(list(string), ["GET", "HEAD"])<br/>    viewer_protocol_policy     = optional(string, "redirect-to-https")<br/>    compress                   = optional(bool, true)<br/>    cache_policy_id            = optional(string)<br/>    origin_request_policy_id   = optional(string)<br/>    response_headers_policy_id = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_origin_access_control_id"></a> [origin\_access\_control\_id](#input\_origin\_access\_control\_id) | Use an existing OAC instead of creating one. | `string` | `null` | no |
| <a name="input_origin_access_control_name"></a> [origin\_access\_control\_name](#input\_origin\_access\_control\_name) | Name of the created OAC. Must be unique per AWS account. Defaults to "<bucket name>-oac", which is unique because bucket names are globally unique. | `string` | `null` | no |
| <a name="input_origin_list_bucket_permission"></a> [origin\_list\_bucket\_permission](#input\_origin\_list\_bucket\_permission) | Grant s3:ListBucket to the CloudFront service principal. S3 then returns 404 rather than 403 for a missing key, letting you narrow spa\_fallback\_error\_codes to [404] so genuine permission failures surface instead of being masked as a 200. Do NOT enable alongside query-string forwarding: a signed ?list-type=2 request would return every object key in the bucket. | `bool` | `false` | no |
| <a name="input_origin_path"></a> [origin\_path](#input\_origin\_path) | Directory inside the bucket that CloudFront treats as the origin root, e.g. "/dist". Leading slash, no trailing slash. | `string` | `null` | no |
| <a name="input_origin_request_policy_id"></a> [origin\_request\_policy\_id](#input\_origin\_request\_policy\_id) | Origin request policy id for the default behaviour. Null attaches none, which is correct for a plain S3 origin. | `string` | `null` | no |
| <a name="input_price_class"></a> [price\_class](#input\_price\_class) | Edge location footprint: PriceClass\_100 (NA + EU), PriceClass\_200 (adds Asia, ME, Africa) or PriceClass\_All. | `string` | `"PriceClass_100"` | no |
| <a name="input_response_headers_policy_id"></a> [response\_headers\_policy\_id](#input\_response\_headers\_policy\_id) | Response headers policy id for the default behaviour. Takes precedence over response\_headers\_policy\_name. | `string` | `null` | no |
| <a name="input_response_headers_policy_name"></a> [response\_headers\_policy\_name](#input\_response\_headers\_policy\_name) | Name of the response headers policy to look up when response\_headers\_policy\_id is null, e.g. Managed-SecurityHeadersPolicy. That policy sets X-Frame-Options: DENY, which breaks iframe embedding — set both this and response\_headers\_policy\_id to null to attach no policy. | `string` | `"Managed-SecurityHeadersPolicy"` | no |
| <a name="input_spa_fallback_caching_min_ttl"></a> [spa\_fallback\_caching\_min\_ttl](#input\_spa\_fallback\_caching\_min\_ttl) | Seconds CloudFront caches a SPA fallback response. | `number` | `10` | no |
| <a name="input_spa_fallback_error_codes"></a> [spa\_fallback\_error\_codes](#input\_spa\_fallback\_error\_codes) | Origin error codes rewritten to the SPA fallback. Under OAC without s3:ListBucket, S3 returns 403 rather than 404 for a missing key, so both are handled by default. Narrow this to [404] if you enable origin\_list\_bucket\_permission. | `list(number)` | <pre>[<br/>  403,<br/>  404<br/>]</pre> | no |
| <a name="input_spa_fallback_path"></a> [spa\_fallback\_path](#input\_spa\_fallback\_path) | Object served for SPA routes. Defaults to "/<default\_root\_object>". | `string` | `null` | no |
| <a name="input_spa_fallback_response_code"></a> [spa\_fallback\_response\_code](#input\_spa\_fallback\_response\_code) | Status returned with the SPA fallback. 200 is standard SPA behaviour; 404 is honest for crawlers and uptime monitors while still rendering the app. | `number` | `200` | no |
| <a name="input_spa_routing_mode"></a> [spa\_routing\_mode](#input\_spa\_routing\_mode) | How client-side routes are served. `cloudfront_function` rewrites extensionless request paths to the entrypoint at the edge, so real routes return a genuine 200 and missing assets still fail honestly. `error_response` rewrites origin 403/404 responses instead, which is simpler but cannot tell a route from a deleted asset. `both` (default) uses the function and keeps the error responses as a safety net. `none` disables SPA handling entirely. | `string` | `"both"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every taggable resource created by this module, merged over the provider's default\_tags. | `map(string)` | `{}` | no |
| <a name="input_viewer_protocol_policy"></a> [viewer\_protocol\_policy](#input\_viewer\_protocol\_policy) | How CloudFront handles HTTP viewer requests: allow-all, https-only or redirect-to-https. | `string` | `"redirect-to-https"` | no |
| <a name="input_web_acl_id"></a> [web\_acl\_id](#input\_web\_acl\_id) | WAFv2 web ACL ARN (scope CLOUDFRONT, therefore created in us-east-1) or a WAF Classic web ACL id. Null attaches no web ACL. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the origin S3 bucket. |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Name of the origin S3 bucket. Use this as the aws s3 sync target. |
| <a name="output_bucket_regional_domain_name"></a> [bucket\_regional\_domain\_name](#output\_bucket\_regional\_domain\_name) | Regional REST endpoint of the origin bucket, used as the CloudFront origin domain. |
| <a name="output_certificate_arn"></a> [certificate\_arn](#output\_certificate\_arn) | Viewer certificate ARN in use, or null when the default CloudFront certificate is used. |
| <a name="output_deploy_policy_json"></a> [deploy\_policy\_json](#output\_deploy\_policy\_json) | IAM policy document granting exactly what a CI deploy job needs: object sync into the origin bucket plus invalidation of this distribution. Attach it to your CI role. |
| <a name="output_distribution_arn"></a> [distribution\_arn](#output\_distribution\_arn) | ARN of the CloudFront distribution. |
| <a name="output_distribution_domain_name"></a> [distribution\_domain\_name](#output\_distribution\_domain\_name) | The d111111abcdef8.cloudfront.net domain name. Point your DNS records here. |
| <a name="output_distribution_hosted_zone_id"></a> [distribution\_hosted\_zone\_id](#output\_distribution\_hosted\_zone\_id) | Route 53 hosted zone id for CloudFront, for use in an alias record. |
| <a name="output_distribution_id"></a> [distribution\_id](#output\_distribution\_id) | Identifier of the CloudFront distribution. Pass this to `aws cloudfront create-invalidation --distribution-id`. |
| <a name="output_distribution_status"></a> [distribution\_status](#output\_distribution\_status) | Current status of the distribution, e.g. Deployed. |
| <a name="output_origin_access_control_id"></a> [origin\_access\_control\_id](#output\_origin\_access\_control\_id) | Identifier of the origin access control used by the distribution. |
| <a name="output_spa_function_arn"></a> [spa\_function\_arn](#output\_spa\_function\_arn) | ARN of the CloudFront Function handling SPA routing, or null when spa\_routing\_mode does not create one. |
<!-- END_TF_DOCS -->

## License

Apache-2.0. See [LICENSE](LICENSE).
