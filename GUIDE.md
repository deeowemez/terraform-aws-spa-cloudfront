# Repository guide

Four things, in order:

1. **[What every file is for](#part-1--what-every-file-is-for)** — a tour of the repo.
2. **[Using this as a versioned module](#part-2--using-this-as-a-versioned-module)** — how you
   actually provision infrastructure with it, and what has to exist first.
3. **[Every resource created](#part-3--every-resource-created)** — what lands in your AWS
   account when you apply, resource by resource.
4. **[Certificates and DNS records](#part-4--certificates-and-dns-records-from-first-principles)**
   — the concepts behind the custom-domain setup, explained from scratch.

If you have never consumed a Terraform module from the registry before, skip to Part 2 and
come back.

---

## Orientation: what kind of repo this is

This repo **is a Terraform module**. It is a reusable package of infrastructure code that
other people reference from their own configuration. It is *not* an application and *not* a
deployable environment.

That has one consequence worth internalising early: **you do not run `terraform apply` in this
repo to provision your site.** There is no state file here, no backend, no environment. You
write your own small Terraform configuration somewhere else, point it at this module, and
apply *that*. Part 2 shows exactly how.

Everything in the repo falls into one of four buckets:

| Kind | Where | Purpose |
|---|---|---|
| **The module itself** | `*.tf` at the repo root | The thing people consume |
| **A submodule** | `modules/acm-certificate/` | An optional extra people consume separately |
| **Examples** | `examples/*/` | Documentation *and* the CI test fixtures |
| **Tooling + docs** | dotfiles, `.github/`, `*.md` | Quality gates and published documentation |

---

## Part 1 — What every file is for

### The module itself (repo root)

Terraform does not care how you split code across `.tf` files — it concatenates every `.tf`
in a directory before evaluating. The split below is pure convention, but it is the
convention the whole ecosystem uses, so keep to it.

#### `main.tf`
The resources. Reading it top to bottom you get: a `locals` block that resolves all the
"caller gave me a value, otherwise derive one" decisions; the S3 origin bucket and its six
associated configuration resources (public access block, ownership controls, versioning,
encryption, lifecycle, policy); the CloudFront Origin Access Control; the CloudFront Function
that handles SPA routing; the distribution; and finally an IAM policy *document* for
deployments.

Two details that surprise people:

- **The opening `/** ... */` comment is not just a comment.** `terraform-docs` is configured
  with `header-from: main.tf`, so that block becomes the module description published on the
  Terraform Registry. Editing it edits the public docs.
- **`data "aws_iam_policy_document" "deploy"` creates nothing.** A `data` source *reads*; this
  one just renders JSON, which is exposed as the `deploy_policy_json` output for callers to
  attach to their own CI role. The module never creates an IAM role.

#### `variables.tf`
Every input the module accepts — 42 of them — grouped under `# ---` banner comments by topic
(Naming, Origin bucket, Distribution, Default cache behaviour, SPA routing, Origin access
control, Certificate, Tags).

Each variable has a `description`, a `type`, usually a `default`, and often a `validation`
block. The `validation` blocks are the module catching your mistake at plan time with a
sentence of English, instead of AWS catching it ten minutes into an apply with an API error.
For example, setting both `bucket_name` and `bucket_prefix` fails immediately with
`Set at most one of bucket_name or bucket_prefix.`

The `description` strings are the reference documentation — they get published verbatim to the
registry — so they carry the operational caveats too, not just the type. Read them before
reaching for AWS docs.

#### `outputs.tf`
What the module hands back: bucket identifiers, distribution identifiers, and
`deploy_policy_json`. You read these with `terraform output`, or reference them from other
resources as `module.site.bucket_id`.

`distribution_domain_name` is the one you point DNS at. `bucket_id` is the `aws s3 sync`
target. `deploy_policy_json` is the ready-made IAM policy for a CI role.

#### `versions.tf`
The floor and ceiling for tooling:

```hcl
required_version = ">= 1.9.0"          # Terraform CLI
version = ">= 5.40, < 7.0"             # hashicorp/aws provider
```

This is a promise to consumers: the module works on any Terraform from 1.9 up, and any AWS
provider in the 5.40–6.x range. The upper bound matters — provider major versions introduce
breaking changes, so a module that does not cap its provider will eventually break without
anyone changing a line of code.

### The submodule

#### `modules/acm-certificate/` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md`)
A second, independent module living inside the same repo. Same file conventions as the root.

It exists for one reason: **CloudFront viewer certificates must be issued in us-east-1**, no
matter where the rest of your infrastructure lives. Terraform handles multi-region by passing
a second, aliased provider into a module — but if the root module needed that, *every single
consumer* would be forced to declare a us-east-1 provider even when using the free
`*.cloudfront.net` domain and no certificate at all. Splitting the certificate into its own
module means only the people who need a custom domain pay that cost.

It deliberately **does not create DNS records**, so it works whether your zone is in Route 53,
Cloudflare, or a registrar's web console. It emits the records you need to create; its
`validation_records_table` output prints them as a copy-pasteable table.

### The examples

These serve double duty: they are documentation, and they are what CI actually validates. Every
one of them uses `source = "../../"` (a local relative path) so it can be checked before any
version is published — **in your own code you would use the registry address and a version
pin instead**, which each example's README reminds you of.

| Directory | What it demonstrates |
|---|---|
| `examples/simple/` | The minimum viable config: `name = "example-simple"` and nothing else. One provider, one module block, applies in a single pass. Start here. |
| `examples/with-certificate/` | A custom domain. Shows the two-provider pattern (default region for the bucket, `us_east_1` alias for the certificate) and the two-phase apply needed when DNS lives outside Terraform. |
| `examples/complete/` | Most of the surface area at once: `bucket_prefix`, `origin_list_bucket_permission`, an ordered cache behaviour for `/assets/*`, geo restriction, `default_tags`, and a CI role wired to `deploy_policy_json`. |

Each contains the same file set as any Terraform root configuration: `main.tf` (providers +
module block), `outputs.tf` (re-exporting the interesting values), `versions.tf`, and a
`README.md`.

### Tooling configuration

#### `.github/workflows/ci.yml`
Five parallel jobs on every pull request and every push to `main`:

1. **`fmt`** — `terraform fmt -check -recursive -diff`. Canonical formatting, repo-wide.
2. **`validate`** — a matrix over all five Terraform directories, each running
   `terraform init -backend=false` then `terraform validate`. The `-backend=false` is the
   important bit: it means **CI needs no AWS credentials**. `validate` catches every syntax,
   type and reference error without touching an account. There are no apply-based tests.
3. **`tflint`** — lint rules beyond what `validate` knows about.
4. **`security`** — Trivy config scan, failing on HIGH/CRITICAL.
5. **`docs`** — regenerates every README's docs block and fails if the result differs from
   what is committed. Forget to regenerate, and CI tells you.

#### `.terraform-docs.yml`
Configures the auto-generated documentation: markdown tables, sorted by required-first,
injected between the `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` markers in each README,
with the module header pulled from `main.tf`'s comment block.

**Never hand-edit between those markers.** Edit the `description` on the variable or output and
regenerate.

#### `.tflint.hcl`
Enables tflint's Terraform ruleset at the `recommended` preset plus the AWS ruleset (pinned to
`0.32.0`), which knows about real AWS constraints — invalid instance types, malformed ARNs,
and so on.

#### `.trivyignore`
Suppressions for the security scanner, with a house rule stated at the top of the file: only
suppress a finding that represents a **caller's** decision exposed as a variable, never one
that is the module's own responsibility. The three current entries (CloudFront access logging,
WAF, S3 bucket logging) each carry a paragraph explaining why the module cannot or should not
turn them on by default. Follow that pattern if you ever add a fourth.

#### `.gitignore`
Standard Terraform ignores: `.terraform/`, state files, plan files, `*.tfvars`, crash logs.

Note that **`.terraform.lock.hcl` is ignored here**. That is correct *for a module repo* and
wrong for a root configuration — see [the lock file](#the-lock-file-terraformlockhcl) in Part 2.

### Documentation

- **`README.md`** — the public front door, and what the Terraform Registry renders on the
  module's page. Covers what gets created, usage, the SPA-routing rationale, defaults worth
  changing, and the deploy workflow.
- **`CHANGELOG.md`** — Keep a Changelog format, semver. Note the standing warning: at `0.x`,
  **minor releases may break the variable interface**, so pin with `~> 0.1.0` (patch-only)
  until 1.0.0.
- **`CLAUDE.md`** — instructions for Claude Code working in this repo.
- **`GUIDE.md`** — this file.

### Local-only, not committed

- **`.terraform/`** — where `terraform init` caches downloaded providers. Disposable; delete it
  and re-init any time.
- **`.terraform.lock.hcl`** — present locally in several directories but gitignored.

### One gap worth knowing about

`README.md` links to a `LICENSE` file and both READMEs state Apache-2.0, but **no `LICENSE`
file exists in the repo**. The Terraform Registry expects one, so it should be added before
publishing.

---

## Part 2 — Using this as a versioned module

### What "versioned module" actually means

A published module has a three-part registry address:

```
deeowemez / spa-cloudfront / aws
└ namespace  └ module name   └ provider
```

The Terraform Registry maps that to the GitHub repository `terraform-aws-spa-cloudfront` —
the repo naming pattern `terraform-<PROVIDER>-<NAME>` is a hard requirement, not a style
choice. Versions come from **git tags** of the form `v0.1.0`. There is no build or publish
step: you tag a commit, and that tag becomes an immutable version.

"Versioned" is the whole point. Without a version pin, your infrastructure changes whenever
someone else pushes to a repo you do not control.

### Writing your first consuming configuration

Create a new, empty directory — **not inside this repo** — and add a single file:

```hcl
# main.tf

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "site" {
  source  = "deeowemez/spa-cloudfront/aws"
  version = "~> 0.1.0"

  name = "my-app"
}

output "bucket_id" {
  value = module.site.bucket_id
}

output "distribution_domain_name" {
  value = module.site.distribution_domain_name
}
```

That is a complete, applyable Terraform **root configuration**. The distinction matters:

- A **root configuration** is a directory you run `terraform` in. It declares providers, holds
  state, and is where credentials apply.
- A **module** declares no providers and holds no state. It inherits both from whoever calls it.

This repo's root is a module. The directory you just created is a root configuration. The
`examples/` directories are also root configurations — which is why each one declares a
`provider "aws"` block while the module itself never does.

#### Reading the version pin

`~> 0.1.0` is the pessimistic constraint operator. It allows the **rightmost** component to
increase:

| Constraint | Allows | Blocks |
|---|---|---|
| `~> 0.1.0` | 0.1.1, 0.1.9 | 0.2.0 |
| `~> 0.1` | 0.2.0, 0.9.0 | 1.0.0 |
| `= 0.1.0` | nothing else | everything else |

Because this module is at `0.x`, [CHANGELOG.md](CHANGELOG.md) explicitly tells you to use
`~> 0.1.0` — patch releases only. Under semver, `0.x` minor bumps are allowed to break things,
and this module's changelog says it will use that latitude.

#### Calling the submodule

A submodule is addressed with a **double slash** marking the repo root:

```hcl
module "certificate" {
  source  = "deeowemez/spa-cloudfront/aws//modules/acm-certificate"
  version = "~> 0.1.0"

  providers = { aws = aws.us_east_1 }

  domain_name = "example.com"
}
```

The `providers = { ... }` argument is how you hand a module a *different* provider than the
one it would inherit. Here the root config's default provider might be `eu-west-1`, but the
certificate module receives the `us_east_1` aliased provider instead. See
[examples/with-certificate/main.tf](examples/with-certificate/main.tf) for the full shape.

#### The lock file (`.terraform.lock.hcl`)

`terraform init` records the exact provider versions and their checksums here. **In your root
configuration, commit this file** — it is what makes builds reproducible. It is gitignored in
*this* repo only because a module does not control which provider version its consumers
resolve.

### Prerequisites

#### Tooling and credentials

- **Terraform CLI 1.9.0 or newer.**
- **AWS credentials** in your environment (`aws configure`, `AWS_PROFILE`, or an assumed role).
  The identity needs to create S3 buckets, CloudFront distributions, CloudFront functions and
  origin access controls, and to *read* CloudFront managed cache/response-header policies. If
  you use the `acm-certificate` submodule, add ACM. If you build a CI role from
  `deploy_policy_json`, add IAM.
- **AWS CLI**, for uploading site content after the apply.

#### AWS resources you must create first

**For the basic case: none.** This is the answer most beginners are looking for. The module
creates its own S3 bucket. You do not pre-create a bucket, a distribution, an OAC, or a bucket
policy — passing it an existing bucket is not supported. Point Terraform at an AWS account and
apply.

The exceptions, each tied to an optional feature:

| If you set… | This must exist beforehand |
|---|---|
| `aliases` + `certificate_arn` | A **registered domain** and a DNS zone you can edit, plus an ACM certificate **in us-east-1** that has already reached **`ISSUED`**. The `acm-certificate` submodule creates the certificate, but the domain and zone are yours. |
| `bucket_sse_algorithm = "aws:kms"` with `bucket_kms_key_arn` | The **KMS key**, and critically its **key policy** must grant `kms:Decrypt` to the CloudFront service principal and to your deploy role. Terraform's IAM side is handled by the module's output; the key policy is not, and cannot be. |
| `web_acl_id` | A **WAFv2 web ACL with scope `CLOUDFRONT`** — which, like the certificate, must be created in us-east-1. |
| `logging` | A **target log bucket** with ACLs enabled and object ownership `BucketOwnerPreferred`. Note the `bucket` argument wants the bucket's *domain name* (`logs.s3.amazonaws.com`), not its name. |
| `origin_access_control_id` | An existing OAC, if you are reusing one rather than letting the module create it. |

#### The one genuine prerequisite for real work: remote state

Not an AWS prerequisite of the *module*, but of any Terraform you intend to keep. By default
state is a local `terraform.tfstate` file — fine for a scratch experiment, unworkable for a
team, and a single laptop failure away from being unrecoverable.

Remote state is bootstrapped **outside** the configuration that uses it (it cannot create the
bucket it stores its own state in):

```hcl
terraform {
  backend "s3" {
    bucket       = "my-terraform-state"
    key          = "spa/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true      # S3-native state locking; requires Terraform 1.10+
  }
}
```

Create that state bucket by hand (or in a separate bootstrap configuration) before your first
`init`. On Terraform 1.9, `use_lockfile` is unavailable — you need a DynamoDB table and the
`dynamodb_table` argument instead, which is another resource to bootstrap.

### The provisioning sequence

```bash
terraform init      # downloads the AWS provider and this module; writes the lock file
terraform plan      # shows what will be created — read this
terraform apply     # creates it
```

What happens during that apply, and why the order matters:

1. The **S3 bucket** is created, then its public-access block, ownership controls, versioning,
   encryption and lifecycle rule.
2. The **CloudFront Function** is created and published (if `spa_routing_mode` uses one).
3. The **Origin Access Control** is created, named after the bucket.
4. The **distribution** is created. This is the slow step — **expect 3–10 minutes** while it
   propagates to edge locations. It is not stuck.
5. The **bucket policy** is applied *last*, because it references the distribution's ARN in its
   condition.

Step 5 is worth noticing. The dependency graph runs bucket → distribution → policy, so for a
brief window the distribution exists but is not yet allowed to read the bucket. If you curl the
site the instant apply finishes and get a 403, wait for the policy and give the distribution a
moment to reach `Deployed`.

**The bucket is empty at this point.** A CloudFront distribution with nothing behind it returns
errors — and with SPA routing on, an error that looks confusing, because the fallback tries to
serve an `index.html` that does not exist yet. Upload content:

```bash
BUCKET=$(terraform output -raw bucket_id)
DIST=$(terraform output -raw distribution_id)

# Content-hashed assets are immutable — cache them for a year.
aws s3 sync ./dist "s3://$BUCKET" --delete \
  --exclude "index.html" \
  --cache-control "public, max-age=31536000, immutable"

# The entrypoint must never be cached, at the edge or in the browser.
aws s3 cp ./dist/index.html "s3://$BUCKET/index.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html; charset=utf-8"

aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*"
```

Then open `https://$(terraform output -raw distribution_domain_name)`.

### Adding a custom domain

This is the part that cannot be done in a single apply unless Terraform also manages your DNS,
and the reason is worth understanding: **CloudFront rejects a certificate that is not yet
`ISSUED`**, failing with `InvalidViewerCertificate`. ACM will not issue until it sees
validation records in your DNS. If Terraform does not control your DNS, nothing in the apply
can publish those records, so the apply cannot get past the certificate.

Hence the two-phase sequence:

```bash
# Phase 1 — create the certificate and nothing else
terraform apply -target=module.certificate
terraform output -raw validation_records_table

# Create those records in your DNS provider, then poll:
aws acm describe-certificate --region us-east-1 \
  --certificate-arn "$(terraform output -raw certificate_arn)" \
  --query 'Certificate.Status'        # wait for ISSUED

# Phase 2 — apply everything
terraform apply
```

Two transcription traps when entering the records by hand, both covered in
[modules/acm-certificate/README.md](modules/acm-certificate/README.md):

- Most zone editors want the **host portion only**. ACM reports `_abc123.example.com`; you
  enter `_abc123`. Pasting the full name produces `_abc123.example.com.example.com`.
- A wildcard and its base domain share one validation record, so you create fewer records than
  you have names. The `validation_records_table` output already de-duplicates.

Leave the validation records in DNS permanently — ACM renews DNS-validated certificates with
no human action for as long as they exist.

Finally, point your site's records at the distribution (`distribution_domain_name`). This is
*your* DNS, not something the module creates.

**If your zone is in Route 53**, none of this applies: create `aws_route53_record` resources
from the certificate's `domain_validation_options`, set `wait_for_validation = true`, and the
whole thing collapses into a single `terraform apply`.

### Upgrading the module later

Bump the constraint, then:

```bash
terraform init -upgrade
terraform plan            # read this carefully before applying
```

Check [CHANGELOG.md](CHANGELOG.md) first. At `0.x`, a minor bump can rename or remove
variables.

### Tearing down

```bash
terraform destroy
```

This **fails if the bucket is not empty**, which is deliberate — `bucket_force_destroy`
defaults to `false` precisely so a `destroy` cannot silently delete a site's content. Either
empty the bucket first (`aws s3 rm "s3://$BUCKET" --recursive`, and delete old versions too if
versioning is on), or set `bucket_force_destroy = true` and re-apply before destroying. Only do
the latter in environments you are happy to lose.

### Common first-run problems

| Symptom | Cause |
|---|---|
| `InvalidViewerCertificate` | The certificate is not `ISSUED`, or is not in us-east-1. |
| `BucketAlreadyExists` | S3 bucket names are **globally** unique across all AWS accounts. Use `bucket_prefix` instead of `bucket_name` and let AWS pick a suffix. |
| `aliases require certificate_arn` | A plan-time validation from the module: the default `*.cloudfront.net` certificate cannot serve custom domain names. |
| 403 on every request, right after apply | The bucket policy applies after the distribution; also check the distribution has reached `Deployed`. |
| 403 or an error page on a URL that should work | The bucket is empty, or `index.html` was never uploaded. |
| `Unexpected token '<'` in the browser console | A missing JavaScript bundle is being served the HTML fallback. `spa_routing_mode = "cloudfront_function"` or `"both"` prevents this; `"error_response"` alone cannot. |
| Stale content after a deploy | The default cache policy (`Managed-CachingOptimized`) has a **24-hour** TTL. Upload `index.html` with `Cache-Control: no-cache` *and* invalidate. |
| The site cannot be embedded in an iframe | The default `Managed-SecurityHeadersPolicy` sets `X-Frame-Options: DENY`. Set both `response_headers_policy_name` and `response_headers_policy_id` to `null` to attach no policy. |

---

## Part 3 — Every resource created

Part 2 covered *how* to apply. This part covers *what lands in your AWS account* when you do,
resource by resource: what it is, why the module creates it, and what to watch for.

### The short version

With **default settings and no optional features**, a `terraform apply` creates **ten
resources**. None of them require anything to pre-exist.

| # | Terraform address | AWS resource | Created when |
|---|---|---|---|
| 1 | `aws_s3_bucket.this` | S3 bucket | Always |
| 2 | `aws_s3_bucket_public_access_block.this` | S3 public access block | Always |
| 3 | `aws_s3_bucket_ownership_controls.this` | S3 ownership controls | Always |
| 4 | `aws_s3_bucket_versioning.this[0]` | S3 versioning config | `bucket_versioning_enabled` (default **true**) |
| 5 | `aws_s3_bucket_server_side_encryption_configuration.this` | S3 encryption config | Always |
| 6 | `aws_s3_bucket_lifecycle_configuration.this[0]` | S3 lifecycle rule | Versioning on **and** `bucket_noncurrent_version_expiration_days` set (default **30**) |
| 7 | `aws_s3_bucket_policy.this` | S3 bucket policy | Always |
| 8 | `aws_cloudfront_origin_access_control.this[0]` | CloudFront OAC | `origin_access_control_id` is null (default) |
| 9 | `aws_cloudfront_function.spa[0]` | CloudFront Function | `spa_routing_mode` is `cloudfront_function` or `both` (default **both**) |
| 10 | `aws_cloudfront_distribution.this` | CloudFront distribution | Always |

Resources 4, 6, 8 and 9 are conditional — they use `count`, which is why their addresses carry
an `[0]` index. Turn the feature off and the resource simply is not in the plan.

Using the `acm-certificate` submodule adds one or two more; see
[the certificate submodule](#the-certificate-submodule) below.

### Data sources — read, never created

These appear in the plan output but **create nothing**. A `data` block asks AWS (or Terraform
itself) a question. Beginners often see these in a plan and worry; they are free and harmless.

| Address | What it reads | Present when |
|---|---|---|
| `data.aws_cloudfront_cache_policy.this[0]` | Looks up an AWS-managed cache policy by name, to get its id | `cache_policy_id` is null (default) |
| `data.aws_cloudfront_response_headers_policy.this[0]` | Same, for the response headers policy | `response_headers_policy_id` is null and a name is set (default) |
| `data.aws_iam_policy_document.bucket` | Renders the bucket policy JSON | Always |
| `data.aws_iam_policy_document.deploy` | Renders the CI deploy policy JSON, exposed as an output | Always |

The two policy-document data sources are pure local computation — they do not even call AWS.
They build JSON that something else consumes: the first feeds `aws_s3_bucket_policy.this`, the
second is handed to you as `deploy_policy_json` to attach to your own role.

---

### The origin bucket group

Seven resources, all describing one bucket. AWS splits S3 bucket configuration across many
separate APIs, and the Terraform AWS provider mirrors that — which is why a single conceptual
"private, encrypted, versioned bucket" is seven entries in your plan rather than one.

#### 1. `aws_s3_bucket.this` — the bucket

The origin. Your built site lives here; nothing reaches it except CloudFront.

Its name comes from whichever of three paths you chose:

- `bucket_name` set → that exact name.
- `bucket_prefix` set → AWS appends a unique suffix. **Read the result from the `bucket_id`
  output**; do not guess it.
- Neither → `"<name>-origin"`.

Bucket names are **globally unique across every AWS account on earth**, which is the most common
first-apply failure. `bucket_prefix` sidesteps it entirely by letting AWS own the collision.

`force_destroy` is wired to `bucket_force_destroy`, default `false` — so `terraform destroy`
refuses to delete a bucket with objects in it. That is a guard rail, not a bug.

#### 2. `aws_s3_bucket_public_access_block.this` — the "never public" switch

All four settings hard-coded to `true`: `block_public_acls`, `block_public_policy`,
`ignore_public_acls`, `restrict_public_buckets`. **Not configurable**, deliberately. The entire
security model of this module is that the bucket is private and only CloudFront can read it; a
variable to weaken that would be a variable to break it.

#### 3. `aws_s3_bucket_ownership_controls.this` — disables ACLs

Sets `object_ownership = "BucketOwnerEnforced"`, which turns off S3 ACLs completely. Every
object is owned by the bucket owner and access is governed by policy alone. This is the modern
AWS default and the recommended posture.

It also explains a limitation documented in `.trivyignore`: CloudFront's legacy access logging
*requires* a log bucket with ACLs enabled (`BucketOwnerPreferred`), which directly contradicts
this. That is why `logging` takes a bucket you create rather than one the module creates.

#### 4. `aws_s3_bucket_versioning.this[0]` — keeps old object versions

On by default, and worth leaving on. The reason is in the variable description: a mistaken
`aws s3 sync --delete` against the wrong bucket is otherwise **unrecoverable**. With versioning,
the deleted objects are still there behind a delete marker.

#### 5. `aws_s3_bucket_server_side_encryption_configuration.this` — encryption at rest

Defaults to `AES256` (SSE-S3), which is free and requires no setup.

Switch to `aws:kms` with `bucket_kms_key_arn` and two things change. First, `bucket_key_enabled`
is automatically turned on, which cuts KMS request costs substantially. Second — and this is the
trap — **the KMS key's own policy must grant `kms:Decrypt` to the CloudFront service principal
and to your deploy role.** Terraform's IAM side is handled (`deploy_policy_json` gains a
`UseBucketKmsKey` statement automatically), but a key policy is attached to the key, not to the
bucket, so the module cannot write it for you. Miss this and CloudFront returns 403 on every
object.

#### 6. `aws_s3_bucket_lifecycle_configuration.this[0]` — expires old versions

One rule, `expire-noncurrent-versions`, deleting noncurrent object versions after
`bucket_noncurrent_version_expiration_days` (default 30). Without it, versioning would
accumulate every build you have ever deployed, forever, and you would pay to store all of it.

Set the variable to `null` to keep versions indefinitely. The resource then disappears from the
plan.

#### 7. `aws_s3_bucket_policy.this` — who may read the bucket

The security centrepiece. Up to three statements:

**`AllowCloudFrontServicePrincipalReadOnly`** (always) — grants `s3:GetObject` on
`<bucket-arn>/*` to the `cloudfront.amazonaws.com` service principal, conditioned on
`AWS:SourceArn` equalling **this specific distribution's ARN**. Read that carefully: not "any
CloudFront distribution", not "any distribution in my account" — this one. Someone else's
distribution cannot be pointed at your bucket.

Note what is *not* granted: no `PutObject`, no `DeleteObject`, no `ListBucket`. CloudFront can
read objects and nothing else.

**`AllowCloudFrontServicePrincipalList`** (only when `origin_list_bucket_permission = true`) —
adds `s3:ListBucket`. Two details matter here:

- `s3:ListBucket` is a **bucket-level** action, so its resource is the bucket ARN with **no
  `/*` suffix**. Getting that wrong is a classic IAM mistake; the module comments the
  distinction inline.
- Granting it changes S3's behaviour on a missing key from **403 to 404**. That sounds cosmetic
  and is not: with honest 404s you can narrow `spa_fallback_error_codes` to `[404]`, so a
  genuine 403 (broken OAC signature, KMS denial) surfaces as an error instead of being silently
  rewritten into a 200 HTML page.
- **Never enable this alongside query-string forwarding.** A signed `?list-type=2` request would
  return every object key in the bucket.

**`DenyInsecureTransport`** (on by default via `enforce_tls_bucket_policy`) — an explicit Deny
on `s3:*` for everyone when `aws:SecureTransport` is false. An explicit Deny in IAM beats any
Allow, anywhere, so this is unconditional.

This resource carries `depends_on = [aws_s3_bucket_public_access_block.this]`. That ordering is
required: `block_public_policy` must be in place before a policy is attached, or AWS may reject
the policy as potentially public.

---

### The CloudFront group

#### 8. `aws_cloudfront_origin_access_control.this[0]` — how CloudFront proves who it is

An OAC is the modern replacement for Origin Access Identity. CloudFront uses it to **SigV4-sign
every request it makes to S3**, which is what allows the bucket to stay fully private while
still being readable at the edge. `signing_behavior = "always"`, `signing_protocol = "sigv4"`.

The name defaults to `"<bucket-id>-oac"`. That derivation is intentional and worth understanding:
**OAC names must be unique per AWS account**, while bucket names are unique globally — so
naming the OAC after the bucket guarantees that two instances of this module in the same account
cannot collide. A naive `"<name>-oac"` would break the second time someone deployed a staging and
a production copy.

Free. OACs cost nothing.

#### 9. `aws_cloudfront_function.spa[0]` — SPA deep-link routing at the edge

A small JavaScript function (`cloudfront-js-2.0` runtime) attached to the distribution's default
behaviour as a **viewer-request** trigger, so it runs on every incoming request before the cache
is consulted.

The logic is four lines: split the URI on `/`, take the last segment, and if it contains **no
dot**, rewrite the whole URI to the SPA entrypoint.

```js
if (last.indexOf('.') === -1) {
    request.uri = '/index.html';
}
```

Why this exists at all is the module's central design point. A SPA route like `/admin/reports`
has no corresponding object in S3. The usual S3 answer — an `error_document` fallback — only
works on the **S3 website endpoint**, which requires a public bucket and cannot sit behind OAC.
This module uses the REST endpoint, so that door is closed and the fallback has to happen in
CloudFront.

The dot test is what makes it better than error responses alone. `/admin/reports` has no dot →
rewritten → the app loads with a genuine **200**. `/assets/main-a1b2c3.js` has a dot → left
alone → if that bundle is missing it **fails honestly**, instead of being handed `index.html`
and producing the classic `Unexpected token '<'` in the console.

Billed per invocation. CloudFront Functions are very cheap, but this runs on every request, so
it is not literally free.

`publish = true` means the function is live, not just saved as a draft.

#### 10. `aws_cloudfront_distribution.this` — the CDN itself

The largest resource, and the slow one: **expect 3–10 minutes** for creation, and a similar wait
on many updates, while the configuration propagates to edge locations worldwide.

Most of its configuration is *inline blocks*, which are part of this one resource rather than
separate resources of their own:

| Block | What it does |
|---|---|
| `origin` | Points at the bucket's `bucket_regional_domain_name` — the **REST** endpoint, not the website endpoint — and attaches the OAC. |
| `default_cache_behavior` | Caching and protocol rules for everything not matched by an ordered behaviour, plus the `function_association` that wires in the SPA function. |
| `ordered_cache_behavior` | One per entry in `ordered_cache_behaviors`, evaluated **in list order, before** the default. Typically used to cache `/assets/*` harder. |
| `custom_error_response` | One per entry in the merged error map. |
| `restrictions` → `geo_restriction` | Always present; `none` by default. |
| `logging_config` | Only when `logging` is set. |
| `viewer_certificate` | The default `*.cloudfront.net` certificate, or your ACM certificate. |

Three things in here are worth understanding rather than skimming:

**The error responses are built as a keyed map, then merged.** `spa_error_responses` and
`extra_error_responses` are both keyed by `tostring(error_code)`, and merged with the SPA
entries second — so SPA entries deterministically win if a caller supplies a conflicting one for
the same code. Both maps are constructed with identical attribute sets, because `merge()` fails
on mismatched object types.

**`custom_error_response` is distribution-level and cannot be scoped to a cache behaviour.**
This is the reason the CloudFront Function exists *alongside* it rather than instead of it: an
error response applies everywhere, so it cannot treat `/assets/*` differently from `/admin/*`.
The function can.

**`viewer_certificate` is two mutually exclusive `dynamic` blocks.** `acm_certificate_arn` and
`cloudfront_default_certificate` cannot both be set, and `minimum_protocol_version` is rejected
alongside the default certificate — so the module emits one block or the other via
`for_each = cond ? [1] : []` and its inverse. A `lifecycle` `precondition` additionally fails the
plan with a readable message if you set `aliases` without a certificate.

Cost: this is where the money is. CloudFront bills for data transfer out and per request, and
`price_class` controls which edge locations are used (`PriceClass_100`, the default, is North
America and Europe only).

---

### The certificate submodule

Only if you call `modules/acm-certificate`.

#### `aws_acm_certificate.this` — the certificate

A public, DNS-validated ACM certificate. **Free** — AWS does not charge for public ACM
certificates.

Two guards are built in. A `precondition` on `data.aws_region.current` fails the plan with a
clear message if the module is not given a us-east-1 provider, because CloudFront viewer
certificates must live there. And `create_before_destroy = true` means a replacement certificate
is issued before the old one is removed, so a domain change does not leave the distribution
briefly certificate-less.

#### `aws_acm_certificate_validation.this[0]` — a wait, not a resource

Only created when `wait_for_validation = true`, and it is worth knowing that **this creates
nothing in AWS**. It is a virtual resource whose entire job is to block the apply until the
certificate reaches `ISSUED`, timing out after `validation_timeout` (default 45m).

Its value is the ordering it imposes: when it exists, the submodule's `certificate_arn` output
comes from *it* rather than from the certificate directly, so any CloudFront distribution
consuming that output is automatically sequenced after validation completes. That is what
collapses the two-phase apply into one when Terraform also manages your DNS.

Leave it `false` when DNS is managed by hand, or the apply will hang for 45 minutes waiting for
records that nobody is going to create, then fail — leaving a half-built stack.

#### `data.aws_region.current`

Reads the region of the provider passed in, purely to power the precondition above. Creates
nothing.

---

### Dependency order

Terraform works this out from the references between resources; you never declare it. But
knowing the shape explains a confusing few minutes after your first apply:

```
aws_s3_bucket.this
   ├─→ public access block, ownership controls, versioning,
   │   encryption, lifecycle          (all in parallel)
   ├─→ aws_cloudfront_origin_access_control  (named after the bucket)
   └─→ aws_cloudfront_distribution           (origin domain + OAC)
            └─→ aws_s3_bucket_policy         (condition references the distribution ARN)
```

The bucket policy is **last**, because it needs the distribution's ARN to exist before it can
name it in a condition. So there is a real window in which the distribution exists but is not
yet permitted to read the bucket. A 403 immediately after apply is usually this, not a
misconfiguration — wait for the policy to land and the distribution to reach `Deployed`.

There is no dependency cycle here, despite appearances, because the distribution depends on the
*bucket*, not on the bucket *policy*.

---

### What the module deliberately does not create

Just as important as the list above. None of these appear in your plan:

| Not created | Why, and what to do instead |
|---|---|
| **An IAM role or policy** | `deploy_policy_json` is an *output* — a rendered policy document scoped to exactly this bucket and distribution. You attach it to your own role. See `examples/complete` for the pattern. This way the permissions cannot drift from the real resources. |
| **DNS records** | Neither the site's records nor the certificate's validation records. The module has no idea who runs your DNS. Point your records at `distribution_domain_name` yourself. |
| **A Route 53 hosted zone** | Same reason. `distribution_hosted_zone_id` is output so you *can* build an alias record, but the record is yours to make. |
| **A WAF web ACL** | `web_acl_id` takes an existing one. A WAFv2 ACL is an account-level resource with its own cost and rule lifecycle; creating one per static site would be wrong. |
| **A log bucket** | `logging.bucket` takes an existing bucket's *domain name*. CloudFront's legacy logging needs ACLs enabled, which conflicts with the `BucketOwnerEnforced` stance this module takes on buckets it creates. |
| **A KMS key** | `bucket_kms_key_arn` takes an existing key, because the key policy — which the module cannot write — is the part that actually matters. |
| **Bucket contents** | The bucket is empty when apply finishes. Upload your build, or the site returns errors. |

Each of the three suppressions in [.trivyignore](.trivyignore) corresponds to a row in this
table: the scanner flags the missing logging and WAF, and the file explains why those are the
caller's decision rather than the module's.

### Where tags land

`var.tags` is applied to `aws_s3_bucket.this` and `aws_cloudfront_distribution.this` (and, in
the submodule, to the certificate). **CloudFront Functions and Origin Access Controls do not
support tags at all**, so four of the ten resources are untagged — three of them are S3
sub-configurations that have no tags of their own, and they inherit nothing.

Tags set here merge *over* the provider's `default_tags`, so a `default_tags` block in your
provider is the cleaner place for organisation-wide tags. `examples/complete` shows both
together.

### Rough cost shape

No fixed monthly fee for any of it — everything below is usage-based, and an idle site with no
traffic costs approximately nothing.

| Resource | Billing |
|---|---|
| S3 bucket | Storage, plus requests. Versioning means you also pay for retained old versions, which is what the lifecycle rule exists to bound. |
| CloudFront distribution | Data transfer out and per-request charges. `price_class` limits which edge locations serve traffic, and therefore cost. |
| CloudFront Function | Per invocation — cheap, but it runs on every request. |
| Origin Access Control | Free. |
| ACM public certificate | Free. |
| Invalidations | A monthly free allowance of paths, then per-path charges. `--paths "/*"` counts as one path. |

The one surprise for people new to CloudFront is that **data transfer out of CloudFront is
billed separately from data transfer out of S3** — but because the origin is fetched through
CloudFront and cached, S3 egress stays small as long as the cache hit rate is healthy.

---

## Part 4 — Certificates and DNS records, from first principles

Part 2 gave you the two-phase apply as a recipe. This part explains *why* it has that shape.
Almost every custom-domain problem becomes obvious once these concepts are clear, so it is
worth the ten minutes even if the recipe already worked for you.

### The core idea: a certificate binds *names*, not servers

HTTPS does two things: it encrypts the connection, and it proves **identity**. Encryption alone
is worthless — an attacker who intercepts your traffic can encrypt just fine. The certificate is
the identity half.

A certificate is a signed statement by a **Certificate Authority** (CA) saying:

> "Whoever holds the private key matching this public key controls the domain names
> `example.com` and `www.example.com`."

Your browser ships with a built-in list of CAs it trusts. When it connects, it checks that the
certificate was signed by one of them and that the name you typed in the address bar appears in
the certificate. If either check fails, you get the red warning page.

The critical thing for reasoning about any of this: **a certificate covers a list of domain
names.** It knows nothing about IP addresses, servers, regions, or which CDN you use. The names
it covers are its entire content. In ACM those are `domain_name` plus `subject_alternative_names`
— see [modules/acm-certificate/variables.tf](modules/acm-certificate/variables.tf).

A wildcard covers **exactly one label**: `*.example.com` covers `www.example.com` but *not*
`a.b.example.com`, and not the bare `example.com` either. That is why certificates so often list
both `example.com` and `*.example.com`.

### Why the CA needs convincing: validation

A CA cannot simply hand out `example.com` certificates to anyone who asks — that would make the
whole system meaningless. So before issuing, it demands proof that you control the domain.

**DNS validation** is the method this module uses, and the logic is simple: the CA asks you to
publish a specific, unguessable record in the domain's DNS zone. Only someone who controls the
zone can do that. Publish it, the CA sees it, the certificate is issued.

That is what the `validation_records_table` output is — ACM's challenge, rendered as a table:

```
NAME                                TYPE   VALUE
_a1b2c3d4e5.example.com             CNAME  _f6g7h8.acm-validations.aws
```

### The part that trips everyone up: two unrelated kinds of DNS record

Setting up a custom domain involves DNS records that serve **two completely different purposes**.
They are both usually CNAMEs, and you create them a few minutes apart, which is exactly why they
get conflated.

**1. Validation records** — prove ownership to ACM.

```
_a1b2c3d4e5.example.com  CNAME  _f6g7h8.acm-validations.aws
```

These point at AWS's validation infrastructure. **No user traffic ever touches them.** They exist
purely so ACM can verify you own the domain. The `_` prefix and random-looking name are
deliberate: unguessable means unforgeable.

**2. Traffic records** — actually route your users.

```
app.example.com  CNAME  d111111abcdef8.cloudfront.net
```

*This* is the one that makes the site load. It tells the world's DNS resolvers that
`app.example.com` is served by that CloudFront distribution — the `distribution_domain_name`
output.

Same zone file, same record type, entirely different jobs. Deleting the validation records will
not break your site today; deleting the traffic record breaks it in seconds.

### The three-way match

Once you have this, every "why does my custom domain not work" becomes obvious. **Three separate
places must list the same hostname**, and if any one of them disagrees, it breaks:

```
Browser asks for  https://app.example.com
        │
        │  ① DNS:  app.example.com → d111.cloudfront.net
        ▼
   CloudFront edge
        │
        │  ② Distribution `aliases` must contain "app.example.com"
        │     ...otherwise CloudFront does not know this request is yours
        │
        │  ③ Certificate names must contain "app.example.com"
        │     ...otherwise the browser rejects it before you see anything
        ▼
   Your S3 origin
```

- **① missing** → the domain does not resolve, or resolves somewhere else entirely.
- **② missing** → CloudFront returns an error; it received a hostname no distribution claims.
- **③ missing** → browser security warning. The connection is encrypted but unverified.

In this module, ② is `var.aliases` and ③ is the names on the certificate. The module enforces a
weaker version of this at plan time — `aliases require certificate_arn` — but it **cannot** check
that your certificate's names actually match your aliases. That part is on you.

### Why the ordering is awkward

Here is the dependency chain, and why Part 2 insists on a two-phase apply:

1. CloudFront **refuses** a certificate that is not `ISSUED` — it fails with
   `InvalidViewerCertificate`.
2. ACM will not mark a certificate `ISSUED` until it sees the validation record in DNS.
3. If Terraform does not manage your DNS, nothing in the apply can publish that record.

So a greenfield apply cannot get past step 1. Hence:

```
create certificate  →  publish validation record  →  wait for ISSUED
                    →  attach to distribution     →  publish traffic record
```

If your zone **is** in Route 53, Terraform can do step 2 itself (`aws_route53_record` built from
`domain_validation_options`), `wait_for_validation = true` blocks until ACM is satisfied, and the
whole thing collapses into one `terraform apply`. The awkwardness comes entirely from DNS living
outside Terraform.

### Leave the validation records in place — permanently

This is the one that bites people six months later. ACM **auto-renews** DNS-validated
certificates, but it re-checks the validation record each time. Delete the record after issuance
because it looks like leftover setup junk, and renewal silently fails — then roughly a year later
the site goes down with an expired certificate.

They cost nothing to keep. Leave them.

### Why us-east-1

CloudFront is a global service; its control plane lives in us-east-1, and it only reads
certificates from ACM **in us-east-1**. Your bucket can be in Sydney and your team in Frankfurt —
the certificate is still us-east-1. That is the sole reason `modules/acm-certificate` exists as a
separate module, as [Part 1](#the-submodule) explains.

Contrast with regional services: an Application Load Balancer needs its certificate in **its
own** region. Same ACM, different rule, because an ALB is not global.

### Two practical notes

**SNI.** The module sets `ssl_support_method = "sni-only"`. Server Name Indication is how a
single CloudFront edge IP serves thousands of different domains, each with its own certificate:
the browser announces which hostname it wants *at the start* of the TLS handshake, before
encryption begins, so the server knows which certificate to present. Universally supported now.
The alternative — a dedicated IP per distribution — carries a substantial monthly fee and exists
only for ancient clients.

**Why you need no certificate at all without a custom domain.** `d111111abcdef8.cloudfront.net`
sits under `cloudfront.net`, which **AWS owns**. AWS already holds a valid certificate for it.
That is what `cloudfront_default_certificate = true` selects, and it is why `examples/simple` has
no certificate, no DNS and applies in a single pass. The moment you want your *own* name in the
address bar, you have to prove you own that name — and everything above kicks in.

### The two transcription traps, now in context

Both make sense once the concepts are clear:

- **Host portion vs. FQDN.** ACM reports the full name `_a1b2c3.example.com`. Most zone editors
  already know the zone is `example.com` and want only `_a1b2c3`. Paste the full name and you
  create `_a1b2c3.example.com.example.com`, which ACM never finds — so the certificate sits at
  `PENDING_VALIDATION` forever, with no error message telling you why.
- **Wildcard dedup.** ACM derives a wildcard's validation record from its base domain, so
  `example.com` and `*.example.com` share a single record. You will create fewer records than you
  have names, which looks like a mistake and is not. The `validation_records_table` output
  already de-duplicates them.
