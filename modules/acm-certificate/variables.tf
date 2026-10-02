/**
 * modules/acm-certificate/variables.tf
 */

variable "domain_name" {
  description = "Primary domain name for the certificate."
  type        = string
}

variable "subject_alternative_names" {
  description = "Additional domain names covered by the certificate. A wildcard covers exactly one label, so *.example.com does not cover a.b.example.com. ACM derives a wildcard's validation record from its base domain, so *.example.com and example.com share one record."
  type        = list(string)
  default     = []
}

variable "validation_method" {
  description = "DNS or EMAIL. DNS is strongly recommended: it renews without human action for as long as the validation records stay in place."
  type        = string
  default     = "DNS"

  validation {
    condition     = contains(["DNS", "EMAIL"], var.validation_method)
    error_message = "validation_method must be DNS or EMAIL."
  }
}

variable "wait_for_validation" {
  description = "Block the apply until the certificate reaches ISSUED. Set true only when the validation records already exist or are created in the same apply — otherwise the apply hangs for validation_timeout and then fails."
  type        = bool
  default     = false
}

variable "validation_record_fqdns" {
  description = "FQDNs of validation records that already exist in DNS. Used only when wait_for_validation is true and you manage DNS outside Terraform. Null derives them from the certificate's own domain_validation_options."
  type        = list(string)
  default     = null
}

variable "validation_timeout" {
  description = "How long to wait for ISSUED when wait_for_validation is true."
  type        = string
  default     = "45m"
}

variable "tags" {
  description = "Tags applied to the certificate, merged over the provider's default_tags."
  type        = map(string)
  default     = {}
}
