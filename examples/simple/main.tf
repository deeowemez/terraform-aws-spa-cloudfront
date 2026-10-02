/**
 * examples/simple/main.tf
 */

provider "aws" {
  region = "us-east-1"
}

# No aliases and no certificate: the site is served on its own *.cloudfront.net domain,
# which is the fastest way to prove a build works before any DNS exists.
module "site" {
  source = "../../"

  name = "example-simple"
}
