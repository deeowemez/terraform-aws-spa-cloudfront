# acm-certificate

Creates a DNS-validated ACM certificate for a CloudFront distribution.

CloudFront viewer certificates must live in **us-east-1**, regardless of where the rest of
your infrastructure is. Pass a us-east-1 provider to this module block; a `precondition`
fails the plan with a clear message if you forget.

This module deliberately does **not** create DNS records. It emits the validation records
ACM expects, so it works the same whether your zone is in Route 53 or at another registrar.

## Usage

```hcl
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "certificate" {
  source  = "deeowemez/spa-cloudfront/aws//modules/acm-certificate"
  version = "~> 0.1.0"

  providers = { aws = aws.us_east_1 }

  domain_name               = "example.com"
  subject_alternative_names = ["*.example.com"]
}
```

## Validating when you do not manage DNS in Terraform

CloudFront **rejects a certificate that is not `ISSUED`**, failing with
`InvalidViewerCertificate`. A greenfield apply therefore cannot succeed in one pass unless
the validation records are created in the same apply. With DNS at another provider, use two
phases:

```bash
# Phase 1 — create the certificate only
terraform apply -target=module.certificate
terraform output -raw validation_records_table

# Create those records in your DNS provider's zone editor, then poll until ISSUED:
aws acm describe-certificate --region us-east-1 \
  --certificate-arn "$(terraform output -raw certificate_arn)" \
  --query 'Certificate.Status'

# Phase 2 — apply everything
terraform apply
```

`validation_records_table` prints a tab-separated `NAME / TYPE / VALUE` table. Two things
to watch when transcribing it:

- Most zone editors take the **host portion only**, not the FQDN. ACM reports
  `_abc123.example.com`; enter `_abc123`. Pasting the full name yields
  `_abc123.example.com.example.com`.
- ACM derives a wildcard's validation record from its base domain, so `*.example.com` and
  `example.com` share a single record — you usually create fewer records than you have
  names on the certificate. `validation_records_table` already de-duplicates them.

Leave the validation records in place permanently. ACM renews DNS-validated certificates
without human action for as long as they exist.

If your zone **is** in Route 53, create `aws_route53_record` resources from
`domain_validation_options` and set `wait_for_validation = true`; the whole thing then
collapses into a single apply.

<!-- BEGIN_TF_DOCS -->
# acm-certificate

Creates a DNS-validated ACM certificate for a CloudFront distribution.

CloudFront viewer certificates must live in us-east-1, so pass a us-east-1 provider to
this module block. The module does not create DNS records: it emits the validation
records to create, so it works whether your zone is in Route 53 or at another provider.

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
| [aws_acm_certificate.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | Primary domain name for the certificate. | `string` | n/a | yes |
| <a name="input_subject_alternative_names"></a> [subject\_alternative\_names](#input\_subject\_alternative\_names) | Additional domain names covered by the certificate. A wildcard covers exactly one label, so *.example.com does not cover a.b.example.com. ACM derives a wildcard's validation record from its base domain, so *.example.com and example.com share one record. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the certificate, merged over the provider's default\_tags. | `map(string)` | `{}` | no |
| <a name="input_validation_method"></a> [validation\_method](#input\_validation\_method) | DNS or EMAIL. DNS is strongly recommended: it renews without human action for as long as the validation records stay in place. | `string` | `"DNS"` | no |
| <a name="input_validation_record_fqdns"></a> [validation\_record\_fqdns](#input\_validation\_record\_fqdns) | FQDNs of validation records that already exist in DNS. Used only when wait\_for\_validation is true and you manage DNS outside Terraform. Null derives them from the certificate's own domain\_validation\_options. | `list(string)` | `null` | no |
| <a name="input_validation_timeout"></a> [validation\_timeout](#input\_validation\_timeout) | How long to wait for ISSUED when wait\_for\_validation is true. | `string` | `"45m"` | no |
| <a name="input_wait_for_validation"></a> [wait\_for\_validation](#input\_wait\_for\_validation) | Block the apply until the certificate reaches ISSUED. Set true only when the validation records already exist or are created in the same apply — otherwise the apply hangs for validation\_timeout and then fails. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_certificate_arn"></a> [certificate\_arn](#output\_certificate\_arn) | ARN of the certificate. When wait\_for\_validation is true this is only known once the certificate is ISSUED, which usefully orders any dependent CloudFront distribution after validation. |
| <a name="output_certificate_status"></a> [certificate\_status](#output\_certificate\_status) | Certificate status: PENDING\_VALIDATION, ISSUED, FAILED and so on. |
| <a name="output_domain_validation_options"></a> [domain\_validation\_options](#output\_domain\_validation\_options) | Validation records ACM expects. Create these in whatever manages your DNS. Each entry has domain\_name, resource\_record\_name, resource\_record\_type and resource\_record\_value. |
| <a name="output_validation_records_table"></a> [validation\_records\_table](#output\_validation\_records\_table) | domain\_validation\_options rendered as a tab-separated table for manual entry in a DNS provider's zone editor. Read it with `terraform output -raw`. |
<!-- END_TF_DOCS -->

## License

Apache-2.0
