# simple

The smallest thing that works: a private bucket, a distribution, SPA routing on, served on
the distribution's own `*.cloudfront.net` domain. No custom domain and no certificate, so
there is nothing to validate and the apply completes in one pass.

```bash
terraform init
terraform apply

aws s3 sync ./dist "s3://$(terraform output -raw bucket_id)" --delete
curl -sI "https://$(terraform output -raw distribution_domain_name)/some/deep/link"   # 200
```

> This example uses `source = "../../"` so it can be validated in CI before any version is
> published. In your own code use the registry address and a version pin:
>
> ```hcl
> source  = "deeowemez/spa-cloudfront/aws"
> version = "~> 0.1.0"
> ```

<!-- BEGIN_TF_DOCS -->
examples/simple/main.tf

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.40, < 7.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_site"></a> [site](#module\_site) | ../../ | n/a |

## Resources

No resources.

## Inputs

No inputs.

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Sync your build output here. |
| <a name="output_distribution_domain_name"></a> [distribution\_domain\_name](#output\_distribution\_domain\_name) | Open this once the distribution reaches Deployed. |
| <a name="output_distribution_id"></a> [distribution\_id](#output\_distribution\_id) | Use this to invalidate the cache after a deploy. |
<!-- END_TF_DOCS -->
