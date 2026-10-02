# complete

Exercises most of the module's surface in one place:

- **`bucket_prefix`** instead of a fixed name, so AWS owns the global-namespace collision.
  Read the result from the `bucket_id` output rather than guessing it.
- **`origin_list_bucket_permission = true`**, which makes S3 return 404 rather than 403 for
  a missing key. That in turn lets `spa_fallback_error_codes` narrow to `[404]`, so a
  genuine 403 — a broken OAC signature, a KMS denial — surfaces as an error instead of
  being masked into a 200 HTML page. Safe here only because nothing forwards query strings
  to the origin; see the warning in the root README.
- **An ordered cache behaviour for `/assets/*`**, since content-hashed filenames are
  immutable and want no SPA handling of their own.
- **A geo restriction** and `PriceClass_200`.
- **`deploy_policy_json` attached to a CI role**, so the sync-and-invalidate permissions
  are generated from the resources the module actually created and cannot drift.

`bucket_force_destroy = true` is set because this is a throwaway sandbox. Do not copy that
line into anything you care about — it deletes every object when the bucket is destroyed.

```bash
terraform init
terraform apply

aws s3 sync ./dist "s3://$(terraform output -raw bucket_id)" --delete
aws cloudfront create-invalidation \
  --distribution-id "$(terraform output -raw distribution_id)" --paths "/*"
```

> This example uses `source = "../../"` so it can be validated in CI. In your own code use
> `source = "deeowemez/spa-cloudfront/aws"` with a `version` pin.

<!-- BEGIN_TF_DOCS -->
examples/complete/main.tf

Exercises most of the module's surface: an explicit bucket name, a WAF-less but
geo-restricted distribution, a tightened cache behaviour for hashed assets, honest 404s
from the origin, and a CI role wired to the module's own deploy policy.

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

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_site"></a> [site](#module\_site) | ../../ | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_role.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.ci](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_policy_document.ci_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

No inputs.

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Generated bucket name — read it from here rather than guessing, since bucket\_prefix lets AWS pick the suffix. |
| <a name="output_ci_role_arn"></a> [ci\_role\_arn](#output\_ci\_role\_arn) | Role a CI job assumes to sync content and invalidate the cache. |
| <a name="output_distribution_domain_name"></a> [distribution\_domain\_name](#output\_distribution\_domain\_name) | The distribution's own domain name. |
| <a name="output_distribution_id"></a> [distribution\_id](#output\_distribution\_id) | Use this to invalidate the cache after a deploy. |
| <a name="output_spa_function_arn"></a> [spa\_function\_arn](#output\_spa\_function\_arn) | ARN of the CloudFront Function rewriting extensionless paths. |
<!-- END_TF_DOCS -->
