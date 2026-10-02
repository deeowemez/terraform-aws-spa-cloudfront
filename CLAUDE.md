# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A published Terraform module (`deeowemez/spa-cloudfront/aws`) — not an application. There is
no state, no backend, and no deployable environment in this repo. Every directory is either
the module, a submodule, or an example that exists to be `validate`d by CI.

## Commands

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs five independent jobs. Run the
equivalents locally before considering a change done:

```bash
# fmt — must pass repo-wide
terraform fmt -check -recursive -diff
terraform fmt -recursive                 # to fix

# validate — runs per-directory, with no AWS credentials
for d in . modules/acm-certificate examples/simple examples/complete examples/with-certificate; do
  (cd "$d" && terraform init -backend=false -input=false && terraform validate)
done

# lint
tflint --init && tflint --recursive --format compact

# security scan (HIGH,CRITICAL only; suppressions live in .trivyignore)
trivy config --exit-code 1 --severity HIGH,CRITICAL .

# docs — CI runs terraform-docs v0.24.0 with these exact commands, then `git diff
# --exit-code`, so stale README blocks break the build. Keep the local version matched.
terraform-docs markdown table --output-file README.md --output-mode inject .
terraform-docs markdown table --output-file README.md --output-mode inject modules/acm-certificate
# ...and the same for each examples/* directory
```

To validate a single directory (the closest thing to "run one test"):
`cd examples/complete && terraform init -backend=false -input=false && terraform validate`.

`terraform init -backend=false` is deliberate: validation catches every type and reference
error without touching an AWS account. There is no plan/apply test suite.

## Architecture

**Root module** — [main.tf](main.tf), [variables.tf](variables.tf), [outputs.tf](outputs.tf).
Creates a private S3 bucket, a CloudFront Origin Access Control, a bucket policy, a
distribution, and (conditionally) a CloudFront Function.

**[modules/acm-certificate](modules/acm-certificate)** — a separate submodule purely because
CloudFront viewer certificates must be in us-east-1. Keeping it separate avoids forcing a
`configuration_aliases` on every consumer of the root module; callers pass it a us-east-1
provider. A `precondition` on `data.aws_region.current` enforces the region.

**[examples/](examples)** — `simple`, `with-certificate`, `complete`. These are CI fixtures as
much as documentation; any new variable that needs demonstrating belongs in `complete`.

### The invariants the whole design rests on

- **The origin is the S3 REST endpoint behind OAC, never the S3 website endpoint.** That is
  what keeps the bucket private. Consequence: `aws_s3_bucket_website_configuration` would be
  dead config, and S3's `error_document` never runs, so SPA deep-link routing *must* happen at
  the edge.
- **Under OAC the bucket policy grants `s3:GetObject` but not `s3:ListBucket`, so S3 masks key
  existence — a missing key returns 403, not 404.** This is why `spa_fallback_error_codes`
  defaults to `[403, 404]`, and why `origin_list_bucket_permission` exists. That flag must
  never be combined with query-string forwarding: a signed `?list-type=2` would list the bucket.
- **`custom_error_response` is distribution-level and cannot be scoped per cache behaviour.**
  This is the entire reason the CloudFront Function exists alongside it. The function
  distinguishes a real route (extensionless → rewrite to the entrypoint, genuine 200) from a
  deleted asset (has a dot → falls through and fails honestly instead of returning HTML).
  `spa_routing_mode` selects `none` / `error_response` / `cloudfront_function` / `both`.
- **The OAC name is derived from the bucket id**, which is globally unique, so two instances of
  the module in one account cannot collide on the account-scoped OAC namespace.
- **`deploy_policy_json` is an output, not a resource.** The module emits an IAM policy scoped
  to the bucket and distribution it created; callers attach it. It cannot drift from the real
  resources — keep it that way rather than documenting a hand-written policy.

### Patterns in the HCL

- Conditional resources use `count = <bool> ? 1 : 0`, and the corresponding local resolves
  "caller-supplied id, else looked-up/created id" (`local.origin_access_control_id`,
  `local.cache_policy_id`, `local.response_headers_policy_id`). Follow that shape for new
  optional resources.
- Mutually exclusive AWS arguments are handled with paired `dynamic` blocks over
  `for_each = cond ? [1] : []` and its inverse — see `viewer_certificate` in
  [main.tf](main.tf#L356-L372). Mutual exclusivity is additionally enforced by a `validation`
  block on the variable (`bucket_prefix`, `certificate_arn`, `bucket_kms_key_arn`).
- Error responses are built as maps keyed by `tostring(error_code)` and `merge`d so SPA entries
  deterministically win over caller-supplied ones. Both maps must carry identical attribute
  sets or `merge` fails on type mismatch.
- Every `.tf` file opens with a `/** */` comment. `main.tf`'s header is the module description
  terraform-docs injects into the README (`header-from: main.tf` in
  [.terraform-docs.yml](.terraform-docs.yml)) — editing it edits the published docs.
- Variables are grouped under `# ---` banner comments (Naming / Origin bucket / Distribution /
  Default cache behaviour / SPA routing / Origin access control / Certificate / Tags). Add new
  ones to the matching group.
- Variable `description` strings carry the operational caveat, not just the type — e.g. that
  `Managed-SecurityHeadersPolicy` sets `X-Frame-Options: DENY`, or that
  `Managed-CachingOptimized` has a 24-hour default TTL. These descriptions *are* the published
  reference docs; write them accordingly.

## Conventions

- **Versioning**: `0.x`, so minor releases may break the variable interface. Every
  user-visible change gets an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md)
  (Keep a Changelog format).
- **Provider constraints** are `>= 1.9.0` Terraform and `>= 5.40, < 7.0` AWS, declared
  identically in the root and submodule `versions.tf`. Keep them in sync.
- **[.trivyignore](.trivyignore)**: only suppress a finding that is genuinely a *caller*
  decision exposed as a variable (logging, WAF), and write the reasoning inline as the existing
  entries do. Anything that is the module's own responsibility gets fixed, not ignored.
- `.terraform.lock.hcl` is gitignored — the lock files present locally are not tracked.
- The `<!-- BEGIN_TF_DOCS -->` blocks in every README are generated. Never hand-edit between
  the markers; edit the variable/output descriptions and regenerate.
