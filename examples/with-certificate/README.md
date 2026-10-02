# with-certificate

A custom domain served over HTTPS, with the certificate created by the bundled
`acm-certificate` submodule.

Note the two providers. The bucket and distribution use the default provider — here
`eu-west-1`, to make the point that they can live anywhere — while the certificate is
pinned to a `us_east_1` alias, because CloudFront viewer certificates must be in us-east-1.

## Two-phase apply

DNS is assumed to be managed outside Terraform. CloudFront rejects a certificate that is
not yet `ISSUED`, so the first apply creates the certificate alone:

```bash
terraform init

# Phase 1
terraform apply -target=module.certificate
terraform output -raw validation_records_table
#   → create those records in your DNS provider

aws acm describe-certificate --region us-east-1 \
  --certificate-arn "$(terraform output -raw certificate_arn)" \
  --query 'Certificate.Status'        # wait for ISSUED

# Phase 2
terraform apply
```

Then point your site records at `distribution_domain_name`.

If your zone is in Route 53, add `aws_route53_record` resources built from the
certificate's `domain_validation_options`, set `wait_for_validation = true`, and the whole
thing becomes a single `terraform apply`.

> This example uses `source = "../../"` so it can be validated in CI. In your own code use
> `source = "deeowemez/spa-cloudfront/aws"` with a `version` pin.

<!-- BEGIN_TF_DOCS -->
examples/with-certificate/main.tf

A custom domain, with the certificate created by the bundled acm-certificate submodule.
DNS is assumed to live outside Terraform, so this needs the two-phase apply described in
the README.

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
| <a name="module_certificate"></a> [certificate](#module\_certificate) | ../../modules/acm-certificate | n/a |
| <a name="module_site"></a> [site](#module\_site) | ../../ | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | Apex domain to serve the site under. | `string` | `"example.com"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Sync your build output here. |
| <a name="output_certificate_arn"></a> [certificate\_arn](#output\_certificate\_arn) | ARN of the certificate, for polling its status with the AWS CLI. |
| <a name="output_certificate_status"></a> [certificate\_status](#output\_certificate\_status) | PENDING\_VALIDATION until the records above are published and ACM picks them up. |
| <a name="output_distribution_domain_name"></a> [distribution\_domain\_name](#output\_distribution\_domain\_name) | Point the site CNAMEs at this. |
| <a name="output_validation_records_table"></a> [validation\_records\_table](#output\_validation\_records\_table) | Create these records in your DNS provider, then wait for the certificate to reach ISSUED. |
<!-- END_TF_DOCS -->
